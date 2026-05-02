import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  captureException,
  errorMessage,
  initSentry,
  safeLog,
} from "../_shared/observability.ts";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const RAPIDAPI_HOST = "aerodatabox.p.rapidapi.com";
const PROVIDER_TIMEOUT_MS = 8000;
const FUNCTION_NAME = "lookup-flight";

interface LookupFlightRequest {
  carrier_iata?: string;
  flight_number?: string;
  departure_date?: string;
}

interface AeroDataBoxFlight {
  status?: string;
  departure?: AeroDataBoxLeg;
  arrival?: AeroDataBoxLeg;
}

interface AeroDataBoxLeg {
  airport?: { iata?: string };
  scheduledTime?: { utc?: string };
  revisedTime?: { utc?: string };
  runwayTime?: { utc?: string };
  gate?: string;
  terminal?: string;
  baggageBelt?: string;
}

interface LookupAudit {
  userId?: string | null;
  carrier?: string | null;
  flightNumber?: string | null;
  departureDate?: string | null;
  status: "found" | "not_found" | "error";
  reason?: string | null;
  httpStatus?: number | null;
  origin?: string | null;
  destination?: string | null;
  metadata?: Record<string, unknown>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

function logEvent(event: string, payload: Record<string, unknown>): void {
  const level = event.includes("error") || event.includes("exception") || event.includes("failed")
    ? "warn"
    : "info";
  safeLog(level, FUNCTION_NAME, event, payload);
}

function normalizeCarrier(value: string | undefined): string | null {
  const normalized = (value ?? "").trim().toUpperCase();
  return /^[A-Z0-9]{2,3}$/.test(normalized) ? normalized : null;
}

function normalizeFlightNumber(value: string | undefined, carrier: string): string | null {
  let normalized = (value ?? "").trim().toUpperCase().replace(/\s+/g, "");
  if (normalized.startsWith(carrier)) normalized = normalized.slice(carrier.length);
  return /^[0-9A-Z]{1,6}$/.test(normalized) ? normalized : null;
}

function normalizeDepartureDate(value: string | undefined): string | null {
  const normalized = (value ?? "").trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(normalized) ? normalized : null;
}

function auditClient(): SupabaseClient | null {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) return null;
  return createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });
}

function userIdFromAuthHeader(req: Request): string | null {
  const value = req.headers.get("authorization") ?? "";
  const token = value.replace(/^Bearer\s+/i, "");
  const payload = token.split(".")[1];
  if (!payload) return null;

  try {
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(normalized.length + ((4 - normalized.length % 4) % 4), "=");
    const json = atob(padded);
    const claims = JSON.parse(json) as { sub?: string };
    return claims.sub ?? null;
  } catch {
    return null;
  }
}

async function recordLookupAttempt(client: SupabaseClient | null, audit: LookupAudit): Promise<void> {
  if (!client) return;
  const { error } = await client.from("flight_lookup_attempts").insert({
    user_id: audit.userId ?? null,
    carrier_iata: audit.carrier ?? null,
    flight_number: audit.flightNumber ?? null,
    departure_date: audit.departureDate ?? null,
    status: audit.status,
    reason: audit.reason ?? null,
    http_status: audit.httpStatus ?? null,
    origin_airport_iata: audit.origin ?? null,
    destination_airport_iata: audit.destination ?? null,
    metadata: audit.metadata ?? {},
  });
  if (error) {
    logEvent("lookup_audit_insert_failed", { error: error.message });
  }
}

async function fetchAeroDataBox(
  carrier: string,
  number: string,
  departureDate: string,
  apiKey: string,
): Promise<AeroDataBoxFlight | null> {
  const flight = `${carrier}${number}`.toUpperCase();
  const url = `https://${RAPIDAPI_HOST}/flights/Number/${encodeURIComponent(flight)}/${departureDate}?withAircraftImage=false&withLocation=false`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);

  try {
    const res = await fetch(url, {
      method: "GET",
      signal: controller.signal,
      headers: {
        "X-RapidAPI-Key": apiKey,
        "X-RapidAPI-Host": RAPIDAPI_HOST,
      },
    });
    if (res.status === 404) return null;
    if (!res.ok) {
      logEvent("lookup_provider_error", { status: res.status, flight, departureDate });
      throw new Error(`provider_${res.status}`);
    }

    const list = await res.json() as AeroDataBoxFlight[];
    if (!Array.isArray(list) || list.length === 0) return null;
    return list[0];
  } finally {
    clearTimeout(timer);
  }
}

serve(async (req) => {
  initSentry();

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: CORS });
  }
  if (req.method !== "POST") return json({ status: "error", reason: "method_not_allowed" }, 405);

  const apiKey = Deno.env.get("AERODATABOX_API_KEY");
  const audits = auditClient();
  const userId = userIdFromAuthHeader(req);
  if (!apiKey) {
    await recordLookupAttempt(audits, {
      userId,
      status: "error",
      reason: "missing_api_key",
      httpStatus: 500,
    });
    return json({ status: "error", reason: "missing_api_key" }, 500);
  }

  let body: LookupFlightRequest;
  try {
    body = await req.json();
  } catch {
    await recordLookupAttempt(audits, {
      userId,
      status: "error",
      reason: "invalid_json",
      httpStatus: 400,
    });
    return json({ status: "error", reason: "invalid_json" }, 400);
  }

  const carrier = normalizeCarrier(body.carrier_iata);
  if (!carrier) {
    await recordLookupAttempt(audits, {
      userId,
      carrier: body.carrier_iata ?? null,
      flightNumber: body.flight_number ?? null,
      departureDate: body.departure_date ?? null,
      status: "error",
      reason: "invalid_carrier_iata",
      httpStatus: 400,
    });
    return json({ status: "error", reason: "invalid_carrier_iata" }, 400);
  }

  const flightNumber = normalizeFlightNumber(body.flight_number, carrier);
  if (!flightNumber) {
    await recordLookupAttempt(audits, {
      userId,
      carrier,
      flightNumber: body.flight_number ?? null,
      departureDate: body.departure_date ?? null,
      status: "error",
      reason: "invalid_flight_number",
      httpStatus: 400,
    });
    return json({ status: "error", reason: "invalid_flight_number" }, 400);
  }

  const departureDate = normalizeDepartureDate(body.departure_date);
  if (!departureDate) {
    await recordLookupAttempt(audits, {
      userId,
      carrier,
      flightNumber,
      departureDate: body.departure_date ?? null,
      status: "error",
      reason: "invalid_departure_date",
      httpStatus: 400,
    });
    return json({ status: "error", reason: "invalid_departure_date" }, 400);
  }

  try {
    const snap = await fetchAeroDataBox(carrier, flightNumber, departureDate, apiKey);
    if (!snap) {
      logEvent("lookup_not_found", { carrier, flightNumber, departureDate });
      await recordLookupAttempt(audits, {
        userId,
        carrier,
        flightNumber,
        departureDate,
        status: "not_found",
        reason: "provider_returned_no_segments",
        httpStatus: 200,
      });
      return json({
        status: "not_found",
        carrier_iata: carrier,
        flight_number: flightNumber,
        departure_date: departureDate,
      });
    }

    const scheduledDepartureUTC = snap.departure?.scheduledTime?.utc ?? null;
    const scheduledArrivalUTC = snap.arrival?.scheduledTime?.utc ?? null;
    if (!scheduledDepartureUTC || !scheduledArrivalUTC) {
      logEvent("lookup_incomplete_schedule", {
        carrier,
        flightNumber,
        departureDate,
        hasDeparture: Boolean(scheduledDepartureUTC),
        hasArrival: Boolean(scheduledArrivalUTC),
      });
      await recordLookupAttempt(audits, {
        userId,
        carrier,
        flightNumber,
        departureDate,
        status: "not_found",
        reason: "incomplete_provider_schedule",
        httpStatus: 200,
        origin: snap.departure?.airport?.iata ?? null,
        destination: snap.arrival?.airport?.iata ?? null,
        metadata: {
          hasDeparture: Boolean(scheduledDepartureUTC),
          hasArrival: Boolean(scheduledArrivalUTC),
        },
      });
      return json({
        status: "not_found",
        reason: "incomplete_provider_schedule",
        carrier_iata: carrier,
        flight_number: flightNumber,
        departure_date: departureDate,
      });
    }

    logEvent("lookup_found", {
      carrier,
      flightNumber,
      departureDate,
      origin: snap.departure?.airport?.iata ?? null,
      destination: snap.arrival?.airport?.iata ?? null,
    });
    await recordLookupAttempt(audits, {
      userId,
      carrier,
      flightNumber,
      departureDate,
      status: "found",
      httpStatus: 200,
      origin: snap.departure?.airport?.iata ?? null,
      destination: snap.arrival?.airport?.iata ?? null,
    });

    return json({
      status: "found",
      carrier_iata: carrier,
      flight_number: flightNumber,
      departure_date: departureDate,
      lookup_verified: true,
      origin_airport_iata: snap.departure?.airport?.iata ?? null,
      destination_airport_iata: snap.arrival?.airport?.iata ?? null,
      scheduled_departure_utc: scheduledDepartureUTC,
      scheduled_arrival_utc: scheduledArrivalUTC,
      terminal_origin: snap.departure?.terminal ?? null,
      terminal_destination: snap.arrival?.terminal ?? null,
      gate_origin: snap.departure?.gate ?? null,
      gate_destination: snap.arrival?.gate ?? null,
      baggage_claim: snap.arrival?.baggageBelt ?? null,
      provider: "aerodatabox",
      provider_payload: snap,
    });
  } catch (error) {
    logEvent("lookup_provider_exception", {
      carrier,
      flightNumber,
      departureDate,
      error: errorMessage(error),
    });
    await captureException(error, {
      fn: FUNCTION_NAME,
      reason: "provider_unavailable",
      fields: {
        carrier,
        flightNumber,
        departureDate,
      },
    });
    await recordLookupAttempt(audits, {
      userId,
      carrier,
      flightNumber,
      departureDate,
      status: "error",
      reason: "provider_unavailable",
      httpStatus: 502,
      metadata: { error: errorMessage(error) },
    });
    return json({ status: "error", reason: "provider_unavailable" }, 502);
  }
});
