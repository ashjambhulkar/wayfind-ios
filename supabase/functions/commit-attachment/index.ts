// Wave 0 (shared infra) — `commit-attachment` Edge Function.
//
// Plan §0.5 E2: prevents the 6th-photo orphan race. Two devices uploading
// concurrently could both pass the client-side max-5 check, both upload
// bytes to storage, then only one INSERT survives the `enforce_trip_activity_max_photos`
// trigger — leaving an orphaned storage object whose row was never written.
//
// Strategy: clients call this function INSTEAD of writing storage directly.
// The function:
//   1. Authenticates the caller (must be an editor on the parent trip).
//   2. Inserts the metadata row first, atomically respecting any server-side
//      cap triggers. If the trigger rejects, we never touch storage.
//   3. Returns a signed UPLOAD URL for the bucket+path so the client streams
//      bytes after we have a guaranteed row id.
//   4. On subsequent client-side upload failure, the row's BEFORE DELETE
//      trigger queues storage cleanup via `pending_storage_deletions`.
//
// Surfaces:
//   - kind=trip_activity_attachment  → table trip_activity_attachments,
//     bucket activity-attachments
//   - kind=trip_booking_attachment   → table trip_booking_attachments,
//     bucket booking-attachments
//   - kind=trip_document             → table trip_documents,
//     bucket trip-documents
//   - kind=trip_expense_attachment   → table trip_expense_attachments,
//     bucket expense-receipts
//
// All four follow the same insert-then-upload pattern. The function returns
// `{ row_id, storage_path, signed_upload_url, expires_at }`.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const ALLOWED_MIME = new Set([
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/heif",
  "image/webp",
  "application/pdf",
]);

const HARD_BYTE_LIMIT = 25 * 1024 * 1024; // 25 MB per plan §0.5 E4

type Kind =
  | "trip_activity_attachment"
  | "trip_booking_attachment"
  | "trip_document"
  | "trip_expense_attachment";

interface CommitBody {
  kind?: Kind;
  trip_id?: string;
  parent_id?: string;
  file_name?: string;
  mime_type?: string;
  byte_size?: number;
  attachment_type?: "photo" | "file" | "link";
  is_cover?: boolean;
  title?: string | null;
  category?: string | null;
}

interface SurfaceConfig {
  table: string;
  bucket: string;
  parentColumn: string;
  buildPath: (params: {
    userId: string;
    tripId: string;
    parentId: string;
    fileExt: string;
  }) => string;
  buildRow: (params: {
    userId: string;
    tripId: string;
    parentId: string;
    body: CommitBody;
    storagePath: string;
  }) => Record<string, unknown>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

function fileExtension(name: string, mime: string): string {
  const lastDot = name.lastIndexOf(".");
  if (lastDot > 0 && lastDot < name.length - 1) {
    const ext = name.slice(lastDot + 1).toLowerCase();
    if (/^[a-z0-9]{1,8}$/.test(ext)) return ext;
  }
  switch (mime) {
    case "image/jpeg": return "jpg";
    case "image/png": return "png";
    case "image/heic":
    case "image/heif": return "heic";
    case "image/webp": return "webp";
    case "application/pdf": return "pdf";
    default: return "bin";
  }
}

const SURFACES: Record<Kind, SurfaceConfig> = {
  trip_activity_attachment: {
    table: "trip_activity_attachments",
    bucket: "activity-attachments",
    parentColumn: "activity_id",
    buildPath: ({ userId, tripId, parentId, fileExt }) =>
      `${userId}/${tripId}/${parentId}/${crypto.randomUUID()}.${fileExt}`,
    buildRow: ({ userId, tripId, parentId, body, storagePath }) => ({
      activity_id: parentId,
      trip_id: tripId,
      user_id: userId,
      attachment_type: body.attachment_type ?? "photo",
      storage_path: storagePath,
      original_filename: body.file_name ?? null,
      mime_type: body.mime_type ?? null,
      file_size_bytes: body.byte_size ?? null,
      label: body.title ?? null,
      is_cover: body.is_cover ?? false,
    }),
  },
  trip_booking_attachment: {
    table: "trip_booking_attachments",
    bucket: "booking-attachments",
    parentColumn: "booking_id",
    buildPath: ({ userId, parentId, fileExt }) =>
      `${userId}/${parentId}/${crypto.randomUUID()}.${fileExt}`,
    buildRow: ({ userId, parentId, body, storagePath }) => ({
      booking_id: parentId,
      user_id: userId,
      storage_path: storagePath,
      original_filename: body.file_name ?? null,
      mime_type: body.mime_type ?? null,
      file_size_bytes: body.byte_size ?? null,
    }),
  },
  trip_document: {
    table: "trip_documents",
    bucket: "trip-documents",
    parentColumn: "trip_id",
    buildPath: ({ userId, tripId, fileExt }) =>
      `${userId}/trip-documents/${tripId}/${crypto.randomUUID()}.${fileExt}`,
    buildRow: ({ userId, tripId, body, storagePath }) => ({
      trip_id: tripId,
      uploaded_by: userId,
      storage_path: storagePath,
      file_name: body.file_name ?? "untitled",
      mime_type: body.mime_type ?? "application/octet-stream",
      byte_size: body.byte_size ?? 0,
      title: body.title ?? null,
      category: body.category ?? null,
    }),
  },
  trip_expense_attachment: {
    table: "trip_expense_attachments",
    bucket: "expense-receipts",
    parentColumn: "expense_id",
    buildPath: ({ userId, tripId, parentId, fileExt }) =>
      `${userId}/${tripId}/${parentId}/${crypto.randomUUID()}.${fileExt}`,
    buildRow: ({ userId, tripId, parentId, body, storagePath }) => ({
      expense_id: parentId,
      trip_id: tripId,
      user_id: userId,
      storage_path: storagePath,
      original_filename: body.file_name ?? null,
      mime_type: body.mime_type ?? null,
      file_size_bytes: body.byte_size ?? null,
    }),
  },
};

async function getUser(client: SupabaseClient, jwt: string) {
  const { data, error } = await client.auth.getUser(jwt);
  if (error || !data?.user) return null;
  return data.user;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const auth = req.headers.get("Authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!jwt) return json({ error: "unauthorized" }, 401);

  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const user = await getUser(anon, jwt);
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: CommitBody;
  try {
    body = (await req.json()) as CommitBody;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (!body.kind || !(body.kind in SURFACES)) {
    return json({ error: "invalid_kind" }, 400);
  }
  if (!body.trip_id) return json({ error: "trip_id_required" }, 400);
  if (!body.parent_id) return json({ error: "parent_id_required" }, 400);
  if (!body.file_name) return json({ error: "file_name_required" }, 400);
  if (!body.mime_type || !ALLOWED_MIME.has(body.mime_type)) {
    return json({ error: "mime_not_allowed", detail: body.mime_type }, 415);
  }
  if (typeof body.byte_size !== "number" || body.byte_size < 0) {
    return json({ error: "byte_size_required" }, 400);
  }
  if (body.byte_size > HARD_BYTE_LIMIT) {
    return json({ error: "file_too_large", limit_bytes: HARD_BYTE_LIMIT }, 413);
  }

  const surface = SURFACES[body.kind];
  const ext = fileExtension(body.file_name, body.mime_type);
  const storagePath = surface.buildPath({
    userId: user.id,
    tripId: body.trip_id,
    parentId: body.parent_id,
    fileExt: ext,
  });

  const row = surface.buildRow({
    userId: user.id,
    tripId: body.trip_id,
    parentId: body.parent_id,
    body,
    storagePath,
  });

  // Insert as the user (RLS + caps apply). Service role is only used to
  // mint the signed upload URL after the row insert succeeds.
  const { data: inserted, error: insertErr } = await anon
    .from(surface.table)
    .insert(row)
    .select("id")
    .single();

  if (insertErr) {
    const detail = insertErr.message ?? "insert_failed";
    if (detail.includes("ACTIVITY_PHOTO_LIMIT")) {
      return json({ error: "limit_reached", detail: "activity_photo_limit", surface: body.kind }, 409);
    }
    return json({ error: "insert_failed", detail }, 400);
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: signed, error: signErr } = await admin.storage
    .from(surface.bucket)
    .createSignedUploadUrl(storagePath);

  if (signErr || !signed) {
    // Roll back the row so we don't leak metadata for an upload that can't happen.
    await anon.from(surface.table).delete().eq("id", inserted.id);
    return json({ error: "signed_url_failed", detail: signErr?.message }, 500);
  }

  return json({
    row_id: inserted.id,
    bucket: surface.bucket,
    storage_path: storagePath,
    signed_upload_url: signed.signedUrl,
    token: signed.token,
    expires_in_seconds: 60 * 60,
  });
});
