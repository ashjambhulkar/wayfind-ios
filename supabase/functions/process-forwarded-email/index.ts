import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  EMAIL_EXTRACTION_PROMPT,
  EXTRACTION_PROMPT,
  CORS_HEADERS,
  PRIMARY_MODEL,
  FALLBACK_MODEL,
  CONFIDENCE_THRESHOLD,
  MODEL_TIMEOUT_MS,
  callExtractionModel,
  sanitizeBookings,
  getMinConfidence,
  type SafeBooking,
} from "../_shared/extraction-utils.ts";
import {
  parseRawMultipart,
  stripHtmlTags,
  type ParsedAttachment,
  type ParsedEmail,
} from "./mime.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const TAG = "[process-forwarded-email]";
const EMAIL_MESSAGE_ID_HASH_KEY = "email_message_id_hash";
const EMAIL_BODY_MAX_CHARS = 50_000;
const EMAIL_BODY_HEAD_CHARS = 25_000;
const EMAIL_BODY_TAIL_CHARS = 24_000;
const EMAIL_BODY_KEYWORD_WINDOW = 5_000;
const MAX_ATTACHMENTS_TO_EXTRACT = 2;

// ── Types ──────────────────────────────────────────────────────────────────

interface QueueRow {
  id: string;
  sender_email: string;
  subject: string | null;
  message_id_hash: string;
  raw_email_storage_path: string | null;
  user_id: string | null;
  trip_id: string | null;
  status: string;
}

interface AttachmentDebug {
  filename: string;
  content_type: string;
  size_bytes: number;
  discovered_from: string;
  is_extractable: boolean;
  extract_attempted: boolean;
  extract_ok: boolean | null;
  bookings_found: number | null;
  extract_error: string | null;
}

interface PipelineDebug {
  stage: string;
  sender_email: string;
  subject: string | null;
  raw_storage_path: string | null;
  inbound_summary: {
    content_type_stored: string;
    raw_body_size_bytes: number;
    fields_found: string[];
    attachment_candidate_count: number;
    body_text_len: number;
    html_len: number;
    body_text_is_qp_decoded: boolean;
    html_is_qp_decoded: boolean;
  };
  attachments: AttachmentDebug[];
  body_extraction: {
    attempted: boolean;
    source_used: "text" | "html_stripped" | "none" | null;
    input_length: number | null;
    bookings_found: number | null;
    error: string | null;
  };
  model: {
    model_used: string | null;
    raw_candidate_count: number;
    confidence_rejected: number;
    duplicate_rejected: number;
  };
  result: {
    inserted_count: number;
    final_status: string;
    error: string | null;
  };
}

// ── Helpers ────────────────────────────────────────────────────────────────

function makePipelineDebug(row: QueueRow): PipelineDebug {
  return {
    stage: "init",
    sender_email: row.sender_email,
    subject: row.subject,
    raw_storage_path: row.raw_email_storage_path,
    inbound_summary: {
      content_type_stored: "",
      raw_body_size_bytes: 0,
      fields_found: [],
      attachment_candidate_count: 0,
      body_text_len: 0,
      html_len: 0,
      body_text_is_qp_decoded: false,
      html_is_qp_decoded: false,
    },
    attachments: [],
    body_extraction: {
      attempted: false,
      source_used: null,
      input_length: null,
      bookings_found: null,
      error: null,
    },
    model: {
      model_used: null,
      raw_candidate_count: 0,
      confidence_rejected: 0,
      duplicate_rejected: 0,
    },
    result: {
      inserted_count: 0,
      final_status: "processing",
      error: null,
    },
  };
}

type SupabaseClient = ReturnType<typeof createClient>;

async function updateQueueStatus(
  supabase: SupabaseClient,
  queueId: string,
  status: string,
  debug: PipelineDebug,
  extra: Record<string, unknown> = {},
): Promise<void> {
  const data: Record<string, unknown> = {
    status,
    pipeline_debug: debug,
    ingestion_stage: debug.stage,
    ...extra,
  };
  if (["processed", "failed", "no_user"].includes(status)) {
    data.processed_at = new Date().toISOString();
  }
  const { error } = await supabase
    .from("email_forwarding_queue")
    .update(data)
    .eq("id", queueId);
  if (error) {
    console.error(`${TAG} Status update failed:`, error.message);
  }
}

const EXTRACTABLE_MIME_TYPES = new Set([
  "application/pdf",
  "image/png",
  "image/jpeg",
  "image/jpg",
  "image/webp",
]);

function isExtractable(contentType: string, filename: string): boolean {
  if (EXTRACTABLE_MIME_TYPES.has(contentType)) return true;
  if (contentType === "application/octet-stream") {
    const ext = filename.toLowerCase().match(/\.[^.]+$/)?.[0] ?? "";
    return [".pdf", ".png", ".jpg", ".jpeg", ".webp"].includes(ext);
  }
  return false;
}

function resolveContentType(contentType: string, filename: string): string {
  if (contentType !== "application/octet-stream") return contentType;
  const ext = filename.toLowerCase().match(/\.[^.]+$/)?.[0] ?? "";
  const extMap: Record<string, string> = {
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
  };
  return extMap[ext] ?? contentType;
}

/**
 * Prefer keyword-centered window; fall back to head+tail.
 * Keeps booking-relevant content near the top of the LLM input.
 */
function sliceBodyForLlm(raw: string, maxLen: number): string {
  if (raw.length <= maxLen) return raw;

  const keywordRe =
    /\b(confirmation|itinerary|reservation|booking|e-?ticket|pnr|record\s*locator|flight|hotel|check-?in)\b/i;
  const matchIdx = raw.search(keywordRe);
  if (matchIdx !== -1) {
    const start = Math.max(0, matchIdx - EMAIL_BODY_KEYWORD_WINDOW);
    const end = Math.min(raw.length, start + maxLen);
    let chunk = raw.slice(start, end);
    if (start > 0) chunk = `[...${start} chars omitted...]\n${chunk}`;
    if (end < raw.length)
      chunk = `${chunk}\n[...${raw.length - end} chars omitted...]`;
    return chunk;
  }

  const marker = "\n\n--- [middle of email omitted] ---\n\n";
  const budget = maxLen - marker.length;
  const head = Math.min(EMAIL_BODY_HEAD_CHARS, Math.floor(budget / 2));
  const tail = Math.min(EMAIL_BODY_TAIL_CHARS, budget - head);
  const omitted = raw.length - head - tail;
  return `${raw.slice(0, head)}${marker}${raw.slice(raw.length - tail)}${
    omitted > 0 ? `\n[${omitted} chars total omitted from middle]` : ""
  }`;
}

// ── Stage 1: Load raw email blob from storage ──────────────────────────────

interface StoredEmailBlob {
  rawBytes: Uint8Array;
  contentType: string;
}

async function loadStoredEmail(
  supabase: SupabaseClient,
  storagePath: string,
): Promise<StoredEmailBlob | { error: string }> {
  const { data: rawBlob } = await supabase.storage
    .from("trip-documents")
    .download(`${storagePath}/raw-body`);

  if (!rawBlob) {
    return { error: `raw-body not found at ${storagePath}` };
  }

  let contentType = rawBlob.type ?? "";

  // Storage may strip the boundary from the MIME type; recover it from meta.json
  if (!contentType.includes("boundary")) {
    const { data: metaBlob } = await supabase.storage
      .from("trip-documents")
      .download(`${storagePath}/meta.json`);
    if (metaBlob) {
      try {
        const meta = JSON.parse(await metaBlob.text()) as {
          contentType?: string;
        };
        if (meta.contentType?.includes("boundary")) {
          contentType = meta.contentType;
        }
      } catch {
        console.warn(`${TAG} Failed to parse meta.json`);
      }
    }
  }

  const rawBytes = new Uint8Array(await rawBlob.arrayBuffer());
  return { rawBytes, contentType };
}

// ── Legacy path: email.json + attachment-* files ───────────────────────────

async function loadLegacyEmail(
  supabase: SupabaseClient,
  storagePath: string,
): Promise<ParsedEmail> {
  const result: ParsedEmail = { html: "", text: "", attachments: [] };

  const { data: emailFile } = await supabase.storage
    .from("trip-documents")
    .download(`${storagePath}/email.json`);
  if (emailFile) {
    try {
      const emailContent = JSON.parse(await emailFile.text()) as {
        html?: string;
        text?: string;
      };
      result.html = emailContent.html ?? "";
      result.text = emailContent.text ?? "";
    } catch {
      console.warn(`${TAG} Legacy email.json parse failed`);
    }
  }

  const { data: storedFiles } = await supabase.storage
    .from("trip-documents")
    .list(storagePath);
  for (const f of (storedFiles ?? []).filter((f) =>
    f.name.startsWith("attachment-"),
  )) {
    const { data: attData } = await supabase.storage
      .from("trip-documents")
      .download(`${storagePath}/${f.name}`);
    if (attData) {
      result.attachments.push({
        filename: f.name,
        contentType:
          (f.metadata as { mimetype?: string } | null)?.mimetype ??
          "application/octet-stream",
        bytes: new Uint8Array(await attData.arrayBuffer()),
        discoveredFrom: "multipart_form_field",
      });
    }
  }

  return result;
}

// ── Stage 2: Parse inbound payload ────────────────────────────────────────

interface ParseResult {
  parsed: ParsedEmail;
  fieldsFound: string[];
  bodyTextIsQpDecoded: boolean;
  htmlIsQpDecoded: boolean;
}

function parseInboundPayload(
  rawBytes: Uint8Array,
  contentType: string,
): ParseResult {
  const parsed = parseRawMultipart(rawBytes, contentType);

  // Detect whether QP decoding was applied by checking if QP signatures were
  // in the raw bytes before decoding (presence of "=XX" patterns in raw text).
  const rawSample = new TextDecoder("utf-8", { fatal: false }).decode(
    rawBytes.subarray(0, Math.min(rawBytes.length, 4096)),
  );
  const rawHasQp = /=[0-9A-Fa-f]{2}/.test(rawSample);

  // Collect what field names are present in the form-data
  const fieldsFound: string[] = [];
  if (parsed.text) fieldsFound.push("text");
  if (parsed.html) fieldsFound.push("html");
  if (parsed.attachments.length > 0) fieldsFound.push("attachments");

  return {
    parsed,
    fieldsFound,
    bodyTextIsQpDecoded: rawHasQp && parsed.text.length > 0,
    htmlIsQpDecoded: rawHasQp && parsed.html.length > 0,
  };
}

// ── Stage 3: Attachment extraction ────────────────────────────────────────

interface ExtractedAttachmentSource {
  filename: string;
  mimeType: string;
  bytes: Uint8Array;
}

interface AttachmentExtractionResult {
  bookings: SafeBooking[];
  modelUsed: string;
  debugEntries: AttachmentDebug[];
  /** Attachments that successfully produced at least one booking — used to
   *  auto-link the source PDF/image to every created trip_booking row. */
  successfulAttachments: ExtractedAttachmentSource[];
}

async function extractFromAttachments(
  apiKey: string,
  attachments: ParsedAttachment[],
): Promise<AttachmentExtractionResult> {
  const allBookings: SafeBooking[] = [];
  let lastModelUsed = PRIMARY_MODEL;
  const debugEntries: AttachmentDebug[] = [];
  const successfulAttachments: ExtractedAttachmentSource[] = [];

  const extractable = attachments.filter((a) =>
    isExtractable(a.contentType, a.filename),
  );

  for (const att of extractable.slice(0, MAX_ATTACHMENTS_TO_EXTRACT)) {
    const resolvedType = resolveContentType(att.contentType, att.filename);
    const isImage = resolvedType.startsWith("image/");

    const debugEntry: AttachmentDebug = {
      filename: att.filename,
      content_type: resolvedType,
      size_bytes: att.bytes.length,
      discovered_from: att.discoveredFrom,
      is_extractable: true,
      extract_attempted: true,
      extract_ok: null,
      bookings_found: null,
      extract_error: null,
    };

    const chunkSize = 8192;
    let binaryStr = "";
    for (let i = 0; i < att.bytes.length; i += chunkSize) {
      binaryStr += String.fromCharCode(
        ...att.bytes.subarray(i, Math.min(i + chunkSize, att.bytes.length)),
      );
    }
    const base64 = btoa(binaryStr);

    const content: Array<Record<string, unknown>> = [
      { type: "text", text: EXTRACTION_PROMPT },
    ];

    if (isImage) {
      // Images: gpt-4o-mini supports image_url — use primary→fallback path.
      content.push({
        type: "image_url",
        image_url: { url: `data:${resolvedType};base64,${base64}`, detail: "high" },
      });
    } else {
      // PDFs: only gpt-4o supports the "file" content type in Chat Completions.
      // Skip gpt-4o-mini entirely and call gpt-4o directly.
      content.push({
        type: "file",
        file: {
          filename: att.filename,
          file_data: `data:${resolvedType};base64,${base64}`,
        },
      });
    }

    try {
      const result = isImage
        ? await extractWithFallback(apiKey, content)
        : await extractWithModel(apiKey, FALLBACK_MODEL, content);
      debugEntry.extract_ok = true;
      debugEntry.bookings_found = result.bookings.length;
      if (result.bookings.length > 0) {
        allBookings.push(...result.bookings);
        lastModelUsed = result.modelUsed;
        successfulAttachments.push({
          filename: att.filename,
          mimeType: resolvedType,
          bytes: att.bytes,
        });
      }
      console.log(
        `${TAG} Attachment "${att.filename}": ${result.bookings.length} booking(s) via ${result.modelUsed}`,
      );
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      debugEntry.extract_ok = false;
      debugEntry.extract_error = msg;
      console.error(`${TAG} Attachment extraction failed for "${att.filename}": ${msg}`);
    }

    debugEntries.push(debugEntry);
  }

  // Record non-extractable attachments for transparency
  for (const att of attachments.filter(
    (a) => !isExtractable(a.contentType, a.filename),
  )) {
    debugEntries.push({
      filename: att.filename,
      content_type: att.contentType,
      size_bytes: att.bytes.length,
      discovered_from: att.discoveredFrom,
      is_extractable: false,
      extract_attempted: false,
      extract_ok: null,
      bookings_found: null,
      extract_error: null,
    });
  }

  return { bookings: allBookings, modelUsed: lastModelUsed, debugEntries, successfulAttachments };
}

// ── Stage 4: Email body extraction ────────────────────────────────────────

interface BodyExtractionResult {
  bookings: SafeBooking[];
  modelUsed: string;
  sourceUsed: "text" | "html_stripped" | "none";
  inputLength: number;
  error: string | null;
}

/**
 * Returns true when >90% of the first 2 KB of non-whitespace characters are
 * in the base64 alphabet.  This catches the case where a raw base64-encoded
 * attachment blob leaked into the text field and prevents wasting an LLM call
 * on binary noise that contains no booking information.
 */
function isLikelyBase64Blob(s: string): boolean {
  if (s.length < 500) return false;
  const sample = s.replace(/\s/g, "").slice(0, 2000);
  if (sample.length === 0) return false;
  const nonBase64 = sample.replace(/[A-Za-z0-9+/=]/g, "").length;
  return nonBase64 / sample.length < 0.05;
}

async function extractFromBody(
  apiKey: string,
  html: string,
  text: string,
): Promise<BodyExtractionResult> {
  const noResult: BodyExtractionResult = {
    bookings: [],
    modelUsed: PRIMARY_MODEL,
    sourceUsed: "none",
    inputLength: 0,
    error: null,
  };

  // Prefer plain text (already decoded); fall back to HTML stripped to text.
  // Use HTML only if text is very short (forwarding headers only, no real body).
  let bodyText = "";
  let sourceUsed: "text" | "html_stripped" = "text";

  if (text.length >= 200) {
    // Guard: if the text field is a raw base64-encoded blob (attachment data
    // that leaked into the text field before the MIME fix), skip it entirely.
    // Sending base64 noise to the LLM produces no bookings and wastes tokens.
    if (isLikelyBase64Blob(text)) {
      console.warn(`${TAG} extractFromBody: text field looks like base64 blob (${text.length} chars) — skipping body extraction`);
      return noResult;
    }
    bodyText = text;
    sourceUsed = "text";
  } else if (html.length > 0) {
    bodyText = stripHtmlTags(html);
    sourceUsed = "html_stripped";
  }

  if (!bodyText) return noResult;

  const sliced = sliceBodyForLlm(bodyText, EMAIL_BODY_MAX_CHARS);
  const content: Array<Record<string, unknown>> = [
    { type: "text", text: EMAIL_EXTRACTION_PROMPT },
    { type: "text", text: `--- EMAIL CONTENT ---\n${sliced}` },
  ];

  try {
    const result = await extractWithFallback(apiKey, content);
    return {
      bookings: result.bookings,
      modelUsed: result.modelUsed,
      sourceUsed,
      inputLength: sliced.length,
      error: null,
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return {
      bookings: [],
      modelUsed: PRIMARY_MODEL,
      sourceUsed,
      inputLength: sliced.length,
      error: msg,
    };
  }
}

// ── Stage 5: Model call with primary → fallback ────────────────────────────

async function extractWithFallback(
  apiKey: string,
  content: Array<Record<string, unknown>>,
): Promise<{ bookings: SafeBooking[]; modelUsed: string }> {
  let modelUsed = PRIMARY_MODEL;
  let extracted = await callExtractionModel(
    apiKey,
    PRIMARY_MODEL,
    content,
    MODEL_TIMEOUT_MS,
  );

  const confidence = getMinConfidence(extracted);
  if (confidence < CONFIDENCE_THRESHOLD) {
    console.log(
      `${TAG} ${PRIMARY_MODEL} confidence=${confidence.toFixed(2)} — retrying with ${FALLBACK_MODEL}`,
    );
    try {
      extracted = await callExtractionModel(
        apiKey,
        FALLBACK_MODEL,
        content,
        MODEL_TIMEOUT_MS,
      );
      modelUsed = FALLBACK_MODEL;
    } catch (fallbackErr) {
      console.error(
        `${TAG} ${FALLBACK_MODEL} failed, keeping ${PRIMARY_MODEL} result:`,
        fallbackErr,
      );
    }
  }

  return { bookings: sanitizeBookings(extracted, modelUsed), modelUsed };
}

async function extractWithModel(
  apiKey: string,
  model: string,
  content: Array<Record<string, unknown>>,
): Promise<{ bookings: SafeBooking[]; modelUsed: string }> {
  const extracted = await callExtractionModel(apiKey, model, content, MODEL_TIMEOUT_MS);
  return { bookings: sanitizeBookings(extracted, model), modelUsed: model };
}

// ── Stage 6: Dedup + insert bookings ──────────────────────────────────────

// ── Stage 6b: Auto-attach source PDFs/images to inserted bookings ─────────

async function linkAttachmentsToBookings(
  supabase: SupabaseClient,
  attachments: ExtractedAttachmentSource[],
  bookingIds: string[],
  userId: string,
): Promise<void> {
  if (attachments.length === 0 || bookingIds.length === 0) return;

  for (const att of attachments) {
    for (const bookingId of bookingIds) {
      const ext = att.filename.includes(".")
        ? att.filename.split(".").pop()!.toLowerCase().slice(0, 8)
        : att.mimeType === "application/pdf" ? "pdf" : "bin";
      const storagePath = `${userId}/${bookingId}/${crypto.randomUUID()}.${ext}`;

      const { error: uploadErr } = await supabase.storage
        .from("booking-attachments")
        .upload(storagePath, att.bytes, {
          contentType: att.mimeType,
          upsert: false,
        });

      if (uploadErr) {
        console.error(
          `${TAG} Storage upload failed for booking ${bookingId}: ${uploadErr.message}`,
        );
        continue;
      }

      const { error: insertErr } = await supabase
        .from("trip_booking_attachments")
        .insert({
          booking_id: bookingId,
          user_id: userId,
          storage_path: storagePath,
          original_filename: att.filename,
          mime_type: att.mimeType,
          file_size_bytes: att.bytes.length,
        });

      if (insertErr) {
        console.error(
          `${TAG} trip_booking_attachments insert failed for booking ${bookingId}: ${insertErr.message}`,
        );
      } else {
        console.log(
          `${TAG} Attached "${att.filename}" → booking ${bookingId}`,
        );
      }
    }
  }
}

interface PersistResult {
  insertedIds: string[];
  confidenceRejected: number;
  duplicateRejected: number;
}

async function persistBookings(
  supabase: SupabaseClient,
  bookings: SafeBooking[],
  tripId: string,
  userId: string,
  messageIdHash: string,
): Promise<PersistResult> {
  const insertedIds: string[] = [];
  let confidenceRejected = 0;
  let duplicateRejected = 0;

  for (const booking of bookings) {
    if (booking.confidence < CONFIDENCE_THRESHOLD) {
      confidenceRejected++;
      console.log(
        `${TAG} Skipping low-confidence booking: ${booking.kind} confidence=${booking.confidence.toFixed(2)}`,
      );
      continue;
    }

    const isDuplicate = await checkDuplicate(supabase, booking, tripId);
    if (isDuplicate) {
      duplicateRejected++;
      continue;
    }

    const detailsWithSource = {
      ...booking.details_json,
      [EMAIL_MESSAGE_ID_HASH_KEY]: messageIdHash,
    };

    const { data: inserted, error: insertErr } = await supabase
      .from("trip_bookings")
      .insert({
        trip_id: tripId,
        user_id: userId,
        kind: booking.kind,
        title: booking.title || `${booking.kind} booking`,
        confirmation_code: booking.confirmation_code,
        provider: booking.provider,
        starts_at: booking.starts_at,
        ends_at: booking.ends_at,
        start_location: booking.start_location,
        end_location: booking.end_location,
        details_json: detailsWithSource,
        total_price: booking.total_price,
        // Write `amount` explicitly so tg_sync_booking_expense fires correctly.
        // Pre-migration rows only had total_price; the tg_coerce_booking_amount
        // trigger handles the coercion for legacy rows but new inserts always
        // carry both fields to avoid relying on the BEFORE trigger order.
        amount: booking.total_price,
        currency: booking.currency,
        source: "forwarded_email",
      })
      .select("id")
      .single();

    if (insertErr) {
      console.error(`${TAG} Booking insert failed:`, insertErr.message);
    } else if (inserted) {
      insertedIds.push((inserted as { id: string }).id);
    }
  }

  return { insertedIds, confidenceRejected, duplicateRejected };
}

async function checkDuplicate(
  supabase: SupabaseClient,
  booking: SafeBooking,
  tripId: string,
): Promise<boolean> {
  if (booking.confirmation_code && booking.starts_at) {
    const { count } = await supabase
      .from("trip_bookings")
      .select("id", { count: "exact", head: true })
      .eq("trip_id", tripId)
      .eq("confirmation_code", booking.confirmation_code)
      .eq("kind", booking.kind)
      .eq("starts_at", booking.starts_at);
    if ((count ?? 0) > 0) return true;
  } else if (booking.starts_at && booking.provider) {
    const { count } = await supabase
      .from("trip_bookings")
      .select("id", { count: "exact", head: true })
      .eq("trip_id", tripId)
      .eq("kind", booking.kind)
      .eq("provider", booking.provider)
      .eq("starts_at", booking.starts_at);
    if ((count ?? 0) > 0) return true;
  }
  return false;
}

// ── Main handler ───────────────────────────────────────────────────────────

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (!OPENAI_API_KEY) {
    console.error(`${TAG} OPENAI_API_KEY not configured`);
    return new Response(
      JSON.stringify({ error: "OPENAI_API_KEY not configured" }),
      { status: 500, headers: CORS_HEADERS },
    );
  }

  const internalSecret = Deno.env.get("INBOUND_EMAIL_SECRET") ?? "";
  const xSecret = req.headers.get("x-processor-secret") ?? "";
  const bearerToken =
    req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const isAuthorized =
    (internalSecret.length > 0 && xSecret === internalSecret) ||
    bearerToken === SUPABASE_SERVICE_ROLE_KEY;

  if (!isAuthorized) {
    console.error(
      `${TAG} Auth failed: xSecretLen=${xSecret.length} bearerLen=${bearerToken.length}`,
    );
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: CORS_HEADERS },
    );
  }

  try {
    const body = await req.json();
    const messageIdHash = body.message_id_hash as string | undefined;
    if (!messageIdHash) {
      return new Response(
        JSON.stringify({ error: "message_id_hash required" }),
        { status: 400, headers: CORS_HEADERS },
      );
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // ── Fetch queue row ──────────────────────────────────────────────────
    const { data: queueRow, error: fetchErr } = await supabase
      .from("email_forwarding_queue")
      .select("*")
      .eq("message_id_hash", messageIdHash)
      .single();

    if (fetchErr || !queueRow) {
      console.error(`${TAG} Queue row not found:`, fetchErr?.message);
      return new Response(
        JSON.stringify({ error: "Queue row not found" }),
        { status: 404, headers: CORS_HEADERS },
      );
    }

    const row = queueRow as QueueRow;
    if (row.status !== "pending") {
      console.log(`${TAG} Skipping non-pending row: ${row.status}`);
      return new Response(
        JSON.stringify({ status: row.status }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    const debug = makePipelineDebug(row);
    await updateQueueStatus(supabase, row.id, "processing", debug);

    // ── Resolve user (legacy compat) ─────────────────────────────────────
    debug.stage = "resolve_user";
    let userId = row.user_id;
    const tripId = row.trip_id;

    if (!userId) {
      const { data: usersData } = await supabase.auth.admin.listUsers();
      const matchedUser = usersData?.users?.find(
        (u) => u.email?.toLowerCase() === row.sender_email.toLowerCase(),
      );
      if (!matchedUser) {
        console.log(`${TAG} No user found for ${row.sender_email}`);
        debug.stage = "failed_no_user";
        debug.result = { inserted_count: 0, final_status: "no_user", error: "User not found" };
        await updateQueueStatus(supabase, row.id, "no_user", debug);
        return new Response(
          JSON.stringify({ status: "no_user" }),
          { status: 200, headers: CORS_HEADERS },
        );
      }
      userId = matchedUser.id;
      await supabase
        .from("email_forwarding_queue")
        .update({ user_id: userId })
        .eq("id", row.id);
    }

    if (!tripId) {
      const errMsg = "Missing trip. Re-forward using your trip-specific email address.";
      debug.stage = "failed_no_trip";
      debug.result = { inserted_count: 0, final_status: "failed", error: errMsg };
      await updateQueueStatus(supabase, row.id, "failed", debug, {
        error_message: errMsg,
      });
      return new Response(
        JSON.stringify({ status: "failed", error: "No trip resolved" }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    // ── Load stored email ────────────────────────────────────────────────
    debug.stage = "load_stored_email";
    const storagePath = row.raw_email_storage_path;

    if (!storagePath) {
      const errMsg = "No email storage path on queue row";
      debug.result = { inserted_count: 0, final_status: "failed", error: errMsg };
      await updateQueueStatus(supabase, row.id, "failed", debug, {
        error_message: errMsg,
      });
      return new Response(
        JSON.stringify({ error: errMsg }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    let parsed: ParsedEmail;

    const blobResult = await loadStoredEmail(supabase, storagePath);
    if ("error" in blobResult) {
      console.warn(`${TAG} raw-body missing, falling back to legacy format`);
      parsed = await loadLegacyEmail(supabase, storagePath);
      debug.inbound_summary.content_type_stored = "legacy";
    } else {
      const { rawBytes, contentType } = blobResult;
      debug.inbound_summary.content_type_stored = contentType;
      debug.inbound_summary.raw_body_size_bytes = rawBytes.length;

      // ── Parse inbound payload ──────────────────────────────────────────
      debug.stage = "parse_inbound";
      const parseResult = parseInboundPayload(rawBytes, contentType);
      parsed = parseResult.parsed;
      debug.inbound_summary.fields_found = parseResult.fieldsFound;
      debug.inbound_summary.body_text_is_qp_decoded =
        parseResult.bodyTextIsQpDecoded;
      debug.inbound_summary.html_is_qp_decoded = parseResult.htmlIsQpDecoded;
    }

    debug.inbound_summary.body_text_len = parsed.text.length;
    debug.inbound_summary.html_len = parsed.html.length;
    debug.inbound_summary.attachment_candidate_count = parsed.attachments.length;

    console.log(
      `${TAG} Parsed: text=${parsed.text.length}c html=${parsed.html.length}c attachments=${parsed.attachments.length}` +
        ` qp_text=${debug.inbound_summary.body_text_is_qp_decoded} qp_html=${debug.inbound_summary.html_is_qp_decoded}`,
    );

    await updateQueueStatus(supabase, row.id, "processing", debug);

    // ── Extract from attachments (PDFs / images) ─────────────────────────
    debug.stage = "attachment_extraction";
    let allBookings: SafeBooking[] = [];
    let modelUsed = PRIMARY_MODEL;
    let attResult: AttachmentExtractionResult = {
      bookings: [],
      modelUsed: PRIMARY_MODEL,
      debugEntries: [],
      successfulAttachments: [],
    };

    if (parsed.attachments.length > 0) {
      attResult = await extractFromAttachments(
        OPENAI_API_KEY!,
        parsed.attachments,
      );
      debug.attachments = attResult.debugEntries;
      allBookings = attResult.bookings;
      modelUsed = attResult.modelUsed;
      console.log(
        `${TAG} Attachment extraction: ${allBookings.length} booking(s) from ${parsed.attachments.length} attachment(s)`,
      );
    }

    // ── Extract from email body (fallback) ────────────────────────────────
    if (allBookings.length === 0) {
      debug.stage = "body_extraction";
      debug.body_extraction.attempted = true;

      const bodyResult = await extractFromBody(
        OPENAI_API_KEY!,
        parsed.html,
        parsed.text,
      );

      debug.body_extraction.source_used = bodyResult.sourceUsed;
      debug.body_extraction.input_length = bodyResult.inputLength;
      debug.body_extraction.bookings_found = bodyResult.bookings.length;
      debug.body_extraction.error = bodyResult.error;

      allBookings = bodyResult.bookings;
      modelUsed = bodyResult.modelUsed;

      console.log(
        `${TAG} Body extraction (source=${bodyResult.sourceUsed} inputLen=${bodyResult.inputLength}): ${allBookings.length} booking(s)`,
      );
    }

    debug.model.model_used = modelUsed;
    debug.model.raw_candidate_count = allBookings.length;

    // ── Fail if nothing was found ─────────────────────────────────────────
    if (allBookings.length === 0) {
      debug.stage = "failed_no_bookings";
      debug.result = {
        inserted_count: 0,
        final_status: "failed",
        error: "No bookings could be extracted",
      };
      await updateQueueStatus(supabase, row.id, "failed", debug, {
        error_message: "No bookings could be extracted",
      });
      return new Response(
        JSON.stringify({ status: "failed", error: "No bookings extracted" }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    // ── Persist bookings ─────────────────────────────────────────────────
    debug.stage = "persist_bookings";
    const persistResult = await persistBookings(
      supabase,
      allBookings,
      tripId,
      userId,
      messageIdHash,
    );

    debug.model.confidence_rejected = persistResult.confidenceRejected;
    debug.model.duplicate_rejected = persistResult.duplicateRejected;

    // Auto-attach the source PDFs/images to every booking they produced.
    if (persistResult.insertedIds.length > 0 && attResult.successfulAttachments.length > 0) {
      await linkAttachmentsToBookings(
        supabase,
        attResult.successfulAttachments,
        persistResult.insertedIds,
        userId,
      );
    }

    if (persistResult.confidenceRejected === allBookings.length) {
      const errMsg =
        "Model returned bookings but all were below the confidence threshold";
      debug.stage = "failed_low_confidence";
      debug.result = { inserted_count: 0, final_status: "failed", error: errMsg };
      await updateQueueStatus(supabase, row.id, "failed", debug, {
        error_message: errMsg,
      });
      return new Response(
        JSON.stringify({ status: "failed", error: errMsg }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    // ── Success ──────────────────────────────────────────────────────────
    debug.stage = "completed";
    debug.result = {
      inserted_count: persistResult.insertedIds.length,
      final_status: "processed",
      error: null,
    };

    await updateQueueStatus(supabase, row.id, "processed", debug, {
      trip_id: tripId,
      extracted_bookings: allBookings,
    });

    console.log(
      `${TAG} Done: ${persistResult.insertedIds.length}/${allBookings.length} bookings inserted` +
        ` (conf_rejected=${persistResult.confidenceRejected} dup_rejected=${persistResult.duplicateRejected})` +
        ` trip=${tripId}`,
    );

    return new Response(
      JSON.stringify({
        status: "processed",
        trip_id: tripId,
        bookings_created: persistResult.insertedIds.length,
      }),
      { status: 200, headers: CORS_HEADERS },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`${TAG} Unhandled error:`, message);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: CORS_HEADERS },
    );
  }
});
