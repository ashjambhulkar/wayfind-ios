// supabase/functions/upload-travel-leg/index.ts
//
// Phase J.2 — Receives Apple-sourced travel-leg uploads from
// `AppleTravelTimesService` (iOS, Phase J.3) and upserts them into
// `city_travel_times`.
//
// Why a function and not direct Postgres writes?
//   1. We need authenticated (JWT) writes that *don't* trust the
//      caller to set `provider='apple'` for a row that was actually
//      computed elsewhere — the Edge Function is the only writer with
//      service-role access to the table.
//   2. Per-user 600/hr Upstash sliding-window rate limit so a misbehaving
//      build can't hammer the table from a single account.
//   3. Skip-write logic: if there's already an Apple row newer than 30
//      days for a leg, drop the upload silently. Saves the iOS app from
//      having to know what the cache TTL is, and saves us from paying
//      for nothing on the Postgres side.
//
// Auth: JWT validated inside the function (same pattern as
// lookup-place-id). config.toml sets verify_jwt = false.
//
// Body:
//   {
//     "city_profile_id": "uuid",
//     "legs": [
//       {
//         "from_place_id": "ChIJ…",
//         "to_place_id":   "ChIJ…",
//         "distance_meters": 1234,           // optional
//         "modes": {
//           "walking":  { "minutes": 17, "polyline": "abcd…" },
//           "driving":  { "minutes": 6,  "polyline": "wxyz…" },
//           "transit":  { "minutes": 22, "polyline": null    }
//         }
//       },
//       …  (≤ 50 per request)
//     ]
//   }

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { Ratelimit } from 'https://esm.sh/@upstash/ratelimit@1.0.1';
import { Redis } from 'https://esm.sh/@upstash/redis@1.28.4';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const UPSTASH_URL = Deno.env.get('UPSTASH_REDIS_REST_URL') ?? '';
const UPSTASH_TOKEN = Deno.env.get('UPSTASH_REDIS_REST_TOKEN') ?? '';

const MAX_LEGS_PER_REQUEST = 50;
const APPLE_FRESHNESS_DAYS = 30;

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
};

// ---------------------------------------------------------------------------
// Rate limiter (Upstash)
// ---------------------------------------------------------------------------

let cachedLimiter: Ratelimit | null = null;
function getLimiter(): Ratelimit | null {
  if (!UPSTASH_URL || !UPSTASH_TOKEN) return null;
  if (cachedLimiter) return cachedLimiter;
  cachedLimiter = new Ratelimit({
    redis: new Redis({ url: UPSTASH_URL, token: UPSTASH_TOKEN }),
    limiter: Ratelimit.slidingWindow(600, '1 h'),
    prefix: 'rl:upload-travel-leg:user',
    analytics: false,
  });
  return cachedLimiter;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Mode = 'walking' | 'driving' | 'transit';

interface LegModePayload {
  minutes?: number | null;
  polyline?: string | null;
}

interface LegPayload {
  from_place_id?: string;
  to_place_id?: string;
  distance_meters?: number | null;
  modes?: Partial<Record<Mode, LegModePayload>>;
}

interface RequestPayload {
  city_profile_id?: string;
  legs?: LegPayload[];
}

interface ExistingRow {
  city_profile_id: string;
  from_place_id: string;
  to_place_id: string;
  walking_minutes: number | null;
  driving_minutes: number | null;
  transit_minutes: number | null;
  walking_polyline: string | null;
  driving_polyline: string | null;
  transit_polyline: string | null;
  walking_provider: string | null;
  driving_provider: string | null;
  transit_provider: string | null;
  apple_refreshed_at: string | null;
  distance_meters: number | null;
  provider: string;
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) {
    return jsonResponse({ error: 'missing_jwt' }, 401);
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return jsonResponse({ error: 'invalid_jwt' }, 401);
  }
  const userId = userData.user.id;

  // Per-user 600/hr cap. Soft-fail on missing Upstash so local dev still works.
  const limiter = getLimiter();
  if (limiter) {
    const rl = await limiter.limit(userId);
    if (!rl.success) {
      return jsonResponse(
        {
          error: 'rate_limited',
          retry_after_ms: rl.reset - Date.now(),
        },
        429
      );
    }
  }

  let payload: RequestPayload;
  try {
    payload = (await req.json()) as RequestPayload;
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const cityProfileId = payload.city_profile_id;
  const legs = payload.legs ?? [];
  if (!cityProfileId) {
    return jsonResponse({ error: 'missing_city_profile_id' }, 400);
  }
  if (!Array.isArray(legs) || legs.length === 0) {
    return jsonResponse({ error: 'missing_legs' }, 400);
  }
  if (legs.length > MAX_LEGS_PER_REQUEST) {
    return jsonResponse(
      { error: 'too_many_legs', max: MAX_LEGS_PER_REQUEST },
      413
    );
  }

  const validLegs = legs.filter(isValidLeg);
  if (validLegs.length === 0) {
    return jsonResponse({ error: 'no_valid_legs' }, 422);
  }

  const sr = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const existing = await loadExisting(sr, cityProfileId, validLegs);
  const freshCutoff = Date.now() - APPLE_FRESHNESS_DAYS * 24 * 60 * 60 * 1000;

  let written = 0;
  let skipped = 0;
  for (const leg of validLegs) {
    const key = `${leg.from_place_id}|${leg.to_place_id}`;
    const prior = existing.get(key);
    if (
      prior?.apple_refreshed_at &&
      Date.parse(prior.apple_refreshed_at) > freshCutoff
    ) {
      // We already have a fresh apple-sourced row. Skip the write so we
      // don't churn the row's `apple_refreshed_at` timestamp on every
      // background batch the iOS app schedules.
      skipped += 1;
      continue;
    }

    const merged = mergeLeg(prior, leg, cityProfileId);
    const { error } = await sr
      .from('city_travel_times')
      .upsert(merged, { onConflict: 'city_profile_id,from_place_id,to_place_id' });
    if (error) {
      console.error('upsert failed', { key, error });
      continue;
    }
    written += 1;
  }

  return jsonResponse({
    ok: true,
    received: legs.length,
    written,
    skipped,
    invalid: legs.length - validLegs.length,
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function isValidLeg(leg: LegPayload): leg is Required<Pick<LegPayload, 'from_place_id' | 'to_place_id'>> & LegPayload {
  if (!leg.from_place_id || !leg.to_place_id) return false;
  if (leg.from_place_id === leg.to_place_id) return false;
  if (!leg.modes) return false;
  // At least one mode must carry either minutes or a polyline.
  for (const mode of ['walking', 'driving', 'transit'] as Mode[]) {
    const m = leg.modes[mode];
    if (m && (typeof m.minutes === 'number' || typeof m.polyline === 'string')) {
      return true;
    }
  }
  return false;
}

async function loadExisting(
  sr: ReturnType<typeof createClient>,
  cityProfileId: string,
  legs: LegPayload[]
): Promise<Map<string, ExistingRow>> {
  const fromIds = Array.from(new Set(legs.map((l) => l.from_place_id!)));
  const toIds = Array.from(new Set(legs.map((l) => l.to_place_id!)));
  const { data, error } = await sr
    .from('city_travel_times')
    .select(
      'city_profile_id,from_place_id,to_place_id,' +
        'walking_minutes,driving_minutes,transit_minutes,' +
        'walking_polyline,driving_polyline,transit_polyline,' +
        'walking_provider,driving_provider,transit_provider,' +
        'apple_refreshed_at,distance_meters,provider'
    )
    .eq('city_profile_id', cityProfileId)
    .in('from_place_id', fromIds)
    .in('to_place_id', toIds);
  if (error || !data) {
    console.error('loadExisting failed', error);
    return new Map();
  }
  const map = new Map<string, ExistingRow>();
  for (const row of data as ExistingRow[]) {
    map.set(`${row.from_place_id}|${row.to_place_id}`, row);
  }
  return map;
}

function mergeLeg(
  prior: ExistingRow | undefined,
  leg: LegPayload,
  cityProfileId: string
): Record<string, unknown> {
  const now = new Date().toISOString();
  const out: Record<string, unknown> = {
    city_profile_id: prior?.city_profile_id ?? cityProfileId,
    from_place_id: leg.from_place_id,
    to_place_id: leg.to_place_id,
    apple_refreshed_at: now,
    computed_at: now,
    // Top-level provider stays as 'mapbox'/'google' if it already was;
    // the per-mode providers tell the real story. If we're inserting a
    // brand-new row, the legacy column has to satisfy a NOT NULL +
    // CHECK constraint, so default it to the most permissive value.
    provider: prior?.provider ?? 'haversine',
    distance_meters:
      leg.distance_meters !== undefined && leg.distance_meters !== null
        ? Math.round(Number(leg.distance_meters))
        : prior?.distance_meters ?? null,
  };

  for (const mode of ['walking', 'driving', 'transit'] as Mode[]) {
    const incoming = leg.modes?.[mode];
    if (!incoming) continue;
    if (typeof incoming.minutes === 'number' && incoming.minutes >= 0) {
      out[`${mode}_minutes`] = Math.round(incoming.minutes);
    }
    if (typeof incoming.polyline === 'string' && incoming.polyline.length > 0) {
      out[`${mode}_polyline`] = incoming.polyline;
    }
    // Whenever we touch a per-mode field we mark its provider as apple.
    if (
      typeof incoming.minutes === 'number' ||
      typeof incoming.polyline === 'string'
    ) {
      out[`${mode}_provider`] = 'apple';
    }
  }

  return out;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}
