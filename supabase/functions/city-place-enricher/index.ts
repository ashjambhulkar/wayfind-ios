import { createClient } from 'npm:@supabase/supabase-js@2';
import OpenAI from 'npm:openai@4';

type HoursEntry = Record<string, string>;

type SerpApiImage = {
  title?: string;
  thumbnail?: string;
  serpapi_thumbnail?: string;
  last_updated?: string;
};

type PopularTimesDayEntry = {
  time?: string;
  info?: string;
  busyness_score?: number;
};

type PopularTimes = {
  current_day?: string;
  live_hash?: {
    time_spent?: string;
    [key: string]: unknown;
  };
  graph_results?: Record<string, PopularTimesDayEntry[]>;
  [key: string]: unknown;
};

type UserReviewSummary = {
  snippet?: string;
  thumbnail?: string;
};

type UserReviewImage = {
  thumbnail?: string;
};

type UserReview = {
  username?: string;
  rating?: number;
  contributor_id?: string;
  user_review_count?: number;
  user_photo_count?: number;
  user_thumbnail?: string;
  description?: string;
  link?: string;
  images?: UserReviewImage[];
  date?: string;
  date_iso8601?: string;
};

type UserReviews = {
  summary?: UserReviewSummary[];
  most_relevant?: UserReview[];
};

type PlaceResult = {
  title?: string;
  place_id?: string;
  rating?: number;
  reviews?: number;
  price?: string;
  phone?: string;
  website?: string;
  hours?: HoursEntry[];
  address?: string;
  images?: SerpApiImage[];
  thumbnail?: string;
  serpapi_thumbnail?: string;
  type?: string[];
  type_ids?: string[];
  popular_times?: PopularTimes;
  user_reviews?: UserReviews;
};

type SerpApiResponse = {
  place_results?: PlaceResult;
  error?: string;
};

type CityPlaceRow = {
  id: string;
  place_id: string;
  name: string;
  formatted_address: string | null;
  wayfind_category: string | null;
  subtypes: string[] | null;
  rating: number | null;
  user_ratings_total: number | null;
  price_level: number | null;
  opening_hours: { day: string; hours: string }[] | null;
  formatted_phone_number: string | null;
  international_phone_number: string | null;
  website: string | null;
  images: string[] | null;
  thumbnail_url: string | null;
  time_spent_min: number | null;
  time_spent_max: number | null;
  time_spent_enriched_at: string | null;
  popular_times: Record<string, unknown> | null;
  reviews_tags: string[] | null;
  ai_short_summary: string | null;
  ai_editorial_summary: string | null;
  ai_review_summary: string | null;
  ai_why_go: string[] | null;
  ai_know_before_you_go: string[] | null;
  ai_enriched_at: string | null;
  details_enriched_at: string | null;
  status: string | null;
};

type AiOutput = {
  ai_short_summary: string;
  ai_editorial_summary: string;
  ai_review_summary: string;
  ai_why_go: string[];
  ai_know_before_you_go: string[];
};

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SERPAPI_API_KEY = Deno.env.get('SERPAPI_API_KEY')!;
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY')!;
const WORKER_SECRET = Deno.env.get('WORKER_SECRET')!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

function json(data: unknown, init?: ResponseInit) {
  return new Response(JSON.stringify(data), {
    headers: { 'content-type': 'application/json' },
    ...init,
  });
}

function parsePriceLevel(priceText: string | null): number | null {
  if (!priceText) return null;
  const match = priceText.match(/[€$£¥]+/);
  return match ? match[0].length || null : null;
}

function normalizeOpeningHours(hours: HoursEntry[] | null | undefined) {
  if (!hours || !Array.isArray(hours)) return null;
  return hours
    .map((entry) => {
      const [day, value] = Object.entries(entry)[0] ?? [];
      return day && value ? { day, hours: value } : null;
    })
    .filter(Boolean);
}

function extractImageUrls(images: SerpApiImage[] | null | undefined): string[] {
  if (!images || !Array.isArray(images)) return [];
  return images
    .map((img) => img.thumbnail?.trim() || img.serpapi_thumbnail?.trim())
    .filter((url): url is string => Boolean(url));
}

function extractThumbnailUrl(place: PlaceResult): string | null {
  return (
    place.thumbnail?.trim() ||
    place.serpapi_thumbnail?.trim() ||
    extractImageUrls(place.images)[0] ||
    null
  );
}

function extractPhones(place: PlaceResult): {
  formatted: string | null;
  international: string | null;
} {
  const raw = place as Record<string, unknown>;
  const formatted =
    (typeof place.phone === 'string' && place.phone.trim()) ||
    (typeof raw['formatted_phone_number'] === 'string' &&
      raw['formatted_phone_number'].trim()) ||
    null;

  const international =
    (typeof raw['international_phone_number'] === 'string' &&
      raw['international_phone_number'].trim()) ||
    (typeof raw['international_phone'] === 'string' &&
      raw['international_phone'].trim()) ||
    formatted;

  return { formatted: formatted || null, international: international || null };
}

function extractSubtypes(place: PlaceResult): string[] | null {
  const values = new Set<string>();
  for (const item of place.type ?? []) {
    const v = item?.trim();
    if (v) values.add(v);
  }
  for (const item of place.type_ids ?? []) {
    const v = item?.trim();
    if (v) values.add(v);
  }
  return values.size > 0 ? Array.from(values) : null;
}

function normalizePopularTimes(
  popularTimes: PopularTimes | null | undefined
): Record<string, unknown> | null {
  if (!popularTimes || typeof popularTimes !== 'object') return null;
  return popularTimes as Record<string, unknown>;
}

function extractReviewTags(place: PlaceResult): string[] | null {
  const tags = new Set<string>();

  for (const type of place.type ?? []) {
    const clean = type?.trim().toLowerCase();
    if (clean) tags.add(clean);
  }

  const summaries = place.user_reviews?.summary ?? [];
  for (const item of summaries) {
    const text = item.snippet?.trim();
    if (!text) continue;
    const lc = text.toLowerCase();

    const keywordMap: [RegExp, string][] = [
      [/\bcoffee\b/, 'coffee'],
      [/\btea\b/, 'tea'],
      [/\bbrunch\b/, 'brunch'],
      [/\bbreakfast\b/, 'breakfast'],
      [/\blunch\b/, 'lunch'],
      [/\bdinner\b/, 'dinner'],
      [/\bdessert\b|\bcake\b|\bpastr(?:y|ies)\b/, 'desserts'],
      [/\bservice\b|\bstaff\b/, 'service'],
      [/\batmosphere\b|\bvibe\b|\bcozy\b|\bcasual\b|\btrendy\b/, 'atmosphere'],
      [/\bqueue\b|\bwait\b/, 'wait time'],
      [/\bportion\b|\bgenerous\b/, 'portion size'],
      [/\bdelicious\b|\btasty\b|\bincredible\b|\bgreat food\b/, 'food quality'],
    ];

    for (const [pattern, tag] of keywordMap) {
      if (pattern.test(lc)) tags.add(tag);
    }
  }

  return tags.size > 0 ? Array.from(tags).slice(0, 20) : null;
}

const _SPEND_LINE_HINT =
  /spend|typically|people\s+\w+\s+spend|visit\s+(?:duration|length)|\d+\s*(?:hr|hour|hours|min)/i;

function walkPopularTimesForSpendStrings(
  obj: unknown,
  basePath: string,
  out: { text: string; path: string }[],
  depth: number
): void {
  if (depth > 14 || out.length >= 24) return;
  if (typeof obj === 'string') {
    const s = obj.trim().replace(/\s+/g, ' ');
    if (s.length >= 8 && s.length <= 500 && _SPEND_LINE_HINT.test(s)) {
      out.push({ text: s, path: basePath });
    }
    return;
  }
  if (Array.isArray(obj)) {
    obj.forEach((item, i) =>
      walkPopularTimesForSpendStrings(item, `${basePath}[${i}]`, out, depth + 1)
    );
    return;
  }
  if (obj && typeof obj === 'object') {
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      walkPopularTimesForSpendStrings(v, `${basePath}.${k}`, out, depth + 1);
    }
  }
}

function extractSpendText(place: PlaceResult | undefined): string | null {
  if (!place) return null;

  const direct = place.popular_times?.live_hash?.time_spent;
  if (typeof direct === 'string' && direct.trim()) return direct.trim();

  const raw = place as Record<string, unknown>;
  for (const key of [
    'people_typically_spend',
    'people_usually_spend',
    'typical_time_spent',
    'visit_duration',
  ]) {
    const v = raw[key];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }

  const alternates: { text: string; path: string }[] = [];
  if (place.popular_times && typeof place.popular_times === 'object') {
    walkPopularTimesForSpendStrings(place.popular_times, 'popular_times', alternates, 0);
    return alternates[0]?.text ?? null;
  }

  return null;
}

function parseTypicalSpend(
  text: string | null
): { time_spent_min: number | null; time_spent_max: number | null } {
  if (!text) return { time_spent_min: null, time_spent_max: null };

  const body = text
    .replace(/^People\s+(typically\s+)?spend\s*/i, '')
    .replace(/^Visitors\s+(typically\s+)?spend\s*/i, '')
    .replace(/\s*here\.?$/i, '')
    .trim();

  const toMinutes = (value: string): number | null => {
    const v = value.trim();
    const hrMatch = v.match(/(\d+(?:\.\d+)?)\s*(hr|hour|hours)\b/i);
    const minMatch = v.match(/(\d+(?:\.\d+)?)\s*(min|minute|minutes)\b/i);

    if (hrMatch) return Math.round(parseFloat(hrMatch[1]) * 60);
    if (minMatch) return Math.round(parseFloat(minMatch[1]));

    const bare = v.match(/^(\d+(?:\.\d+)?)\s*$/);
    if (bare) {
      const n = parseFloat(bare[1]);
      if (n > 0 && n <= 12) return Math.round(n * 60);
      if (n > 12) return Math.round(n);
    }
    return null;
  };

  const upperOnly = body.match(/^\s*(?:up\s+to|at\s+most)\s+(.+)$/i);
  if (upperOnly) {
    const maxM = toMinutes(upperOnly[1].trim());
    if (maxM != null && maxM > 0) {
      const minM = Math.max(1, Math.round(maxM / 2));
      return { time_spent_min: minM, time_spent_max: maxM };
    }
  }

  let parts: string[];
  if (/\s+to\s+/i.test(body)) {
    parts = body.split(/\s+to\s+/i).map((s) => s.trim());
  } else if (/[–-]/.test(body) && /hr|hour|min/i.test(body)) {
    parts = body.split(/\s*[–-]\s*/).map((s) => s.trim()).filter(Boolean);
  } else {
    parts = [body];
  }

  if (parts.length === 2) {
    return {
      time_spent_min: toMinutes(parts[0]),
      time_spent_max: toMinutes(parts[1]),
    };
  }

  const single = toMinutes(body);
  return { time_spent_min: single, time_spent_max: single };
}

async function fetchSerpPlace(placeId: string): Promise<SerpApiResponse> {
  const url = new URL('https://serpapi.com/search.json');
  url.searchParams.set('engine', 'google_maps');
  url.searchParams.set('type', 'place');
  url.searchParams.set('place_id', placeId);
  url.searchParams.set('api_key', SERPAPI_API_KEY);

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers: { Accept: 'application/json' },
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`SerpApi request failed: ${response.status} ${text}`);
  }

  return (await response.json()) as SerpApiResponse;
}

function compactPopularTimes(popularTimes: Record<string, unknown> | null): Record<string, unknown> | null {
  if (!popularTimes) return null;

  const liveHash =
    typeof popularTimes.live_hash === 'object' && popularTimes.live_hash
      ? popularTimes.live_hash
      : null;

  const graphResults =
    typeof popularTimes.graph_results === 'object' && popularTimes.graph_results
      ? popularTimes.graph_results
      : null;

  return {
    current_day: popularTimes.current_day ?? null,
    live_hash: liveHash,
    graph_results: graphResults,
  };
}

function buildPlaceContext(row: CityPlaceRow) {
  return {
    name: row.name,
    formatted_address: row.formatted_address,
    wayfind_category: row.wayfind_category,
    subtypes: row.subtypes ?? [],
    rating: row.rating,
    user_ratings_total: row.user_ratings_total,
    price_level: row.price_level,
    opening_hours: row.opening_hours,
    formatted_phone_number: row.formatted_phone_number,
    website: row.website,
    time_spent_min: row.time_spent_min,
    time_spent_max: row.time_spent_max,
    popular_times: compactPopularTimes(row.popular_times),
    reviews_tags: row.reviews_tags ?? [],
  };
}

function sanitizeAiOutput(raw: unknown): AiOutput {
  const obj = (raw ?? {}) as Record<string, unknown>;

  const shortSummaryRaw =
    typeof obj.ai_short_summary === 'string' ? obj.ai_short_summary.trim() : '';
  const shortSummary = shortSummaryRaw.slice(0, 280);

  const editorial =
    typeof obj.ai_editorial_summary === 'string'
      ? obj.ai_editorial_summary.trim()
      : '';

  const reviewSummary =
    typeof obj.ai_review_summary === 'string'
      ? obj.ai_review_summary.trim()
      : '';

  const whyGo = Array.isArray(obj.ai_why_go)
    ? obj.ai_why_go
        .filter((x): x is string => typeof x === 'string')
        .map((s) => s.trim())
        .filter(Boolean)
        .slice(0, 6)
    : [];

  const knowBefore = Array.isArray(obj.ai_know_before_you_go)
    ? obj.ai_know_before_you_go
        .filter((x): x is string => typeof x === 'string')
        .map((s) => s.trim())
        .filter(Boolean)
        .slice(0, 6)
    : [];

  if (!shortSummary || !editorial || !reviewSummary) {
    throw new Error('Model returned incomplete AI fields');
  }

  return {
    ai_short_summary: shortSummary,
    ai_editorial_summary: editorial,
    ai_review_summary: reviewSummary,
    ai_why_go: whyGo,
    ai_know_before_you_go: knowBefore,
  };
}

async function generateAiFields(row: CityPlaceRow): Promise<AiOutput> {
  const place = buildPlaceContext(row);

  const response = await openai.chat.completions.create({
    model: 'gpt-4o-mini',
    response_format: {
      type: 'json_schema',
      json_schema: {
        name: 'city_place_ai_enrichment',
        strict: true,
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            ai_short_summary: {
              type: 'string',
              minLength: 12,
              maxLength: 240,
            },
            ai_editorial_summary: {
              type: 'string',
            },
            ai_review_summary: {
              type: 'string',
            },
            ai_why_go: {
              type: 'array',
              items: { type: 'string' },
              minItems: 3,
              maxItems: 6,
            },
            ai_know_before_you_go: {
              type: 'array',
              items: { type: 'string' },
              minItems: 3,
              maxItems: 6,
            },
          },
          required: [
            'ai_short_summary',
            'ai_editorial_summary',
            'ai_review_summary',
            'ai_why_go',
            'ai_know_before_you_go',
          ],
        },
      },
    },
    messages: [
      {
        role: 'developer',
        content: [
          {
            type: 'text',
            text:
              'You generate travel-place copy for a production app. Use only the supplied place data. Do not invent facts, ticketing rules, reservation rules, accessibility claims, dress codes, or opening-hour exceptions unless directly supported by the input. Keep language natural, clear, and useful. Prefer concrete, grounded guidance over generic marketing language.',
          },
        ],
      },
      {
        role: 'user',
        content: [
          {
            type: 'text',
            text: `Generate AI enrichment for this place.\n\nPLACE JSON:\n${JSON.stringify(
              place,
              null,
              2
            )}`,
          },
        ],
      },
    ],
  });

  const content = response.choices[0]?.message?.content;
  if (!content) throw new Error('No model content returned');

  return sanitizeAiOutput(JSON.parse(content));
}

async function fetchPlaceRow(cityPlaceId: string): Promise<CityPlaceRow> {
  const { data, error } = await supabase
    .from('city_places')
    .select(`
      id,
      place_id,
      name,
      formatted_address,
      wayfind_category,
      subtypes,
      rating,
      user_ratings_total,
      price_level,
      opening_hours,
      formatted_phone_number,
      international_phone_number,
      website,
      images,
      thumbnail_url,
      time_spent_min,
      time_spent_max,
      time_spent_enriched_at,
      popular_times,
      reviews_tags,
      ai_short_summary,
      ai_editorial_summary,
      ai_review_summary,
      ai_why_go,
      ai_know_before_you_go,
      ai_enriched_at,
      details_enriched_at,
      status
    `)
    .eq('id', cityPlaceId)
    .single();

  if (error) throw new Error(`fetchPlaceRow failed: ${error.message}`);
  return data as CityPlaceRow;
}

async function markJob(
  jobId: number,
  status: 'done' | 'failed',
  lastError?: string | null,
  delaySeconds = 0
) {
  const patch: Record<string, unknown> = {
    status,
    last_error: lastError ?? null,
    finished_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };

  if (status === 'failed' && delaySeconds > 0) {
    patch.status = 'failed';
    patch.run_after = new Date(Date.now() + delaySeconds * 1000).toISOString();
  }

  const { error } = await supabase
    .from('city_place_enrichment_jobs')
    .update(patch)
    .eq('id', jobId);

  if (error) throw new Error(`markJob failed: ${error.message}`);
}

/**
 * Mode controls which slice of the SerpAPI payload we apply:
 *
 *   - 'details': rating, hours, phones, website, AI-feeders. Skips image
 *               writes entirely. Cheap fields, refreshed often.
 *   - 'images':  thumbnail_url + images[] + images_refreshed_at +
 *               image_source. Skips text fields.
 *   - 'all':    legacy combined behavior.
 *
 * Critical safety: when image_source = 'user', we NEVER overwrite the
 * thumbnail or images columns. User-uploaded photos (Phase F) own those
 * slots until the Phase F lifecycle removes them.
 */
type EnrichMode = 'details' | 'images' | 'all';

async function runSenseStage(row: CityPlaceRow, mode: EnrichMode = 'all') {
  // For 'details' mode the gating heuristic is unchanged; for 'images' mode
  // we always re-fetch (the caller has already decided the image is stale).
  if (
    mode === 'details' &&
    row.details_enriched_at &&
    row.rating !== null &&
    row.reviews_tags &&
    row.reviews_tags.length > 0
  ) {
    return;
  }

  const data = await fetchSerpPlace(row.place_id);
  if (data.error) throw new Error(`SerpApi error: ${data.error}`);

  const place = data.place_results;
  if (!place) {
    await supabase
      .from('city_places')
      .update({
        details_enriched_at: new Date().toISOString(),
        time_spent_enriched_at: new Date().toISOString(),
      })
      .eq('id', row.id);
    return;
  }

  const nowIso = new Date().toISOString();
  const payload: Record<string, unknown> = {};

  if (mode === 'details' || mode === 'all') {
    const spendText = extractSpendText(place);
    const { time_spent_min, time_spent_max } = parseTypicalSpend(spendText);
    const phones = extractPhones(place);
    const subtypes = extractSubtypes(place);
    const reviewTags = extractReviewTags(place);
    const popularTimesPayload = normalizePopularTimes(place.popular_times);

    payload.rating = place.rating ?? null;
    payload.user_ratings_total =
      typeof place.reviews === 'number' ? Math.round(place.reviews) : null;
    payload.price_level = parsePriceLevel(place.price ?? null);
    payload.opening_hours = normalizeOpeningHours(place.hours ?? null);
    payload.formatted_phone_number = phones.formatted;
    payload.international_phone_number = phones.international;
    payload.website = place.website?.trim() || null;
    payload.popular_times = popularTimesPayload;
    payload.subtypes = subtypes;
    payload.reviews_tags = reviewTags;
    payload.time_spent_min = time_spent_min;
    payload.time_spent_max = time_spent_max;
    payload.details_enriched_at = nowIso;
    payload.time_spent_enriched_at = nowIso;
  }

  if (mode === 'images' || mode === 'all') {
    // Hard stop: never overwrite user-uploaded photos.
    const imageSource = (row as unknown as { image_source?: string | null }).image_source;
    if (imageSource === 'user') {
      console.log(
        `[worker] image_source=user for city_place_id=${row.id} — skipping image refresh`,
      );
    } else {
      const imageUrls = extractImageUrls(place.images);
      const thumbnailUrl = extractThumbnailUrl(place);
      payload.images = imageUrls.length > 0 ? imageUrls : null;
      payload.thumbnail_url = thumbnailUrl;
      payload.image_source = thumbnailUrl ? 'serpapi' : 'unknown';
      payload.images_refreshed_at = nowIso;
    }
  }

  if (Object.keys(payload).length === 0) return;

  const { error } = await supabase.from('city_places').update(payload).eq('id', row.id);
  if (error) throw new Error(`sense update failed: ${error.message}`);
}

function needsAi(row: CityPlaceRow) {
  return (
    row.ai_short_summary == null ||
    row.ai_editorial_summary == null ||
    row.ai_review_summary == null ||
    row.ai_why_go == null ||
    row.ai_know_before_you_go == null
  );
}

async function runAiStage(row: CityPlaceRow) {
  if (!needsAi(row)) return;

  const ai = await generateAiFields(row);
  const nowIso = new Date().toISOString();

  const { error } = await supabase
    .from('city_places')
    .update({
      ai_short_summary: ai.ai_short_summary,
      ai_editorial_summary: ai.ai_editorial_summary,
      ai_review_summary: ai.ai_review_summary,
      ai_why_go: ai.ai_why_go,
      ai_know_before_you_go: ai.ai_know_before_you_go,
      ai_enriched_at: nowIso,
    })
    .eq('id', row.id);

  if (error) throw new Error(`ai update failed: ${error.message}`);
}

async function processBatch(batchSize = 5) {
  const { data, error } = await supabase.rpc('claim_city_place_enrichment_jobs', {
    batch_size: batchSize,
  });

  if (error) throw new Error(`claim jobs failed: ${error.message}`);

  const jobs = (data ?? []) as {
    id: number;
    city_place_id: string;
    mode?: EnrichMode | null;
    priority?: string | null;
  }[];
  if (jobs.length === 0) return { claimed: 0 };

  for (const job of jobs) {
    const mode: EnrichMode = (job.mode ?? 'all') as EnrichMode;
    try {
      let row = await fetchPlaceRow(job.city_place_id);

      await runSenseStage(row, mode);

      row = await fetchPlaceRow(job.city_place_id);

      // AI stage only makes sense after we have details; skip entirely
      // for image-only refreshes.
      if (mode !== 'images' && row.details_enriched_at) {
        await runAiStage(row);
      }

      await markJob(job.id, 'done', null);
      console.log(`[worker] done city_place_id=${job.city_place_id} mode=${mode}`);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      await markJob(job.id, 'failed', message, 300);
      console.error(
        `[worker] failed city_place_id=${job.city_place_id} mode=${mode}: ${message}`,
      );
    }
  }

  return { claimed: jobs.length };
}

Deno.serve(async (req) => {
  const secret = req.headers.get('x-worker-secret');
  if (!WORKER_SECRET || secret !== WORKER_SECRET) {
    return json({ error: 'unauthorized' }, { status: 401 });
  }

  const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
  const batchSize = Math.max(1, Math.min(20, Number(body.batch_size ?? 5)));

  EdgeRuntime.waitUntil(processBatch(batchSize));

  return json({ ok: true, accepted: true, batch_size: batchSize }, { status: 202 });
});