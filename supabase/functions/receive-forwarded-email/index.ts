import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const INBOUND_EMAIL_USER = Deno.env.get("INBOUND_EMAIL_USER") ?? "";
const INBOUND_EMAIL_SECRET = Deno.env.get("INBOUND_EMAIL_SECRET") ?? "";

const MAX_EMAILS_PER_USER_PER_HOUR = 10;
const TAG = "[receive-forwarded-email]";

function validateBasicAuth(req: Request): boolean {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Basic ")) return false;
  const decoded = atob(authHeader.slice(6));
  const [user, pass] = decoded.split(":");
  return user === INBOUND_EMAIL_USER && pass === INBOUND_EMAIL_SECRET;
}

function extractEmail(fromField: string): string {
  const match = fromField.match(/<([^>]+)>/);
  return (match ? match[1] : fromField).trim().toLowerCase();
}

function extractTokenFromTo(toField: string): string | null {
  const tokenPattern = /trips\+([a-zA-Z0-9]+)@/i;
  const addressPattern = /<([^>]+)>/g;
  let match: RegExpExecArray | null;
  while ((match = addressPattern.exec(toField)) !== null) {
    const tokenMatch = match[1].match(tokenPattern);
    if (tokenMatch) return tokenMatch[1];
  }
  const rawMatch = toField.match(tokenPattern);
  return rawMatch ? rawMatch[1] : null;
}

async function computeHash(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Extract a named text field value from raw multipart form-data bytes.
 * Only scans part headers — does NOT load attachment binaries into memory.
 * Returns empty string if the field isn't found.
 */
function extractMultipartField(
  raw: Uint8Array,
  boundary: string,
  fieldName: string,
): string {
  const decoder = new TextDecoder();
  const boundaryBytes = new TextEncoder().encode(`--${boundary}`);
  const fieldHeader = `name="${fieldName}"`;

  let pos = 0;
  while (pos < raw.length) {
    const bIdx = indexOf(raw, boundaryBytes, pos);
    if (bIdx === -1) break;

    const headerEnd = indexOf(
      raw,
      new TextEncoder().encode("\r\n\r\n"),
      bIdx,
    );
    if (headerEnd === -1) break;

    const headerText = decoder.decode(raw.subarray(bIdx, headerEnd));
    if (headerText.includes(fieldHeader) && !headerText.includes("filename=")) {
      const valueStart = headerEnd + 4;
      const nextBoundary = indexOf(raw, boundaryBytes, valueStart);
      if (nextBoundary === -1) break;
      // -2 for the \r\n before the next boundary
      const valueEnd = nextBoundary - 2;
      return decoder.decode(raw.subarray(valueStart, valueEnd));
    }

    pos = headerEnd + 4;
  }
  return "";
}

function indexOf(
  haystack: Uint8Array,
  needle: Uint8Array,
  from = 0,
): number {
  outer: for (let i = from; i <= haystack.length - needle.length; i++) {
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/**
 * Architecture: "store raw body, parse later"
 *
 * The previous approach used req.formData() which buffers the entire
 * multipart body (10-30MB with attachments) into memory. The Supabase
 * Edge gateway times out at ~150s just receiving that data.
 *
 * New approach:
 * 1. Read raw body bytes (streamed, no parsing)
 * 2. Extract only 'to', 'from', 'subject', 'headers' by scanning
 *    multipart boundary headers (skips attachment bodies)
 * 3. Upload the raw body blob to storage in one shot
 * 4. Insert queue row
 * 5. Return 200 to SendGrid
 * 6. Processor downloads the raw blob and parses at leisure
 */
serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  if (!INBOUND_EMAIL_USER || !INBOUND_EMAIL_SECRET) {
    console.error(`${TAG} INBOUND_EMAIL_USER/SECRET not configured`);
    return new Response("Server misconfigured", { status: 500 });
  }

  if (!validateBasicAuth(req)) {
    console.error(`${TAG} Basic auth failed`);
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    const contentType = req.headers.get("content-type") ?? "";
    let from = "";
    let to = "";
    let subject = "";
    let emailHeaders = "";
    let rawBody: Uint8Array | null = null;
    let storedContentType = contentType;

    if (contentType.includes("multipart/form-data")) {
      // Read the raw bytes — no formData() parsing
      rawBody = new Uint8Array(await req.arrayBuffer());

      const boundaryMatch = contentType.match(/boundary=([^\s;]+)/);
      const boundary = boundaryMatch?.[1] ?? "";

      if (boundary && rawBody.length > 0) {
        from = extractMultipartField(rawBody, boundary, "from");
        to = extractMultipartField(rawBody, boundary, "to");
        subject = extractMultipartField(rawBody, boundary, "subject");
        emailHeaders = extractMultipartField(rawBody, boundary, "headers");
      }
    } else if (contentType.includes("application/json")) {
      const bodyText = await req.text();
      rawBody = new TextEncoder().encode(bodyText);
      try {
        const body = JSON.parse(bodyText);
        from = body.from ?? "";
        to = body.to ?? "";
        subject = body.subject ?? "";
        emailHeaders = body.headers ?? "";
      } catch {
        console.error(`${TAG} Failed to parse JSON body`);
        return new Response("OK", { status: 200 });
      }
    } else {
      return new Response("Unsupported content type", { status: 415 });
    }

    const senderEmail = extractEmail(from);
    if (!senderEmail) {
      console.error(`${TAG} No sender email found`);
      return new Response("OK", { status: 200 });
    }

    let messageIdSource = "";
    const messageIdMatch = emailHeaders.match(/Message-ID:\s*(<[^>]+>)/i);
    if (messageIdMatch) {
      messageIdSource = messageIdMatch[1];
    } else {
      messageIdSource = `${senderEmail}|${subject}|${Date.now()}`;
    }
    const messageIdHash = await computeHash(messageIdSource);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // ── Resolve trip + user from per-trip token ──
    const token = extractTokenFromTo(to);
    let resolvedUserId: string | null = null;
    let resolvedTripId: string | null = null;
    let queueStatus = "received";
    let errorMessage: string | null = null;

    if (token) {
      const { data: addrRow } = await supabase
        .from("user_forwarding_addresses")
        .select("user_id, trip_id")
        .eq("address_token", token)
        .eq("is_active", true)
        .single();

      if (addrRow) {
        resolvedUserId = addrRow.user_id;
        resolvedTripId = addrRow.trip_id;
      } else {
        queueStatus = "failed";
        errorMessage =
          "Forwarding address no longer valid. Open the trip in Wayfind to get the current address.";
        console.warn(`${TAG} Token not found or inactive: ${token}`);
      }
    } else {
      queueStatus = "failed";
      errorMessage =
        "Please use the trip-specific forwarding address from your trip in Wayfind.";
      console.warn(`${TAG} No token in to field: ${to}`);
    }

    // ── Rate limiting ──
    const oneHourAgo = new Date(Date.now() - 3600_000).toISOString();
    const { count } = await supabase
      .from("email_forwarding_queue")
      .select("id", { count: "exact", head: true })
      .eq("sender_email", senderEmail)
      .gte("created_at", oneHourAgo);

    if ((count ?? 0) >= MAX_EMAILS_PER_USER_PER_HOUR) {
      console.warn(`${TAG} Rate limit exceeded for ${senderEmail}`);
      return new Response("OK", { status: 200 });
    }

    // ── Upload raw body blob to storage (one fast write) ──
    const storagePath = `forwarded-emails/${messageIdHash}`;
    let uploadedOk = false;

    if (rawBody && rawBody.length > 0 && queueStatus !== "failed") {
      const { error: uploadErr } = await supabase.storage
        .from("trip-documents")
        .upload(`${storagePath}/raw-body`, rawBody, {
          contentType: storedContentType,
          upsert: true,
        });
      if (uploadErr) {
        console.error(`${TAG} Raw body upload failed:`, uploadErr.message);
      } else {
        uploadedOk = true;
      }
    }

    // ── INSERT queue row ──
    const queueRow: Record<string, unknown> = {
      sender_email: senderEmail,
      subject: subject || null,
      message_id_hash: messageIdHash,
      raw_email_storage_path: uploadedOk ? storagePath : null,
      status: uploadedOk ? "pending" : queueStatus,
    };
    if (resolvedUserId) queueRow.user_id = resolvedUserId;
    if (resolvedTripId) queueRow.trip_id = resolvedTripId;
    if (errorMessage) queueRow.error_message = errorMessage;
    if (queueStatus === "failed") {
      queueRow.processed_at = new Date().toISOString();
    }

    const { data: insertedRow, error: insertError } = await supabase
      .from("email_forwarding_queue")
      .insert(queueRow)
      .select("id")
      .single();

    if (insertError) {
      if (insertError.code === "23505") {
        console.log(
          `${TAG} Duplicate email, skipping: ${messageIdHash.slice(0, 12)}`,
        );
        return new Response("OK", { status: 200 });
      }
      console.error(`${TAG} Insert failed:`, insertError.message);
      return new Response("OK", { status: 200 });
    }

    const queueId = insertedRow?.id as string;

    console.log(
      `${TAG} Done: from=${senderEmail} token=${token ?? "none"} status=${queueRow.status} hash=${messageIdHash.slice(0, 12)} queueId=${queueId} bodySize=${rawBody?.length ?? 0}`,
    );

    // ── Fire processor if we're ready ──
    if (queueRow.status === "pending") {
      fetch(`${SUPABASE_URL}/functions/v1/process-forwarded-email`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ message_id_hash: messageIdHash }),
      }).catch((e) =>
        console.error(`${TAG} Processor invoke failed (non-fatal):`, e),
      );
    }

    return new Response("OK", { status: 200 });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`${TAG} error:`, message);
    return new Response("OK", { status: 200 });
  }
});
