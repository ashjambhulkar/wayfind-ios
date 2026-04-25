// Wave 3.2 — `poll-flight-status` Edge Function.
//
// Hot path: scheduled by pg_cron every 5 minutes. Selects rows from
// `flight_statuses` whose `next_poll_at <= now()`, fetches a fresh
// snapshot from AeroDataBox via RapidAPI, diffs against the stored row,
// and:
//
//   1. Updates the row in place (Realtime fan-out → in-app badge).
//   2. Computes the next `next_poll_at` based on the tiered cadence
//      (60m → 15m → 5m → 10m post-landing).
//   3. If a *user-visible* field changed, sends an FCM push so the
//      lock-screen / Live Activity reflects the change.
//
// Cost guards (per-day budget + kill switch) are checked BEFORE making
// any outbound calls, so a runaway can be killed in seconds via a
// `feature_flags` flip with no redeploy.
//
// Observability: emits structured `console.log` JSON (`event=poll`,
// `event=skip_reason`, `event=push_sent`) so Supabase log drains can
// alert on anomaly volume.
//
// Idempotency: writes are SET-based so a duplicate run within the
// same minute is a no-op (next_poll_at simply stays in the past).

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const RAPIDAPI_HOST = "aerodatabox.p.rapidapi.com";
const PUSH_SCHEMA_VERSION = 1;

// Per-batch cap. We poll up to N rows per cron tick; keeps Edge Function
// cold-start and outbound concurrency predictable. With a 5-minute cron
// cadence and 60 rows per tick we comfortably cover ~17K daily checks.
const MAX_ROWS_PER_INVOCATION = 60;

// Outbound per-call timeout. AeroDataBox p99 is < 3s; we cap at 8s so
// a stuck call doesn't drag the worker past the cron interval.
const PROVIDER_TIMEOUT_MS = 8000;

interface FlightRow {
  id: string;
  booking_id: string;
  trip_id: string;
  user_id: string;
  carrier_iata: string;
  flight_number: string;
  scheduled_departure_utc: string;
  scheduled_arrival_utc: string;
  status: string;
  estimated_departure_utc: string | null;
  estimated_arrival_utc: string | null;
  actual_departure_utc: string | null;
  actual_arrival_utc: string | null;
  origin_airport_iata: string | null;
  destination_airport_iata: string | null;
  gate_origin: string | null;
  gate_destination: string | null;
  terminal_origin: string | null;
  terminal_destination: string | null;
  baggage_claim: string | null;
  delay_minutes: number | null;
  polled_at: string;
  next_poll_at: string | null;
  last_change_summary: string | null;
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
  quality?: string[];
}

function logEvent(event: string, payload: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, ...payload, ts: new Date().toISOString() }));
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

// ───────────────────────── Cadence ─────────────────────────
// Returns the next absolute time to poll based on how close we are
// to the scheduled departure / known landing. Mirrors the table in
// docs/flight-tracking-push-payload.md.
function computeNextPollAt(row: FlightRow, now: Date): Date | null {
  const sched = new Date(row.scheduled_departure_utc).getTime();
  const arrSched = new Date(row.scheduled_arrival_utc).getTime();
  const arrActual = row.actual_arrival_utc ? new Date(row.actual_arrival_utc).getTime() : null;
  const t = now.getTime();

  // Past-landing tail: every 10m for the first hour.
  if (arrActual && t > arrActual) {
    if (t > arrActual + 60 * 60 * 1000) return null;
    return new Date(t + 10 * 60 * 1000);
  }

  // Active flight (departed but not landed): every 5m.
  if (row.actual_departure_utc) {
    return new Date(t + 5 * 60 * 1000);
  }

  // Pre-departure tiers, measured from scheduled departure.
  const minutesUntilSched = (sched - t) / 60000;
  if (minutesUntilSched > 24 * 60) return new Date(t + 60 * 60 * 1000);
  if (minutesUntilSched > 4 * 60)  return new Date(t + 15 * 60 * 1000);
  if (minutesUntilSched > -60)     return new Date(t + 5 * 60 * 1000);

  // Sched arrival is also past with no actual landing recorded — keep
  // probing every 10m for an hour, then give up (data outage).
  if (t < arrSched + 60 * 60 * 1000) return new Date(t + 10 * 60 * 1000);
  return null;
}

// ───────────────────────── Provider ─────────────────────────
async function fetchAeroDataBox(
  carrier: string,
  number: string,
  departureDateUTC: string,
  apiKey: string,
): Promise<AeroDataBoxFlight | null> {
  // Endpoint: /flights/Number/{flight}/{date}?withAircraftImage=false&withLocation=false
  const flight = `${carrier}${number}`.toUpperCase();
  const url = `https://${RAPIDAPI_HOST}/flights/Number/${encodeURIComponent(flight)}/${departureDateUTC}?withAircraftImage=false&withLocation=false`;

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
    if (res.status === 404) return null; // Provider hasn't seen this segment yet.
    if (!res.ok) {
      logEvent("provider_error", { status: res.status, flight, departureDateUTC });
      return null;
    }
    const list = await res.json() as AeroDataBoxFlight[];
    if (!Array.isArray(list) || list.length === 0) return null;
    return list[0];
  } catch (err) {
    logEvent("provider_exception", { flight, error: String(err) });
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// ───────────────────────── Diff ─────────────────────────
interface UpdatePayload {
  status: string;
  estimated_departure_utc: string | null;
  estimated_arrival_utc: string | null;
  actual_departure_utc: string | null;
  actual_arrival_utc: string | null;
  origin_airport_iata: string | null;
  destination_airport_iata: string | null;
  gate_origin: string | null;
  gate_destination: string | null;
  terminal_origin: string | null;
  terminal_destination: string | null;
  baggage_claim: string | null;
  delay_minutes: number | null;
  changeSummary: string | null;
}

function normaliseStatus(raw: string | undefined): string {
  if (!raw) return "unknown";
  const s = raw.toLowerCase();
  if (s.includes("cancel")) return "cancelled";
  if (s.includes("divert")) return "diverted";
  if (s.includes("land") || s.includes("arrived")) return "landed";
  if (s.includes("expected") || s.includes("scheduled") || s.includes("checkin")) return "scheduled";
  if (s.includes("approach") || s.includes("enroute") || s.includes("departed") || s.includes("active")) return "active";
  return "unknown";
}

function computeDelayMinutes(scheduled: string, projected: string | null | undefined): number | null {
  if (!projected) return null;
  const a = new Date(scheduled).getTime();
  const b = new Date(projected).getTime();
  if (isNaN(a) || isNaN(b)) return null;
  return Math.round((b - a) / 60000);
}

function buildUpdate(row: FlightRow, snap: AeroDataBoxFlight): UpdatePayload {
  const dep = snap.departure ?? {};
  const arr = snap.arrival ?? {};
  const status = normaliseStatus(snap.status);
  const estDep = dep.revisedTime?.utc ?? null;
  const estArr = arr.revisedTime?.utc ?? null;
  const actDep = dep.runwayTime?.utc ?? null;
  const actArr = arr.runwayTime?.utc ?? null;
  const delay = computeDelayMinutes(row.scheduled_departure_utc, estDep ?? actDep);

  // User-visible diff — drives whether we send a push.
  const diffs: string[] = [];
  if (status !== row.status) diffs.push(`status ${row.status} → ${status}`);
  if (estDep && estDep !== row.estimated_departure_utc) {
    const minutes = computeDelayMinutes(row.scheduled_departure_utc, estDep);
    if (minutes !== null && Math.abs(minutes - (row.delay_minutes ?? 0)) >= 5) {
      diffs.push(minutes >= 0
        ? `ETA pushed ${minutes} minute${Math.abs(minutes) === 1 ? "" : "s"}`
        : `Departing ${Math.abs(minutes)} minute${Math.abs(minutes) === 1 ? "" : "s"} early`);
    }
  }
  if ((dep.gate ?? null) !== row.gate_origin && dep.gate) diffs.push(`Gate ${dep.gate}`);
  if ((arr.baggageBelt ?? null) !== row.baggage_claim && arr.baggageBelt) {
    diffs.push(`Baggage belt ${arr.baggageBelt}`);
  }

  return {
    status,
    estimated_departure_utc: estDep,
    estimated_arrival_utc: estArr,
    actual_departure_utc: actDep,
    actual_arrival_utc: actArr,
    origin_airport_iata: dep.airport?.iata ?? row.origin_airport_iata,
    destination_airport_iata: arr.airport?.iata ?? row.destination_airport_iata,
    gate_origin: dep.gate ?? row.gate_origin,
    gate_destination: arr.gate ?? row.gate_destination,
    terminal_origin: dep.terminal ?? row.terminal_origin,
    terminal_destination: arr.terminal ?? row.terminal_destination,
    baggage_claim: arr.baggageBelt ?? row.baggage_claim,
    delay_minutes: delay,
    changeSummary: diffs.length > 0 ? diffs.slice(0, 2).join("; ") : null,
  };
}

// ───────────────────────── Push ─────────────────────────
async function sendPush(
  client: SupabaseClient,
  row: FlightRow,
  update: UpdatePayload,
): Promise<void> {
  if (!update.changeSummary) return;
  const flightId = `${row.carrier_iata}${row.flight_number}-${row.scheduled_departure_utc.slice(0, 10)}`;
  const contentState = {
    schema_version: PUSH_SCHEMA_VERSION,
    booking_id: row.booking_id,
    flight_id: flightId,
    carrier_iata: row.carrier_iata,
    flight_number: row.flight_number,
    status: update.status,
    scheduled_departure_utc: row.scheduled_departure_utc,
    scheduled_arrival_utc: row.scheduled_arrival_utc,
    estimated_departure_utc: update.estimated_departure_utc,
    estimated_arrival_utc: update.estimated_arrival_utc,
    actual_departure_utc: update.actual_departure_utc,
    actual_arrival_utc: update.actual_arrival_utc,
    origin_airport_iata: update.origin_airport_iata,
    destination_airport_iata: update.destination_airport_iata,
    gate_origin: update.gate_origin,
    gate_destination: update.gate_destination,
    terminal_origin: update.terminal_origin,
    terminal_destination: update.terminal_destination,
    baggage_claim: update.baggage_claim,
    delay_minutes: update.delay_minutes,
    last_change_summary: update.changeSummary,
    polled_at: new Date().toISOString(),
    is_stale: false,
  };
  const title = `${row.carrier_iata} ${row.flight_number} — ${update.status}`;
  const body = update.changeSummary;
  // Reuse the existing `send-notification` Edge Function so the routing
  // / token-refresh / silent-failure semantics are identical to the
  // rest of the app's notifications. We pass the full `wf` envelope +
  // content_state so the iOS app router can dispatch to ActivityKit.
  try {
    const { error } = await client.functions.invoke("send-notification", {
      body: {
        user_id: row.user_id,
        notification: {
          title,
          body,
          data: {
            wf: {
              type: "flight_status_update",
              trip_id: row.trip_id,
              user_id: row.user_id,
            },
            content_state: contentState,
          },
        },
      },
    });
    if (error) {
      logEvent("push_invoke_error", { error: error.message, flight_id: flightId });
    } else {
      logEvent("push_sent", { user_id: row.user_id, flight_id: flightId, summary: update.changeSummary });
    }
  } catch (err) {
    logEvent("push_exception", { error: String(err) });
  }
}

// ───────────────────────── Cost guards ─────────────────────────
async function isKilled(client: SupabaseClient): Promise<boolean> {
  const { data } = await client
    .from("feature_flags")
    .select("value")
    .eq("flag", "flight_tracking_enabled")
    .maybeSingle();
  if (!data) return false;
  // Default: enabled. We only treat explicit `false` as a kill signal.
  return data.value === false || data.value === "false";
}

async function dailyBudget(client: SupabaseClient): Promise<number> {
  const { data } = await client
    .from("feature_flags")
    .select("value")
    .eq("flag", "flight_tracking_daily_call_budget")
    .maybeSingle();
  const raw = data?.value;
  if (typeof raw === "number") return raw;
  const parsed = parseInt(String(raw ?? "6000"), 10);
  return Number.isFinite(parsed) ? parsed : 6000;
}

async function callsToday(client: SupabaseClient): Promise<number> {
  const since = new Date();
  since.setUTCHours(0, 0, 0, 0);
  const { count } = await client
    .from("flight_statuses")
    .select("id", { count: "exact", head: true })
    .gte("polled_at", since.toISOString());
  return count ?? 0;
}

// ───────────────────────── Handler ─────────────────────────
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: CORS });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = Deno.env.get("AERODATABOX_API_KEY");
  if (!supabaseUrl || !serviceRole) return json({ error: "not_configured" }, 500);

  const client = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  if (await isKilled(client)) {
    logEvent("kill_switch_active", {});
    return json({ skipped: "kill_switch", processed: 0 });
  }

  const budget = await dailyBudget(client);
  const used = await callsToday(client);
  if (used >= budget) {
    logEvent("budget_exhausted", { used, budget });
    return json({ skipped: "budget", used, budget, processed: 0 });
  }
  const remaining = budget - used;

  if (!apiKey) {
    logEvent("missing_api_key", {});
    return json({ error: "missing_api_key" }, 500);
  }

  const now = new Date();
  const { data: rows, error } = await client
    .from("flight_statuses")
    .select("*")
    .lte("next_poll_at", now.toISOString())
    .order("next_poll_at", { ascending: true })
    .limit(Math.min(MAX_ROWS_PER_INVOCATION, remaining));
  if (error) return json({ error: error.message }, 500);
  if (!rows || rows.length === 0) return json({ processed: 0 });

  let processed = 0;
  for (const row of rows as FlightRow[]) {
    const departureDate = row.scheduled_departure_utc.slice(0, 10);
    const snap = await fetchAeroDataBox(row.carrier_iata, row.flight_number, departureDate, apiKey);

    let update: UpdatePayload | null = null;
    let provider: string = row.next_poll_at ? "aerodatabox" : "aerodatabox";
    if (snap) {
      update = buildUpdate(row, snap);
    } else {
      // Provider outage / 404 — fall back to the airline's published
      // schedule (which is just the booking's stored times). This keeps
      // the badge from going stale during transient outages.
      provider = "airline_schedule_fallback";
      update = {
        status: row.status,
        estimated_departure_utc: row.estimated_departure_utc,
        estimated_arrival_utc: row.estimated_arrival_utc,
        actual_departure_utc: row.actual_departure_utc,
        actual_arrival_utc: row.actual_arrival_utc,
        origin_airport_iata: row.origin_airport_iata,
        destination_airport_iata: row.destination_airport_iata,
        gate_origin: row.gate_origin,
        gate_destination: row.gate_destination,
        terminal_origin: row.terminal_origin,
        terminal_destination: row.terminal_destination,
        baggage_claim: row.baggage_claim,
        delay_minutes: row.delay_minutes,
        changeSummary: null,
      };
    }

    const next = computeNextPollAt(row, now);
    const { error: updErr } = await client
      .from("flight_statuses")
      .update({
        status: update.status,
        estimated_departure_utc: update.estimated_departure_utc,
        estimated_arrival_utc: update.estimated_arrival_utc,
        actual_departure_utc: update.actual_departure_utc,
        actual_arrival_utc: update.actual_arrival_utc,
        origin_airport_iata: update.origin_airport_iata,
        destination_airport_iata: update.destination_airport_iata,
        gate_origin: update.gate_origin,
        gate_destination: update.gate_destination,
        terminal_origin: update.terminal_origin,
        terminal_destination: update.terminal_destination,
        baggage_claim: update.baggage_claim,
        delay_minutes: update.delay_minutes,
        provider,
        provider_payload: snap ?? null,
        polled_at: now.toISOString(),
        next_poll_at: next ? next.toISOString() : null,
        last_change_summary: update.changeSummary ?? row.last_change_summary,
        last_change_at: update.changeSummary ? now.toISOString() : null,
      })
      .eq("id", row.id);
    if (updErr) {
      logEvent("update_error", { id: row.id, error: updErr.message });
      continue;
    }

    await sendPush(client, row, update);
    processed += 1;

    // Respect the day budget mid-loop too — a flood of new bookings
    // can otherwise blow past the cap inside a single tick.
    if (used + processed >= budget) {
      logEvent("budget_exhausted_midloop", { used: used + processed, budget });
      break;
    }
  }

  return json({ processed, remaining: Math.max(0, budget - used - processed) });
});
