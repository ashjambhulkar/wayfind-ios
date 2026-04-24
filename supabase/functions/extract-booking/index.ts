import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  EXTRACTION_PROMPT,
  CORS_HEADERS,
  PRIMARY_MODEL,
  FALLBACK_MODEL,
  CONFIDENCE_THRESHOLD,
  MODEL_TIMEOUT_MS,
  callExtractionModel,
  sanitizeBookings,
  getMinConfidence,
} from "../_shared/extraction-utils.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Max bytes downloaded for extraction (V2b Stage 1 — aligns with Edge payload / vision limits). */
const MAX_EXTRACTION_FILE_BYTES = 6 * 1024 * 1024;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (!OPENAI_API_KEY) {
    console.error("[extract-booking] OPENAI_API_KEY not configured");
    return new Response(
      JSON.stringify({ error: "OPENAI_API_KEY not configured" }),
      { status: 500, headers: CORS_HEADERS },
    );
  }

  let extractionUserId: string | null = null;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: CORS_HEADERS },
      );
    }

    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: CORS_HEADERS },
      );
    }

    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await supabaseUser.auth
      .getUser();
    const user = userData?.user;
    if (userErr || !user?.id) {
      console.error("[extract-booking] Auth failed:", userErr?.message);
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: CORS_HEADERS },
      );
    }
    extractionUserId = user.id;

    const body = await req.json();
    const { storage_path, mime_type } = body as {
      storage_path?: string;
      mime_type?: string;
    };

    if (!storage_path || !mime_type) {
      return new Response(
        JSON.stringify({ error: "storage_path and mime_type are required" }),
        { status: 400, headers: CORS_HEADERS },
      );
    }

    if (
      typeof storage_path !== "string" ||
      !storage_path.startsWith(`${user.id}/`)
    ) {
      return new Response(
        JSON.stringify({ error: "Forbidden" }),
        { status: 403, headers: CORS_HEADERS },
      );
    }

    console.log(
      `[extract-booking] user=${user.id} path_prefix_ok mime=${mime_type}`,
    );

    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: fileData, error: downloadError } = await supabaseAdmin.storage
      .from("trip-documents")
      .download(storage_path);

    if (downloadError || !fileData) {
      console.error("[extract-booking] Download failed:", downloadError?.message);
      return new Response(
        JSON.stringify({ error: "Failed to download document" }),
        { status: 500, headers: CORS_HEADERS },
      );
    }

    const arrayBuffer = await fileData.arrayBuffer();
    const uint8Array = new Uint8Array(arrayBuffer);

    if (uint8Array.length > MAX_EXTRACTION_FILE_BYTES) {
      return new Response(
        JSON.stringify({
          error: `File too large (max ${MAX_EXTRACTION_FILE_BYTES / (1024 * 1024)}MB)`,
        }),
        { status: 413, headers: CORS_HEADERS },
      );
    }

    const chunkSize = 8192;
    let binaryStr = "";
    for (let i = 0; i < uint8Array.length; i += chunkSize) {
      binaryStr += String.fromCharCode(
        ...uint8Array.subarray(i, Math.min(i + chunkSize, uint8Array.length)),
      );
    }
    const base64 = btoa(binaryStr);

    const isImage = mime_type.startsWith("image/");

    const openaiContent: Array<Record<string, unknown>> = [
      { type: "text", text: EXTRACTION_PROMPT },
    ];

    if (isImage) {
      openaiContent.push({
        type: "image_url",
        image_url: {
          url: `data:${mime_type};base64,${base64}`,
          detail: "high",
        },
      });
    } else {
      openaiContent.push({
        type: "file",
        file: {
          filename: storage_path.split("/").pop() || "document.pdf",
          file_data: `data:application/pdf;base64,${base64}`,
        },
      });
    }

    let extracted: Record<string, unknown>;
    let modelUsed = PRIMARY_MODEL;

    try {
      extracted = await callExtractionModel(
        OPENAI_API_KEY,
        PRIMARY_MODEL,
        openaiContent,
        MODEL_TIMEOUT_MS,
      );
    } catch (primaryErr) {
      console.error(`[extract-booking] ${PRIMARY_MODEL} failed:`, primaryErr);
      return new Response(
        JSON.stringify({ error: "Extraction service unavailable" }),
        { status: 502, headers: CORS_HEADERS },
      );
    }

    const primaryConfidence = getMinConfidence(extracted);

    if (primaryConfidence < CONFIDENCE_THRESHOLD) {
      console.log(
        `[extract-booking] ${PRIMARY_MODEL} confidence=${primaryConfidence.toFixed(2)}, retrying with ${FALLBACK_MODEL}`,
      );
      try {
        extracted = await callExtractionModel(
          OPENAI_API_KEY,
          FALLBACK_MODEL,
          openaiContent,
          MODEL_TIMEOUT_MS,
        );
        modelUsed = FALLBACK_MODEL;
      } catch (fallbackErr) {
        console.error(
          `[extract-booking] ${FALLBACK_MODEL} failed, using ${PRIMARY_MODEL} result:`,
          fallbackErr,
        );
      }
    }

    const safeBookings = sanitizeBookings(extracted, modelUsed);

    console.log(
      `[extract-booking] ok count=${safeBookings.length} model=${modelUsed}`,
    );

    // Notify user of extraction result (fire-and-forget)
    try {
      const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
      if (safeBookings.length > 0) {
        const first = safeBookings[0];
        const kind = first.kind ?? "booking";
        const title = first.title ?? kind;
        await supabaseAdmin.functions.invoke("send-notification", {
          body: {
            userId: user.id,
            type: "booking_extracted",
            title: "Booking added",
            body: `Your ${kind} "${title}" was extracted successfully.`,
            data: { storagePath: storage_path },
            idempotencyKey: `booking_extracted:${storage_path}`,
          },
        });
      }
    } catch (notifErr) {
      console.error("[extract-booking] notification send failed:", notifErr);
    }

    return new Response(JSON.stringify({ bookings: safeBookings }), {
      status: 200,
      headers: CORS_HEADERS,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[extract-booking] error:", message);

    // Notify user of extraction failure (fire-and-forget)
    try {
      if (extractionUserId) {
        const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
        await supabaseAdmin.functions.invoke("send-notification", {
          body: {
            userId: extractionUserId,
            type: "booking_extraction_failed",
            title: "Booking couldn't be read",
            body: "We couldn't extract details from your document. Try adding it manually.",
            data: {},
            idempotencyKey: `booking_failed:${Date.now()}`,
          },
        });
      }
    } catch (notifErr) {
      console.error("[extract-booking] failure notification failed:", notifErr);
    }

    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: CORS_HEADERS },
    );
  }
});
