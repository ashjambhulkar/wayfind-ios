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
 * Byte-level quoted-printable decoder per RFC 2045. Operates directly on the
 * input byte stream so non-ASCII payloads (rare but possible inside a QP
 * message) are preserved exactly. Use this when you intend to feed the
 * result back through a MIME parser rather than display it as text.
 */
export function decodeQuotedPrintableBytes(input: Uint8Array): Uint8Array {
  const out = new Uint8Array(input.length);
  let w = 0;
  for (let r = 0; r < input.length; r++) {
    const b = input[r];
    if (b !== 0x3d /* '=' */) {
      out[w++] = b;
      continue;
    }
    const n1 = input[r + 1];
    const n2 = input[r + 2];
    if (n1 === 0x0d && n2 === 0x0a) {
      r += 2;
      continue;
    }
    if (n1 === 0x0a) {
      r += 1;
      continue;
    }
    if (isHexByte(n1) && isHexByte(n2)) {
      out[w++] = (hexValue(n1) << 4) | hexValue(n2);
      r += 2;
      continue;
    }
    out[w++] = b;
  }
  return out.subarray(0, w);
}

function isHexByte(b: number | undefined): boolean {
  if (b === undefined) return false;
  return (
    (b >= 0x30 && b <= 0x39) ||
    (b >= 0x41 && b <= 0x46) ||
    (b >= 0x61 && b <= 0x66)
  );
}

function hexValue(b: number): number {
  if (b >= 0x30 && b <= 0x39) return b - 0x30;
  if (b >= 0x41 && b <= 0x46) return b - 0x41 + 10;
  return b - 0x61 + 10;
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
 * Extract the value of a named header field from an RFC822 header block,
 * anchored to line starts and with RFC 2822 header folding unrolled first.
 *
 * Plain `header.match(/Content-Type:\s*…/i)` is NOT safe on full RFC822
 * envelopes: DKIM-Signature `h=` parameters list header names separated by
 * colons (e.g. `h=\r\n\tcontent-type:date:from:…`). Without line-start
 * anchoring the regex greedily matches that folded parameter value instead of
 * the real Content-Type field, producing a garbage content-type string.
 */
function extractRfc822Header(headers: string, fieldName: string): string {
  // Unfold RFC 2822 folded headers: a CRLF followed by SP or HT is a
  // continuation of the previous header, not a new field.
  const unfolded = headers.replace(/\r\n[ \t]+/g, " ");
  const re = new RegExp(`(?:^|\\r\\n)${fieldName}:[ \\t]*([^\\r\\n]+)`, "i");
  return unfolded.match(re)?.[1]?.trim() ?? "";
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

// ── RFC822 sniff-and-recurse helper ───────────────────────────────────────

/**
 * Try to parse `raw` as a full RFC822 MIME message (headers + body).
 * Returns the structured ParsedEmail when the content looks like a MIME
 * message with a multipart body; returns null otherwise.
 *
 * This is needed because some SendGrid configurations (and certain Gmail
 * forwarding paths) place the entire raw RFC822 email into the form-data
 * "text" or unnamed field instead of creating a proper "email" field.
 */
function tryParseAsRfc822(raw: Uint8Array): ParsedEmail | null {
  const headerEnd = byteIndexOf(raw, CRLF_CRLF);
  if (headerEnd === -1) return null;

  const headers = DECODER.decode(raw.subarray(0, headerEnd));
  // Must look like an RFC822 envelope (has MIME or email headers near the top)
  const looksLikeRfc822 =
    /^(MIME-Version:|Content-Type:|From:|Received:|Message-ID:|Message-Id:)/im.test(
      headers,
    );
  if (!looksLikeRfc822) return null;

  const innerCt = extractRfc822Header(headers, "Content-Type");
  if (!innerCt) return null;

  const body = raw.subarray(headerEnd + 4);

  if (innerCt.toLowerCase().includes("multipart/")) {
    const parsed = parseMimeParts(body, innerCt);
    // Only consider this a successful RFC822 parse if we found something
    // meaningful (text, html, or attachments).
    if (parsed.text || parsed.html || parsed.attachments.length > 0) {
      return parsed;
    }
    return null;
  }

  // Single-part messages with a recognisable content type
  const innerEnc = getTransferEncoding(headers);
  if (innerCt.toLowerCase().includes("text/html")) {
    return { html: decodeTextPart(body, innerEnc), text: "", attachments: [] };
  }
  if (innerCt.toLowerCase().includes("text/plain")) {
    return { html: "", text: decodeTextPart(body, innerEnc), attachments: [] };
  }

  return null;
}

/**
 * Content-sniff whether `raw` looks like a quoted-printable-encoded RFC822
 * email body. The form-field's `Content-Transfer-Encoding` header is
 * unreliable — NYU/Exchange forwards a fully QP-encoded RFC822 payload
 * inside a SendGrid `text` field that declares 8bit transport. The only
 * reliable signal is the QP shape of the bytes themselves.
 */
function looksLikeQuotedPrintableEmail(raw: Uint8Array): boolean {
  if (raw.length === 0) return false;
  // Scan up to the first 8 KB as latin1 so every byte maps 1:1 to a char.
  const sample = new TextDecoder("latin1").decode(
    raw.subarray(0, Math.min(raw.length, 8192)),
  );

  // High-signal markers: QP-encoded RFC822 header names.
  if (
    sample.includes("Content-Type=3A") ||
    sample.includes("MIME-Version=3A") ||
    sample.includes("Content-Transfer-Encoding=3A") ||
    sample.includes("From=3A") ||
    sample.includes("=0D=0A")
  ) {
    return true;
  }

  // Generic fallback: many `=XX` hex escapes within the first 8 KB. Plain
  // text bodies almost never contain four or more such tokens.
  const escapes = sample.match(/=[0-9A-Fa-f]{2}/g);
  return (escapes?.length ?? 0) >= 4;
}

/**
 * Resolve a form-data field that may carry a nested RFC822 message into a
 * structured ParsedEmail. Tries (in order):
 *
 *   1. Decode the form-field-level transfer encoding when it is `base64`
 *      (uncommon, but mandatory when present).
 *   2. Parse the bytes as RFC822 as-is.
 *   3. If that fails and the bytes look QP-encoded by content (regardless of
 *      what the form header claims), QP-decode and parse again.
 *
 * Returns `null` when no nested RFC822 message can be recovered, in which
 * case the caller should treat the field as an ordinary text/html body.
 */
function tryNestedRfc822Field(
  body: Uint8Array,
  enc: TransferEncoding,
): ParsedEmail | null {
  // Honor an explicit `base64` form-field encoding before sniffing — the
  // bytes are unreadable until decoded.
  const candidate =
    enc === "base64" ? decodeBase64Bytes(DECODER.decode(body)) : body;

  const direct = tryParseAsRfc822(candidate);
  if (direct) return direct;

  // Content-sniff for QP. Also runs when the form header *did* say `qp`,
  // since the sniff is a strict superset of that case.
  if (enc === "qp" || looksLikeQuotedPrintableEmail(candidate)) {
    try {
      const decoded = decodeQuotedPrintableBytes(candidate);
      const nested = tryParseAsRfc822(decoded);
      if (nested) return nested;
    } catch {
      // Fall through to "no nested email".
    }
  }

  return null;
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
 *
 * Edge-case: some Gmail forwarding paths put the complete raw RFC822 message
 * (including base64-encoded attachments) into the "text" form field instead
 * of a proper "email" field.  We sniff for this and recurse accordingly.
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
        const innerCt = extractRfc822Header(mimeHeaders, "Content-Type");
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

    // Parsed mode: explicit "html" / "text" fields from SendGrid.
    // Before treating the value as plain text, check whether it is actually
    // a full RFC822 MIME message that landed in the wrong field.
    // NYU/Exchange QP-encodes the entire forwarded RFC822 message inside a
    // SendGrid `text` field that declares 8bit transport, so we cannot
    // trust the form-field header — `tryNestedRfc822Field` content-sniffs.
    if (fieldName === "html" && !result.html) {
      const nested = tryNestedRfc822Field(part.body, enc);
      if (nested) {
        if (nested.html) result.html = nested.html;
        if (nested.text && !result.text) result.text = nested.text;
        result.attachments.push(...nested.attachments);
      } else {
        result.html = decodeTextPart(part.body, enc);
      }
      continue;
    }

    if (fieldName === "text" && !result.text) {
      const nested = tryNestedRfc822Field(part.body, enc);
      if (nested) {
        if (nested.html && !result.html) result.html = nested.html;
        if (nested.text) result.text = nested.text;
        result.attachments.push(...nested.attachments);
      } else {
        result.text = decodeTextPart(part.body, enc);
      }
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
