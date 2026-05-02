// Wave 2.2a — currency-rates Edge Function.
//
// Frankfurter is our day-1 default for currency conversion. Audit
// (April 2026) of plan-listed travel currencies:
//
//   • INR — ✅ supported by Frankfurter
//   • THB — ✅ supported by Frankfurter
//   • BRL — ✅ supported by Frankfurter
//   • IDR — ✅ supported by Frankfurter
//   • AED — ❌ NOT supported by Frankfurter (no Gulf states coverage)
//
// To avoid dropping travelers heading to Dubai / Abu Dhabi we fan out
// to a backup provider (exchangerate.host) when Frankfurter returns 404
// for a currency. Both providers are free, no-auth, and CORS-friendly.
//
// Request:
//   GET /currency-rates?base=USD&symbols=AED,EUR,JPY&date=2026-04-25
//
// `date` is optional (defaults to "latest"). When provided it must be
// YYYY-MM-DD. Frankfurter exposes daily ECB-style rates 1999→present.
//
// Response:
//   { base: "USD", date: "2026-04-25",
//     rates: { AED: 3.673, EUR: 0.92, JPY: 152.4 },
//     missing: [],
//     source: { primary: "frankfurter", fallback: ["exchangerate.host"] } }
//
// On total failure (both providers down) returns 502 with `{ error }`
// so the iOS layer knows to fall back to its yesterday-cache.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};

const FRANKFURTER_SUPPORTED = new Set([
  "AUD","BRL","CAD","CHF","CNY","CZK","DKK","EUR","GBP","HKD","HUF","IDR",
  "ILS","INR","ISK","JPY","KRW","MXN","MYR","NOK","NZD","PHP","PLN","RON",
  "SEK","SGD","THB","TRY","USD","ZAR",
]);

interface RatesResponse {
  base: string;
  date: string;
  rates: Record<string, number>;
  missing: string[];
  source: { primary: string; fallback: string[] };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function fetchFromFrankfurter(
  base: string,
  symbols: string[],
  date: string,
): Promise<{ date: string; rates: Record<string, number> } | null> {
  const supported = symbols.filter((s) => FRANKFURTER_SUPPORTED.has(s));
  if (supported.length === 0) return { date, rates: {} };
  const path = date === "latest" ? "latest" : date;
  const url = `https://api.frankfurter.app/${path}?from=${encodeURIComponent(base)}&to=${supported.join(",")}`;
  try {
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const body = await res.json();
    return { date: body?.date ?? date, rates: body?.rates ?? {} };
  } catch {
    return null;
  }
}

async function fetchFromExchangerateHost(
  base: string,
  symbols: string[],
  date: string,
): Promise<Record<string, number>> {
  if (symbols.length === 0) return {};
  const path = date === "latest" ? "latest" : date;
  const url = `https://api.exchangerate.host/${path}?base=${encodeURIComponent(base)}&symbols=${symbols.join(",")}`;
  try {
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return {};
    const body = await res.json();
    return body?.rates ?? {};
  } catch {
    return {};
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "GET") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const url = new URL(req.url);
  const base = (url.searchParams.get("base") ?? "USD").toUpperCase();
  const symbolsRaw = url.searchParams.get("symbols") ?? "";
  const date = url.searchParams.get("date") ?? "latest";

  const symbols = symbolsRaw
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter((s) => /^[A-Z]{3}$/.test(s));

  if (symbols.length === 0) {
    return json({ error: "missing_symbols" }, 400);
  }

  const primary = await fetchFromFrankfurter(base, symbols, date);
  const aggregateRates: Record<string, number> = primary?.rates ? { ...primary.rates } : {};
  const usedFallbacks: string[] = [];
  const stillMissing: string[] = [];

  const missingFromPrimary = symbols.filter((s) => !(s in aggregateRates));
  if (missingFromPrimary.length > 0) {
    const fallback = await fetchFromExchangerateHost(base, missingFromPrimary, date);
    for (const [k, v] of Object.entries(fallback)) {
      aggregateRates[k] = v;
    }
    if (Object.keys(fallback).length > 0) {
      usedFallbacks.push("exchangerate.host");
    }
    for (const s of missingFromPrimary) {
      if (!(s in aggregateRates)) stillMissing.push(s);
    }
  }

  if (Object.keys(aggregateRates).length === 0) {
    return json({ error: "providers_unavailable" }, 502);
  }

  const payload: RatesResponse = {
    base,
    date: primary?.date ?? date,
    rates: aggregateRates,
    missing: stillMissing,
    source: {
      primary: "frankfurter",
      fallback: usedFallbacks,
    },
  };

  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: {
      ...CORS,
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=21600", // 6h CDN cache
    },
  });
});
