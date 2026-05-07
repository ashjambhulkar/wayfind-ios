export const ALLOWED_KINDS = [
  "flight",
  "car",
  "lodging",
  "restaurant",
  "train",
  "bus",
  "ferry",
  "cruise",
  "concert",
  "theater",
  "tour",
] as const;

export const ALLOWED_DETAILS_KEYS = new Set([
  "flight_number",
  "airline",
  "seat",
  "terminal",
  "gate",
  "departure_tz",
  "arrival_tz",
  "car_type",
  "license_plate",
  "room_type",
  "guests",
  "address",
  "train_number",
  "route",
  "bus_line",
  "ferry_route",
  "ship_name",
  "cabin",
  "venue",
  "show_name",
  "seat_section",
  "table_party_size",
  "operator",
  "tour_name",
]);

export const MAX_DETAILS_KEYS = 24;
export const MAX_DETAIL_STRING_LEN = 500;
export const MAX_DETAILS_JSON_CHARS = 6000;

export const PRIMARY_MODEL = "gpt-4o-mini";
export const FALLBACK_MODEL = "gpt-4o";
export const CONFIDENCE_THRESHOLD = 0.6;
export const MODEL_TIMEOUT_MS = 30_000;

export const EXTRACTION_PROMPT = `You are a travel booking data extractor. Analyze this booking confirmation document and extract ALL individual bookings found.

A single document may contain multiple bookings — e.g. an outbound and return flight, multiple hotel reservations, or a round-trip train ticket. Extract EACH one as a separate entry.

Return ONLY a valid JSON object with a top-level "bookings" array:
{
  "bookings": [
    {
      "kind": one of: flight | car | lodging | restaurant | train | bus | ferry | cruise | concert | theater | tour,
      "title": "short descriptive title",
      "confirmation_code": "booking reference",
      "provider": "company or operator name",
      "starts_at": "ISO 8601 datetime with timezone",
      "ends_at": "ISO 8601 datetime with timezone",
      "start_location": "departure / pickup / venue / origin",
      "end_location": "arrival / drop-off / null for single-venue (lodging, restaurant, concert, theater, tour)",
      "total_price": number or null,
      "currency": "3-letter code (default USD)",
      "details_json": { optional keys only from: flight_number, airline, seat, terminal, gate, car_type, license_plate, room_type, guests, address, train_number, route, bus_line, ferry_route, ship_name, cabin, venue, show_name, seat_section, table_party_size, operator, tour_name },
      "confidence": number from 0.0 to 1.0
    }
  ]
}

Rules:
- Return one entry per distinct leg/segment/reservation. A round-trip flight = 2 entries. Multiple hotel nights at different properties = separate entries. Same hotel, one stay = 1 entry.
- Flights: title "ORIGIN → DESTINATION" with airport codes when possible. Use ONLY the IATA airport code (e.g. "MCO", "JFK") in start_location and end_location — never append terminal or gate info there. Put terminal in details_json.terminal instead.
- FLIGHT TIMES (critical): starts_at MUST use the departure airport's IANA timezone. ends_at MUST use the arrival airport's IANA timezone. Never apply the same timezone offset to both endpoints. Store the IANA timezone in details_json.departure_tz (e.g. "America/New_York") and details_json.arrival_tz (e.g. "America/Los_Angeles"). Examples: JFK/LGA/EWR → America/New_York; LAX/SFO/SJC → America/Los_Angeles; ORD/MDW → America/Chicago; PHX → America/Phoenix (no DST, always UTC-7); LHR/LGW → Europe/London; CDG/ORY → Europe/Paris; NRT/HND → Asia/Tokyo; DXB → Asia/Dubai. Apply DST correctly for the flight date (e.g. US clocks spring forward on the 2nd Sunday of March, fall back on the 1st Sunday of November; in November New York is EST=UTC-5 not EDT=UTC-4; LA is PST=UTC-8 not PDT=UTC-7).
- Lodging: property name as title; end_location often null.
- Restaurant / concert / theater / tour: venue in start_location; end_location usually null.
- Train / bus / ferry: origin and destination in start_location / end_location.
- Cruise: embark / disembark ports or dates in fields as appropriate.
- Parse dates with timezone when visible.
- Omit null or empty sub-fields from details_json.
- Set confidence from how clearly you could read the document.
- If only one booking exists, still wrap it in the "bookings" array.`;

export const EMAIL_EXTRACTION_PROMPT = `You are a travel booking data extractor. Analyze this forwarded booking confirmation EMAIL and extract ALL individual bookings found.

IMPORTANT: This is a forwarded email. Ignore:
- Forwarded-message headers ("---------- Forwarded message ----------", "From:", "Date:", "Subject:", "To:" lines at the top of the forwarded content)
- Email signatures, footers, unsubscribe links, marketing content, and social media links
- If the email is a thread, focus ONLY on the original booking confirmation, not replies or follow-ups

A single email may contain multiple bookings — e.g. an outbound and return flight, multiple hotel reservations, or a round-trip train ticket. Extract EACH one as a separate entry.

Return ONLY a valid JSON object with a top-level "bookings" array:
{
  "bookings": [
    {
      "kind": one of: flight | car | lodging | restaurant | train | bus | ferry | cruise | concert | theater | tour,
      "title": "short descriptive title",
      "confirmation_code": "booking reference",
      "provider": "company or operator name",
      "starts_at": "ISO 8601 datetime with timezone",
      "ends_at": "ISO 8601 datetime with timezone",
      "start_location": "departure / pickup / venue / origin",
      "end_location": "arrival / drop-off / null for single-venue (lodging, restaurant, concert, theater, tour)",
      "total_price": number or null,
      "currency": "3-letter code (default USD)",
      "details_json": { optional keys only from: flight_number, airline, seat, terminal, gate, car_type, license_plate, room_type, guests, address, train_number, route, bus_line, ferry_route, ship_name, cabin, venue, show_name, seat_section, table_party_size, operator, tour_name },
      "confidence": number from 0.0 to 1.0
    }
  ]
}

Rules:
- Return one entry per distinct leg/segment/reservation. A round-trip flight = 2 entries. Multiple hotel nights at different properties = separate entries. Same hotel, one stay = 1 entry.
- Flights: title "ORIGIN → DESTINATION" with airport codes when possible. Use ONLY the IATA airport code (e.g. "MCO", "JFK") in start_location and end_location — never append terminal or gate info there. Put terminal in details_json.terminal instead.
- FLIGHT TIMES (critical): starts_at MUST use the departure airport's IANA timezone. ends_at MUST use the arrival airport's IANA timezone. Never apply the same timezone offset to both endpoints. Store the IANA timezone in details_json.departure_tz (e.g. "America/New_York") and details_json.arrival_tz (e.g. "America/Los_Angeles"). Examples: JFK/LGA/EWR → America/New_York; LAX/SFO/SJC → America/Los_Angeles; ORD/MDW → America/Chicago; PHX → America/Phoenix (no DST, always UTC-7); LHR/LGW → Europe/London; CDG/ORY → Europe/Paris; NRT/HND → Asia/Tokyo; DXB → Asia/Dubai. Apply DST correctly for the flight date (e.g. US clocks spring forward on the 2nd Sunday of March, fall back on the 1st Sunday of November; in November New York is EST=UTC-5 not EDT=UTC-4; LA is PST=UTC-8 not PDT=UTC-7).
- Lodging: property name as title; end_location often null.
- Restaurant / concert / theater / tour: venue in start_location; end_location usually null.
- Train / bus / ferry: origin and destination in start_location / end_location.
- Cruise: embark / disembark ports or dates in fields as appropriate.
- Parse dates with timezone when visible.
- Omit null or empty sub-fields from details_json.
- Set confidence from how clearly you could read the document.
- If only one booking exists, still wrap it in the "bookings" array.

CRITICAL — accuracy:
- Never invent confirmation codes, airlines, flights, hotels, prices, or dates. Every extracted field must be clearly present as labeled or quoted text in the email body you were given (not from memory or examples).
- If the body is mostly headers, MIME structure, or quoted thread noise and you cannot find explicit reservation details, return {"bookings": []}.
- Do not fill gaps with plausible-looking placeholders. When unsure, return fewer entries or an empty "bookings" array and set confidence low.`;

export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

export function sanitizeDetailsJson(
  raw: unknown,
): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return out;
  }
  const obj = raw as Record<string, unknown>;
  let count = 0;
  for (const [k, v] of Object.entries(obj)) {
    if (count >= MAX_DETAILS_KEYS) break;
    if (!ALLOWED_DETAILS_KEYS.has(k)) continue;
    if (typeof v === "string") {
      const t = v.trim();
      if (t.length === 0) continue;
      out[k] =
        t.length > MAX_DETAIL_STRING_LEN
          ? t.slice(0, MAX_DETAIL_STRING_LEN)
          : t;
      count++;
    } else if (typeof v === "number" && Number.isFinite(v)) {
      out[k] = v;
      count++;
    } else if (typeof v === "boolean") {
      out[k] = v;
      count++;
    }
  }
  while (
    JSON.stringify(out).length > MAX_DETAILS_JSON_CHARS &&
    Object.keys(out).length > 0
  ) {
    const keys = Object.keys(out);
    delete out[keys[keys.length - 1]];
  }
  return out;
}

export function normalizeKind(raw: unknown): string {
  if (typeof raw !== "string") return "flight";
  const k = raw.trim().toLowerCase();
  return (ALLOWED_KINDS as readonly string[]).includes(k) ? k : "flight";
}

export async function callExtractionModel(
  apiKey: string,
  model: string,
  content: Array<Record<string, unknown>>,
  timeoutMs: number,
): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(
      "https://api.openai.com/v1/chat/completions",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        signal: controller.signal,
        body: JSON.stringify({
          model,
          messages: [{ role: "user", content }],
          max_tokens: 4096,
          temperature: 0.1,
          response_format: { type: "json_object" },
        }),
      },
    );

    if (!response.ok) {
      throw new Error(`OpenAI ${model} status ${response.status}`);
    }

    const data = await response.json();
    const raw = data.choices?.[0]?.message?.content;
    if (!raw || typeof raw !== "string") {
      throw new Error(`${model} returned no content`);
    }

    return JSON.parse(raw) as Record<string, unknown>;
  } finally {
    clearTimeout(timer);
  }
}

export interface SafeBooking {
  kind: string;
  title: string | null;
  confirmation_code: string | null;
  provider: string | null;
  starts_at: string | null;
  ends_at: string | null;
  start_location: string | null;
  end_location: string | null;
  total_price: number | null;
  currency: string;
  details_json: Record<string, string | number | boolean>;
  confidence: number;
  model_used: string;
}

function parseTotalPrice(raw: unknown): number | null {
  if (typeof raw === "number") {
    return Number.isFinite(raw) ? raw : null;
  }
  if (typeof raw !== "string") return null;

  const trimmed = raw.trim();
  if (!trimmed) return null;

  // Handle common accounting negatives, e.g. "(1,234.56)".
  const isAccountingNegative =
    trimmed.startsWith("(") && trimmed.endsWith(")");

  // Keep only numeric separators/signs and drop currency symbols / labels.
  const cleaned = trimmed
    .replace(/[^0-9,.\-]/g, "")
    .replace(/(?!^)-/g, "");

  if (!cleaned) return null;

  // Heuristics:
  // - If both separators appear, treat the right-most one as decimal marker.
  // - If only commas and the last group is 2 digits, treat comma as decimal.
  // - Otherwise commas are thousand separators.
  let normalized = cleaned;
  const lastDot = cleaned.lastIndexOf(".");
  const lastComma = cleaned.lastIndexOf(",");

  if (lastDot !== -1 && lastComma !== -1) {
    const decimalIsComma = lastComma > lastDot;
    normalized = decimalIsComma
      ? cleaned.replace(/\./g, "").replace(",", ".")
      : cleaned.replace(/,/g, "");
  } else if (lastComma !== -1 && lastDot === -1) {
    const trailing = cleaned.slice(lastComma + 1);
    normalized = trailing.length === 2
      ? cleaned.replace(/\./g, "").replace(",", ".")
      : cleaned.replace(/,/g, "");
  } else {
    normalized = cleaned.replace(/,/g, "");
  }

  const parsed = Number(normalized);
  if (!Number.isFinite(parsed)) return null;
  return isAccountingNegative ? -Math.abs(parsed) : parsed;
}

function normalizeCurrency(raw: unknown): string {
  if (typeof raw !== "string") return "USD";
  const trimmed = raw.trim();
  if (!trimmed) return "USD";

  const upper = trimmed.toUpperCase();
  if (/^[A-Z]{3}$/.test(upper)) return upper;

  // Common symbol fallbacks when model returns "$", "€", etc.
  const symbolMap: Record<string, string> = {
    "$": "USD",
    "US$": "USD",
    "€": "EUR",
    "£": "GBP",
    "¥": "JPY",
    "₹": "INR",
    "A$": "AUD",
    "C$": "CAD",
  };
  return symbolMap[trimmed] ?? "USD";
}

export function sanitizeBookings(
  extracted: Record<string, unknown>,
  modelUsed: string,
): SafeBooking[] {
  const rawBookings: Record<string, unknown>[] = Array.isArray(
    extracted.bookings,
  )
    ? (extracted.bookings as Record<string, unknown>[])
    : [extracted];

  return rawBookings.map((entry) => {
    const kind = normalizeKind(entry.kind);
    const details = sanitizeDetailsJson(entry.details_json);

    return {
      kind,
      title: typeof entry.title === "string" ? entry.title : null,
      confirmation_code:
        typeof entry.confirmation_code === "string"
          ? entry.confirmation_code
          : null,
      provider: typeof entry.provider === "string" ? entry.provider : null,
      starts_at:
        typeof entry.starts_at === "string" ? entry.starts_at : null,
      ends_at: typeof entry.ends_at === "string" ? entry.ends_at : null,
      start_location:
        typeof entry.start_location === "string"
          ? entry.start_location
          : null,
      end_location:
        typeof entry.end_location === "string" ? entry.end_location : null,
      total_price: parseTotalPrice(entry.total_price),
      currency: normalizeCurrency(entry.currency),
      details_json: details,
      confidence:
        typeof entry.confidence === "number" &&
        entry.confidence >= 0 &&
        entry.confidence <= 1
          ? entry.confidence
          : 0.5,
      model_used: modelUsed,
    };
  });
}

export function getMinConfidence(
  extracted: Record<string, unknown>,
): number {
  const rawBookings = Array.isArray(extracted.bookings)
    ? (extracted.bookings as Record<string, unknown>[])
    : [extracted];
  if (rawBookings.length === 0) return 0.5;
  return Math.min(
    ...rawBookings.map((b) =>
      typeof (b as Record<string, unknown>).confidence === "number"
        ? ((b as Record<string, unknown>).confidence as number)
        : 0.5,
    ),
  );
}
