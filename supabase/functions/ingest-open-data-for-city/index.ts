// supabase/functions/ingest-open-data-for-city/index.ts
//
// Phase I.2 — Open-data ingestion for `city_places`.
//
// Pulls "free" travel data — Overpass (OpenStreetMap), Wikidata,
// Wikivoyage, Wikimedia Commons — and *only fills gaps*. We never
// overwrite a populated field; the goal is to displace future Google
// dependency without regressing existing data quality.
//
// Source policy (sequential, cheapest first):
//   1. Overpass — list of `tourism=*` POIs in the city's bounding box.
//      Used to discover *which* places exist; we do NOT push new rows
//      into `city_places` from Overpass alone (we'd risk inserting
//      duplicates of Google-sourced rows under a different name). We
//      only enrich rows that already match by name + 80m radius.
//   2. Wikidata — pulls `wdt:P18` (image) + `schema:description` for
//      each Overpass POI carrying `wikidata=Qxxx`.
//   3. Wikivoyage — pulls the *prose* `<extract>` for any place
//      with a Wikivoyage redirect; used as a candidate for
//      `ai_editorial_summary` *only* when our existing field is null.
//   4. Wikimedia Commons — when Wikidata returns an image filename, we
//      resolve to the original CC-licensed URL and capture the photo
//      author + license string for attribution.
//
// `image_source='wikimedia'` is set when (and only when) we update the
// thumbnail. `ai_source_attribution` is always merged (never replaced)
// so prior provenance is preserved.
//
// Auth: service-role only. Triggered by pg_cron (per-city sweep) or by
// `request_city_place_enrichment` when the requester opts into the
// open-data tier.

import { createClient } from 'npm:@supabase/supabase-js@2';

interface IngestArgs {
  city_profile_id: string;
  /** Optional cap so we don't burn an hour on huge cities. */
  max_places?: number;
  /** When true, only re-runs for rows whose ai_source_attribution is null. */
  fill_only?: boolean;
}

interface CityProfileRow {
  id: string;
  name: string;
  country_code: string | null;
  bbox_north: number | null;
  bbox_south: number | null;
  bbox_east: number | null;
  bbox_west: number | null;
}

interface CityPlaceRow {
  id: string;
  name: string;
  lat: number;
  lng: number;
  ai_editorial_summary: string | null;
  ai_short_summary: string | null;
  thumbnail_url: string | null;
  image_source: string | null;
  ai_source_attribution: Record<string, unknown> | null;
}

interface OverpassPoi {
  lat: number;
  lng: number;
  name: string;
  wikidata?: string;
  wikipedia?: string;
}

interface WikidataEnrichment {
  description?: string;
  imageFilename?: string;
}

interface WikimediaImage {
  url: string;
  artist: string | null;
  license: string | null;
}

interface WikivoyageExtract {
  title: string;
  extract: string;
  pageUrl: string;
}

const OVERPASS_URL = 'https://overpass-api.de/api/interpreter';
const WIKIDATA_URL = 'https://www.wikidata.org/w/api.php';
const COMMONS_URL = 'https://commons.wikimedia.org/w/api.php';
const WIKIVOYAGE_URL = (lang: string) =>
  `https://${lang}.wikivoyage.org/w/api.php`;

const USER_AGENT =
  'Wayfind/1.0 (+https://wayfind.app open-data ingestor; ops@wayfind.app)';

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const workerSecret = Deno.env.get('CITY_PLACE_ENRICHER_WORKER_SECRET');
  if (workerSecret && req.headers.get('x-worker-secret') !== workerSecret) {
    return new Response('Forbidden', { status: 403 });
  }

  let args: IngestArgs;
  try {
    args = (await req.json()) as IngestArgs;
  } catch {
    return new Response('Bad JSON', { status: 400 });
  }
  if (!args.city_profile_id) {
    return new Response('Missing city_profile_id', { status: 400 });
  }
  const maxPlaces = Math.min(args.max_places ?? 200, 500);

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  );

  const city = await loadCity(supabase, args.city_profile_id);
  if (!city) {
    return new Response('city_profile not found', { status: 404 });
  }
  if (!hasBbox(city)) {
    return new Response('city_profile missing bbox', { status: 422 });
  }

  // 1. Discover OSM POIs in the bbox.
  const pois = await fetchOverpass(city, maxPlaces);
  if (pois.length === 0) {
    return jsonResponse({ ok: true, processed: 0, reason: 'no_overpass_hits' });
  }

  // 2. Fetch the candidate `city_places` rows that might match.
  const places = await loadCandidatePlaces(
    supabase,
    args.city_profile_id,
    args.fill_only ?? true
  );
  if (places.length === 0) {
    return jsonResponse({ ok: true, processed: 0, reason: 'no_city_places' });
  }

  // 3. Match (name fuzzy + 80m radius) and enrich each match.
  let processed = 0;
  const lang = preferredWikiLang(city.country_code);
  for (const place of places) {
    const match = bestPoiMatch(place, pois);
    if (!match) continue;

    const update: Partial<CityPlaceRow> & {
      ai_source_attribution: Record<string, unknown>;
    } = {
      ai_source_attribution: place.ai_source_attribution ?? {},
    };

    let touched = false;

    // 3a. Wikidata description → ai_short_summary fallback only.
    if (match.wikidata && !place.ai_short_summary) {
      const wd = await fetchWikidata(match.wikidata);
      if (wd?.description) {
        update.ai_short_summary = wd.description;
        update.ai_source_attribution = mergeAttribution(
          update.ai_source_attribution,
          'short_summary',
          [`wikidata:${match.wikidata}`]
        );
        touched = true;
      }
      if (wd?.imageFilename && place.image_source !== 'user') {
        const commons = await fetchCommonsImage(wd.imageFilename);
        if (commons && shouldSetThumb(place)) {
          update.thumbnail_url = commons.url;
          update.image_source = 'wikimedia';
          update.ai_source_attribution = mergeAttribution(
            update.ai_source_attribution,
            'thumbnail',
            [
              `wikimedia:${wd.imageFilename}`,
              commons.license ? `license:${commons.license}` : '',
              commons.artist ? `author:${commons.artist}` : '',
            ].filter(Boolean)
          );
          touched = true;
        }
      }
    }

    // 3b. Wikivoyage extract → ai_editorial_summary fallback only.
    if (!place.ai_editorial_summary) {
      const wv = await fetchWikivoyage(lang, match.name);
      if (wv) {
        update.ai_editorial_summary = wv.extract;
        update.ai_source_attribution = mergeAttribution(
          update.ai_source_attribution,
          'editorial_summary',
          [`wikivoyage:${lang}:${wv.title}`, 'license:CC-BY-SA-3.0']
        );
        touched = true;
      }
    }

    if (!touched) continue;

    const { error } = await supabase
      .from('city_places')
      .update(update)
      .eq('id', place.id);
    if (error) {
      console.error('city_places update failed', { id: place.id, error });
      continue;
    }
    processed += 1;
  }

  return jsonResponse({ ok: true, processed, considered: places.length });
});

// ---------------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------------

async function loadCity(
  supabase: ReturnType<typeof createClient>,
  id: string
): Promise<CityProfileRow | null> {
  const { data, error } = await supabase
    .from('city_profiles')
    .select(
      'id, name, country_code, bbox_north, bbox_south, bbox_east, bbox_west'
    )
    .eq('id', id)
    .maybeSingle();
  if (error) {
    console.error('loadCity failed', error);
    return null;
  }
  return (data as CityProfileRow) ?? null;
}

async function loadCandidatePlaces(
  supabase: ReturnType<typeof createClient>,
  cityProfileId: string,
  fillOnly: boolean
): Promise<CityPlaceRow[]> {
  let query = supabase
    .from('city_places')
    .select(
      'id, name, lat, lng, ai_editorial_summary, ai_short_summary, ' +
        'thumbnail_url, image_source, ai_source_attribution'
    )
    .eq('city_profile_id', cityProfileId)
    .limit(500);
  if (fillOnly) {
    // Only rows that still have at least one gap *and* haven't been
    // ingested before (no attribution = no prior open-data pass).
    query = query.is('ai_source_attribution', null);
  }
  const { data, error } = await query;
  if (error) {
    console.error('loadCandidatePlaces failed', error);
    return [];
  }
  return (data as CityPlaceRow[]) ?? [];
}

function hasBbox(city: CityProfileRow): boolean {
  return [
    city.bbox_north,
    city.bbox_south,
    city.bbox_east,
    city.bbox_west,
  ].every((v) => typeof v === 'number');
}

// ---------------------------------------------------------------------------
// Overpass
// ---------------------------------------------------------------------------

async function fetchOverpass(
  city: CityProfileRow,
  max: number
): Promise<OverpassPoi[]> {
  // bbox order is south, west, north, east per Overpass.
  const bbox = `${city.bbox_south},${city.bbox_west},${city.bbox_north},${city.bbox_east}`;
  // Tourism + historic + leisure cover the high-value travel POIs without
  // burying us in convenience stores.
  const query = `
    [out:json][timeout:60];
    (
      node["tourism"](${bbox});
      node["historic"](${bbox});
      node["leisure"="park"](${bbox});
    );
    out center ${max};
  `;
  try {
    const res = await fetch(OVERPASS_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': USER_AGENT,
      },
      body: `data=${encodeURIComponent(query)}`,
    });
    if (!res.ok) {
      console.warn('Overpass non-200', res.status);
      return [];
    }
    const json = (await res.json()) as {
      elements?: Array<{
        lat?: number;
        lon?: number;
        tags?: Record<string, string>;
      }>;
    };
    const out: OverpassPoi[] = [];
    for (const el of json.elements ?? []) {
      const name = el.tags?.['name:en'] ?? el.tags?.name;
      if (!name || typeof el.lat !== 'number' || typeof el.lon !== 'number') {
        continue;
      }
      out.push({
        name,
        lat: el.lat,
        lng: el.lon,
        wikidata: el.tags?.wikidata,
        wikipedia: el.tags?.wikipedia,
      });
    }
    return out;
  } catch (err) {
    console.error('Overpass fetch failed', err);
    return [];
  }
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

function bestPoiMatch(
  place: CityPlaceRow,
  pois: OverpassPoi[]
): OverpassPoi | null {
  let best: OverpassPoi | null = null;
  let bestScore = 0;
  for (const poi of pois) {
    const distance = haversineMeters(place.lat, place.lng, poi.lat, poi.lng);
    if (distance > 80) continue;
    const sim = stringSimilarity(
      place.name.toLowerCase(),
      poi.name.toLowerCase()
    );
    if (sim < 0.6) continue;
    const score = sim * 0.7 + (1 - distance / 80) * 0.3;
    if (score > bestScore) {
      bestScore = score;
      best = poi;
    }
  }
  return best;
}

function haversineMeters(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number
): number {
  const R = 6_371_000;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLng = ((lng2 - lng1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** Dice coefficient over bigrams; 0..1, fast and forgiving for venue names. */
function stringSimilarity(a: string, b: string): number {
  if (a === b) return 1;
  if (a.length < 2 || b.length < 2) return 0;
  const bigrams = (s: string): Map<string, number> => {
    const m = new Map<string, number>();
    for (let i = 0; i < s.length - 1; i++) {
      const bi = s.substring(i, i + 2);
      m.set(bi, (m.get(bi) ?? 0) + 1);
    }
    return m;
  };
  const aMap = bigrams(a);
  const bMap = bigrams(b);
  let intersection = 0;
  for (const [bi, count] of aMap) {
    const other = bMap.get(bi) ?? 0;
    intersection += Math.min(count, other);
  }
  return (2 * intersection) / (a.length - 1 + (b.length - 1));
}

// ---------------------------------------------------------------------------
// Wikidata + Commons + Wikivoyage
// ---------------------------------------------------------------------------

async function fetchWikidata(
  qid: string
): Promise<WikidataEnrichment | null> {
  try {
    const url = new URL(WIKIDATA_URL);
    url.searchParams.set('action', 'wbgetentities');
    url.searchParams.set('ids', qid);
    url.searchParams.set('props', 'descriptions|claims');
    url.searchParams.set('languages', 'en');
    url.searchParams.set('format', 'json');
    url.searchParams.set('formatversion', '2');
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
    if (!res.ok) return null;
    const json = await res.json();
    const ent = json?.entities?.[qid];
    if (!ent) return null;
    const description = ent.descriptions?.en?.value as string | undefined;
    const imageClaim = ent.claims?.P18?.[0]?.mainsnak?.datavalue?.value as
      | string
      | undefined;
    return {
      description,
      imageFilename: imageClaim,
    };
  } catch (err) {
    console.error('Wikidata fetch failed', err);
    return null;
  }
}

async function fetchCommonsImage(
  filename: string
): Promise<WikimediaImage | null> {
  try {
    const url = new URL(COMMONS_URL);
    url.searchParams.set('action', 'query');
    url.searchParams.set('prop', 'imageinfo');
    url.searchParams.set('iiprop', 'url|extmetadata');
    url.searchParams.set('titles', `File:${filename}`);
    url.searchParams.set('format', 'json');
    url.searchParams.set('formatversion', '2');
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
    if (!res.ok) return null;
    const json = await res.json();
    const page = json?.query?.pages?.[0];
    const info = page?.imageinfo?.[0];
    if (!info?.url) return null;
    const meta = info.extmetadata ?? {};
    return {
      url: info.url as string,
      artist: stripHtml(meta?.Artist?.value as string | undefined),
      license: (meta?.LicenseShortName?.value as string | undefined) ?? null,
    };
  } catch (err) {
    console.error('Commons fetch failed', err);
    return null;
  }
}

async function fetchWikivoyage(
  lang: string,
  title: string
): Promise<WikivoyageExtract | null> {
  try {
    const url = new URL(WIKIVOYAGE_URL(lang));
    url.searchParams.set('action', 'query');
    url.searchParams.set('prop', 'extracts');
    url.searchParams.set('exintro', '1');
    url.searchParams.set('explaintext', '1');
    url.searchParams.set('redirects', '1');
    url.searchParams.set('titles', title);
    url.searchParams.set('format', 'json');
    url.searchParams.set('formatversion', '2');
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
    if (!res.ok) return null;
    const json = await res.json();
    const page = json?.query?.pages?.[0];
    const extract = page?.extract as string | undefined;
    if (!extract || extract.length < 60) return null;
    return {
      title: page?.title as string,
      extract: extract.trim().slice(0, 1200),
      pageUrl: `https://${lang}.wikivoyage.org/wiki/${encodeURIComponent(
        page?.title as string
      )}`,
    };
  } catch (err) {
    console.error('Wikivoyage fetch failed', err);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function preferredWikiLang(country: string | null): string {
  // Cheap heuristic: most users want EN articles; only switch when we
  // know the local Wikivoyage is much richer (FR/DE/IT/ES/JA).
  switch ((country ?? '').toUpperCase()) {
    case 'FR':
      return 'fr';
    case 'DE':
    case 'AT':
    case 'CH':
      return 'de';
    case 'IT':
      return 'it';
    case 'ES':
    case 'MX':
      return 'es';
    case 'JP':
      return 'ja';
    default:
      return 'en';
  }
}

function shouldSetThumb(place: CityPlaceRow): boolean {
  // Never overwrite a user-sourced photo (Phase H rule). Also leave
  // existing Google thumbnails alone — open-data is fallback-only.
  if (place.image_source === 'user') return false;
  return !place.thumbnail_url;
}

function mergeAttribution(
  existing: Record<string, unknown>,
  field: string,
  sources: string[]
): Record<string, unknown> {
  const out = { ...existing };
  const cur = (out[field] as { sources?: string[] } | undefined) ?? {};
  const merged = new Set<string>([...(cur.sources ?? []), ...sources]);
  out[field] = { sources: Array.from(merged) };
  return out;
}

function stripHtml(s: string | undefined): string | null {
  if (!s) return null;
  return s.replace(/<[^>]+>/g, '').trim() || null;
}

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
}
