/**
 * Robust MIME / multipart parser for inbound forwarded travel emails.
 *
 * Handles:
 *  - Gmail (multipart/alternative, base64 bodies)
 *  - Outlook / Exchange / NYU (quoted-printable bodies, multipart/related nesting)
 *  - SendGrid send_raw=true ("email" field with full RFC822 message)
 *  - SendGrid parsed mode (separate "html", "text", attachment fields)
 *  - RFC2231 encoded filenames
 *  - base64 text bodies decoded correctly as UTF-8 (not via atob directly)
 */

export interface ParsedAttachment {
  filename: string;
  contentType: string;
  bytes: Uint8Array;
  discoveredFrom: "mime_attachment" | "multipart_form_field";
}

export interface ParsedEmail {
  html: string;
  text: string;
  attachments: ParsedAttachment[];
}

// ── Byte helpers ───────────────────────────────────────────────────────────

const ENCODER = new TextEncoder();
const DECODER = new TextDecoder("utf-8");
const CRLF_CRLF = ENCODER.encode("\r\n\r\n");
const CRLF = ENCODER.encode("\r\n");

export function byteIndexOf(
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

// ── Content-Transfer-Encoding decoders ────────────────────────────────────

/**
 * Decode quoted-printable text per RFC 2045.
 * Removes soft line breaks (=\r\n or =\n) and decodes =XX sequences.
 */
export function decodeQuotedPrintable(input: string): string {
  return input
    .replace(/=\r\n/g, "")
    .replace(/=\n/g, "")
    .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) =>
      String.fromCharCode(parseInt(hex, 16)),
    );
}

/**
 * Decode base64 text to a UTF-8 string (handles non-ASCII correctly).
 * The naive atob approach returns a raw binary string, causing mojibake for
 * non-Latin characters from Exchange / university email servers.
 */
function decodeBase64Text(b64input: string): string {
  const clean = b64input.replace(/\s/g, "");
  const binStr = atob(clean);
  const bytes = new Uint8Array(binStr.length);
  for (let i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
  return DECODER.decode(bytes);
}

/**
 * Decode base64 to raw bytes (for attachments).
 */
function decodeBase64Bytes(b64input: string): Uint8Array {
  const clean = b64input.replace(/\s/g, "");
  const binStr = atob(clean);
  const bytes = new Uint8Array(binStr.length);
  for (let i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
  return bytes;
}

// ── Header accessors ───────────────────────────────────────────────────────

type TransferEncoding = "base64" | "qp" | "plain";

function getTransferEncoding(headers: string): TransferEncoding {
  const match = headers.match(/Content-Transfer-Encoding:\s*([^\r\n]+)/i);
  const enc = match?.[1]?.trim().toLowerCase() ?? "";
  if (enc === "base64") return "base64";
  if (enc === "quoted-printable") return "qp";
  return "plain";
}

function getContentType(headers: string): string {
  return (
    headers.match(/Content-Type:\s*([^;\r\n]+)/i)?.[1]?.trim().toLowerCase() ??
    ""
  );
}

/**
 * Extract filename from MIME part headers.
 * Priority: RFC2231 (filename*=) → quoted → unquoted.
 * Returns null when no real filename is present.
 */
export function extractFilename(headers: string): string | null {
  // RFC2231: filename*=charset'lang'encoded-value
  const rfc2231 = headers.match(/filename\*\s*=\s*([^\r\n;]+)/i);
  if (rfc2231) {
    const raw = rfc2231[1].trim().replace(/^["']+|["']+$/g, "");
    const parts = raw.split("'");
    if (parts.length >= 3) {
      try {
        const decoded = decodeURIComponent(parts.slice(2).join("'")).trim();
        if (decoded) return decoded;
      } catch {
        // fall through to raw value
      }
    }
    return raw.trim() || null;
  }

  const quoted = headers.match(/filename\s*=\s*"([^"]*)"/i);
  if (quoted) return quoted[1].trim() || null;

  const unquoted = headers.match(/filename\s*=\s*([^;\r\n\s"']+)/i);
  if (unquoted) return unquoted[1].trim() || null;

  return null;
}

// ── Multipart boundary scanner ─────────────────────────────────────────────

function parseMultipartParts(
  raw: Uint8Array,
  boundary: string,
): { headers: string; body: Uint8Array }[] {
  const sep = ENCODER.encode(`--${boundary}`);
  const parts: { headers: string; body: Uint8Array }[] = [];
  let pos = 0;

  while (pos < raw.length) {
    const start = byteIndexOf(raw, sep, pos);
    if (start === -1) break;

    const afterSep = start + sep.length;
    if (afterSep + 2 <= raw.length) {
      if (DECODER.decode(raw.subarray(afterSep, afterSep + 2)) === "--") break;
    }

    const lineEnd = byteIndexOf(raw, CRLF, afterSep);
    if (lineEnd === -1) break;

    const bodyDelim = byteIndexOf(raw, CRLF_CRLF, lineEnd);
    if (bodyDelim === -1) break;

    const headers = DECODER.decode(raw.subarray(lineEnd + 2, bodyDelim));
    const bodyStart = bodyDelim + 4;
    const nextBoundary = byteIndexOf(raw, sep, bodyStart);
    const bodyEnd = nextBoundary === -1 ? raw.length : nextBoundary - 2;

    parts.push({ headers, body: raw.subarray(bodyStart, bodyEnd) });
    pos = nextBoundary === -1 ? raw.length : nextBoundary;
  }

  return parts;
}

// ── Recursive MIME parser ──────────────────────────────────────────────────

/**
 * Recursively parse a MIME multipart body into structured text + attachments.
 * Supports: base64, quoted-printable, plain (7bit/8bit) bodies.
 * Handles: multipart/mixed, multipart/alternative, multipart/related.
 */
export function parseMimeParts(
  raw: Uint8Array,
  contentType: string,
): ParsedEmail {
  const result: ParsedEmail = { html: "", text: "", attachments: [] };

  const boundaryMatch = contentType.match(/boundary="?([^";\s]+)"?/i);
  if (!boundaryMatch) return result;

  const parts = parseMultipartParts(raw, boundaryMatch[1]);

  for (const part of parts) {
    const ct = getContentType(part.headers);
    const enc = getTransferEncoding(part.headers);
    const filename = extractFilename(part.headers);

    // Recurse: multipart/alternative, multipart/related, multipart/mixed, etc.
    if (ct.startsWith("multipart/")) {
      const nested = parseMimeParts(part.body, part.headers);
      if (!result.html && nested.html) result.html = nested.html;
      if (!result.text && nested.text) result.text = nested.text;
      result.attachments.push(...nested.attachments);
      continue;
    }

    // Attachment part (has a real filename)
    if (filename) {
      const bytes =
        enc === "base64"
          ? decodeBase64Bytes(DECODER.decode(part.body))
          : new Uint8Array(part.body);
      result.attachments.push({
        filename,
        contentType: ct || "application/octet-stream",
        bytes,
        discoveredFrom: "mime_attachment",
      });
      continue;
    }

    // HTML body
    if (ct.includes("text/html") && !result.html) {
      result.html = decodeTextPart(part.body, enc);
      continue;
    }

    // Plain text body
    if ((ct.includes("text/plain") || ct === "") && !result.text) {
      result.text = decodeTextPart(part.body, enc);
      continue;
    }
  }

  return result;
}

function decodeTextPart(body: Uint8Array, enc: TransferEncoding): string {
  if (enc === "base64") return decodeBase64Text(DECODER.decode(body));
  if (enc === "qp") return decodeQuotedPrintable(DECODER.decode(body));
  return DECODER.decode(body);
}

// ── Outer form-data parser ─────────────────────────────────────────────────

/**
 * Parse the raw multipart/form-data blob stored by the Cloudflare worker.
 *
 * Handles two SendGrid ingest shapes:
 *  - send_raw=true  → single "email" field containing a full RFC822 MIME message
 *  - Parsed mode    → separate "html", "text", and file attachment fields
 *
 * The "email" field path recurses into parseMimeParts which handles all
 * inner encoding (QP, base64, multipart/related, etc.) correctly.
 */
export function parseRawMultipart(
  raw: Uint8Array,
  contentType: string,
): ParsedEmail {
  const result: ParsedEmail = { html: "", text: "", attachments: [] };

  const boundaryMatch = contentType.match(/boundary="?([^";\s]+)"?/i);
  if (!boundaryMatch) return result;

  const parts = parseMultipartParts(raw, boundaryMatch[1]);

  for (const part of parts) {
    const dispMatch = part.headers.match(
      /Content-Disposition:[^\r\n]*name\s*=\s*"?([^";\r\n]+)"?/i,
    );
    const fieldName = dispMatch?.[1]?.trim().toLowerCase() ?? "";
    const filename = extractFilename(part.headers);
    const ct = getContentType(part.headers);
    const enc = getTransferEncoding(part.headers);

    // SendGrid send_raw=true: entire RFC822 MIME message in one "email" field.
    if (fieldName === "email") {
      // Skip any wrapper CRLF CRLF between form-field headers and RFC822 start
      const headerEnd = byteIndexOf(part.body, CRLF_CRLF);
      if (headerEnd === -1) {
        // No inner headers found — treat whole body as plain text
        result.text = DECODER.decode(part.body);
      } else {
        const mimeHeaders = DECODER.decode(part.body.subarray(0, headerEnd));
        const mimeBody = part.body.subarray(headerEnd + 4);
        const innerCt =
          mimeHeaders.match(/Content-Type:\s*([^\r\n]+)/i)?.[1] ?? "";
        const innerEnc = getTransferEncoding(mimeHeaders);

        if (innerCt.toLowerCase().includes("multipart/")) {
          const parsed = parseMimeParts(mimeBody, innerCt);
          if (parsed.html) result.html = parsed.html;
          if (parsed.text) result.text = parsed.text;
          result.attachments.push(...parsed.attachments);
        } else if (innerCt.toLowerCase().includes("text/html")) {
          result.html = decodeTextPart(mimeBody, innerEnc);
        } else {
          result.text = decodeTextPart(mimeBody, innerEnc);
        }
      }
      continue;
    }

    // Parsed mode: explicit "html" / "text" fields from SendGrid
    if (fieldName === "html" && !result.html) {
      result.html = decodeTextPart(part.body, enc);
      continue;
    }

    if (fieldName === "text" && !result.text) {
      result.text = decodeTextPart(part.body, enc);
      continue;
    }

    // Any part with a non-empty filename is an attachment
    if (filename) {
      const bytes =
        enc === "base64"
          ? decodeBase64Bytes(DECODER.decode(part.body))
          : new Uint8Array(part.body);
      result.attachments.push({
        filename,
        contentType: ct || "application/octet-stream",
        bytes,
        discoveredFrom: "multipart_form_field",
      });
      continue;
    }
  }

  return result;
}

// ── HTML → plain text ──────────────────────────────────────────────────────

/**
 * Strip HTML tags to produce clean plain text for LLM consumption.
 * Preserves paragraph and line breaks as newlines.
 */
export function stripHtmlTags(html: string): string {
  return html
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<\/div>/gi, "\n")
    .replace(/<\/tr>/gi, "\n")
    .replace(/<\/li>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
