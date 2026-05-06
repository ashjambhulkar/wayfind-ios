/**
 * flight_enrichment.ts — shared helpers for resolving per-airport IANA
 * timezones and correct UTC instants for flight bookings.
 *
 * Priority chain:
 *   1. `airport_timezones` DB cache (populated from AeroDataBox responses).
 *   2. Nothing — caller should fall back to the existing stored value or AI-parsed TZ.
 *
 * This module deliberately does NOT call AeroDataBox directly; that is
 * the job of `lookup-flight` (user-initiated) and `poll-flight-status`
 * (cron-triggered). This keeps enrichment fast and free.
 */

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { normaliseIATA } from "./iata.ts";

export interface AirportTZResult {
  iata: string;
  iana: string | null;
}

/**
 * Looks up the IANA timezone for up to two IATA codes in one DB query.
 * Returns a map of `{ IATA → iana | null }`.
 */
export async function lookupAirportTimezones(
  client: SupabaseClient,
  codes: string[],
): Promise<Map<string, string>> {
  const valid = codes
    .map(normaliseIATA)
    .filter((c): c is string => c !== null);

  if (valid.length === 0) return new Map();

  const { data, error } = await client
    .from("airport_timezones")
    .select("iata, iana")
    .in("iata", valid);

  if (error || !data) return new Map();

  return new Map(data.map((row: { iata: string; iana: string }) => [row.iata, row.iana]));
}

/**
 * Writes an IATA→IANA mapping into the cache.  Uses the DB upsert helper
 * so concurrent writes are idempotent.
 */
export async function cacheAirportTimezone(
  client: SupabaseClient,
  iata: string,
  iana: string,
): Promise<void> {
  const code = normaliseIATA(iata);
  if (!code) return;
  await client.rpc("upsert_airport_timezone", { p_iata: code, p_iana: iana });
}

/**
 * Writes multiple IATA→IANA mappings in one round trip (sequential RPCs).
 */
export async function cacheAirportTimezones(
  client: SupabaseClient,
  entries: Array<{ iata: string; iana: string }>,
): Promise<void> {
  await Promise.all(
    entries
      .filter((e) => normaliseIATA(e.iata) !== null)
      .map((e) => cacheAirportTimezone(client, e.iata, e.iana)),
  );
}

/**
 * Returns `true` when the two UTC instants differ by more than `thresholdMs`.
 * Used to decide whether an enrichment should overwrite an existing value.
 */
export function exceedsThreshold(
  existingUtc: string | null | undefined,
  newUtc: string,
  thresholdMs = 5 * 60 * 1000,
): boolean {
  if (!existingUtc) return true;
  const diff = Math.abs(
    new Date(newUtc).getTime() - new Date(existingUtc).getTime(),
  );
  return diff > thresholdMs;
}
