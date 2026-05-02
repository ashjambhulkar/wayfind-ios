/**
 * Google Places `regularOpeningHours` (JSONB) helpers for Change 9 TTDP.
 * `weekday`: 0 = Sunday … 6 = Saturday (matches `Date#getDay()`).
 */

export type OpeningHoursPeriod = {
  open?: { day?: number; hour?: number; minute?: number };
  close?: { day?: number; hour?: number; minute?: number };
};

export type RegularOpeningHoursShape = {
  periods?: OpeningHoursPeriod[];
};

function toMinutes(hour: number, minute: number): number {
  return hour * 60 + minute;
}

function periodsArray(openingHours: unknown): OpeningHoursPeriod[] | null {
  if (!openingHours || typeof openingHours !== "object") return null;
  const oh = openingHours as Record<string, unknown>;
  const periods = oh.periods;
  if (!Array.isArray(periods) || periods.length === 0) return null;
  return periods as OpeningHoursPeriod[];
}

/**
 * True when structured hours exist and **no** period opens on `dayOfWeek`.
 * No / empty periods → **false** (treat as unknown / assume open for TTDP).
 */
export function isClosedOnDay(
  openingHours: unknown,
  dayOfWeek: number,
): boolean {
  const periods = periodsArray(openingHours);
  if (!periods) return false;
  return !periods.some((p) => p.open?.day === dayOfWeek);
}

/**
 * Minutes from midnight on `dayOfWeek` for earliest open or latest close among
 * periods whose **open.day** equals `dayOfWeek` (split hours: first open, last close).
 *
 * - No / invalid / empty `periods` → **null** (no constraint; TTDP treats as open).
 * - Periods exist but **none** for this weekday → **0** for both open and close (closed marker; use with `isClosedOnDay`).
 * - Close on a different calendar day than open → cap that close at **1440** (end of local day).
 * - A matching period with no `close` time → **1440** for `"close"` (open 24h that segment).
 */
export function parseOpeningHour(
  openingHours: unknown,
  dayOfWeek: number,
  which: "open" | "close",
): number | null {
  const periods = periodsArray(openingHours);
  if (!periods) return null;

  const todayPeriods = periods.filter((p) => p.open?.day === dayOfWeek);
  if (todayPeriods.length === 0) {
    return which === "open" ? 0 : 0;
  }

  if (which === "open") {
    let earliest = Number.POSITIVE_INFINITY;
    for (const p of todayPeriods) {
      if (p.open?.hour == null) continue;
      const min = toMinutes(p.open.hour ?? 0, p.open.minute ?? 0);
      if (min < earliest) earliest = min;
    }
    return earliest === Number.POSITIVE_INFINITY ? null : earliest;
  }

  for (const p of todayPeriods) {
    if (p.close?.hour == null) {
      return 1440;
    }
  }

  let latest = 0;
  for (const p of todayPeriods) {
    const h = p.close!.hour ?? 0;
    const m = p.close!.minute ?? 0;
    let min = toMinutes(h, m);
    if (p.close!.day != null && p.close!.day !== dayOfWeek) {
      min = 1440;
    }
    if (min > latest) latest = min;
  }

  return latest === 0 ? null : latest;
}



