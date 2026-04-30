#!/usr/bin/env node

/**
 * Backfill Unsplash cover pools for city_profiles.
 *
 * Required env:
 *   SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY
 *   UNSPLASH_ACCESS_KEY
 *
 * Optional env:
 *   CITY_PROFILE_ID       Backfill one city profile only
 *   LIMIT                 Max city profiles to scan, default 100
 *   PER_PAGE              Unsplash images per city, default 20
 *   MIN_ACTIVE_COVERS     Skip cities with this many active covers, default 20
 *   DRY_RUN=1             Fetch and print without writing
 *
 * Example:
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... UNSPLASH_ACCESS_KEY=... \
 *     node scripts/backfill-city-profile-covers.mjs
 */

const SUPABASE_URL = requiredEnv('SUPABASE_URL').replace(/\/$/, '');
const SERVICE_ROLE_KEY = requiredEnv('SUPABASE_SERVICE_ROLE_KEY');
const UNSPLASH_ACCESS_KEY = requiredEnv('UNSPLASH_ACCESS_KEY');

const CITY_PROFILE_ID = process.env.CITY_PROFILE_ID?.trim();
const LIMIT = clampNumber(process.env.LIMIT, 100, 1, 1000);
const PER_PAGE = clampNumber(process.env.PER_PAGE, 20, 1, 30);
const MIN_ACTIVE_COVERS = clampNumber(process.env.MIN_ACTIVE_COVERS, 20, 1, 100);
const DRY_RUN = process.env.DRY_RUN === '1';

const headers = {
  apikey: SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  'Content-Type': 'application/json',
};

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});

async function main() {
  const cities = await loadCityProfiles();
  console.log(`Found ${cities.length} city profile(s) to inspect.`);

  let processed = 0;
  for (const city of cities) {
    const activeCount = await activeCoverCount(city.id);
    if (activeCount >= MIN_ACTIVE_COVERS) {
      console.log(`Skipping ${city.display_name}: already has ${activeCount} active covers.`);
      continue;
    }

    const photos = await fetchUnsplashPhotos(city);
    if (photos.length === 0) {
      console.log(`No Unsplash results for ${city.display_name}.`);
      continue;
    }

    const rows = photos.map((photo, index) => coverRow(city.id, photo, index));
    if (DRY_RUN) {
      console.log(`[dry-run] ${city.display_name}: would upsert ${rows.length} cover(s).`);
    } else {
      await upsertCoverRows(rows);
      await recordUsage(city.id, photos.length);
      console.log(`${city.display_name}: upserted ${rows.length} cover(s).`);
    }
    processed += 1;
  }

  console.log(`Done. Processed ${processed} city profile(s).`);
}

async function loadCityProfiles() {
  const params = new URLSearchParams();
  params.set('select', 'id,display_name,country_code,city_search_label,created_at');
  params.set('order', 'created_at.asc');
  params.set('limit', String(LIMIT));
  if (CITY_PROFILE_ID) {
    params.set('id', `eq.${CITY_PROFILE_ID}`);
  }

  const response = await supabaseFetch(`/rest/v1/city_profiles?${params}`);
  return response.json();
}

async function activeCoverCount(cityProfileId) {
  const params = new URLSearchParams();
  params.set('select', 'id');
  params.set('city_profile_id', `eq.${cityProfileId}`);
  params.set('is_active', 'eq.true');

  const response = await fetch(`${SUPABASE_URL}/rest/v1/city_profile_cover_images?${params}`, {
    headers: {
      ...headers,
      Prefer: 'count=exact',
      Range: '0-0',
    },
  });
  if (!response.ok) {
    throw new Error(`cover count failed (${response.status}): ${await response.text()}`);
  }

  const contentRange = response.headers.get('content-range') ?? '';
  const total = contentRange.split('/').at(-1);
  return total && total !== '*' ? Number(total) : 0;
}

async function fetchUnsplashPhotos(city) {
  const query = [city.display_name, city.country_code, 'travel city landmark skyline']
    .filter(Boolean)
    .join(' ');
  const url = new URL('https://api.unsplash.com/search/photos');
  url.searchParams.set('query', query);
  url.searchParams.set('orientation', 'landscape');
  url.searchParams.set('per_page', String(PER_PAGE));
  url.searchParams.set('content_filter', 'high');

  const response = await fetch(url, {
    headers: { Authorization: `Client-ID ${UNSPLASH_ACCESS_KEY}` },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = Array.isArray(body.errors) ? body.errors.join(', ') : response.statusText;
    throw new Error(`Unsplash failed for ${city.display_name} (${response.status}): ${detail}`);
  }

  return (body.results ?? []).filter((photo) => photo.id && photo.urls?.regular);
}

function coverRow(cityProfileId, photo, position) {
  const photographerName = photo.user?.name?.trim() || null;
  const photographerUsername = photo.user?.username?.trim() || null;
  const photographerUrl = photo.user?.links?.html?.trim() || null;
  const photoPageUrl = photo.links?.html?.trim() || null;

  return {
    city_profile_id: cityProfileId,
    source: 'unsplash',
    source_photo_id: photo.id,
    image_url: photo.urls.regular,
    image_width: photo.width ?? null,
    image_height: photo.height ?? null,
    photographer_name: photographerName,
    photographer_username: photographerUsername,
    photographer_url: photographerUrl,
    photo_page_url: photoPageUrl,
    download_location: photo.links?.download_location?.trim() || null,
    attribution: {
      source: 'unsplash',
      photographer: photographerName,
      photographerUsername,
      photographerUrl,
      photoPageUrl,
      text: `Photo by ${photographerName ?? 'Unsplash'} on Unsplash`,
    },
    position,
    is_active: true,
    fetched_at: new Date().toISOString(),
  };
}

async function upsertCoverRows(rows) {
  const params = new URLSearchParams();
  params.set('on_conflict', 'city_profile_id,source,source_photo_id');

  await supabaseFetch(`/rest/v1/city_profile_cover_images?${params}`, {
    method: 'POST',
    headers: {
      ...headers,
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify(rows),
  });
}

async function recordUsage(cityProfileId, returned) {
  await supabaseFetch('/rest/v1/rpc/record_external_api_usage_event', {
    method: 'POST',
    body: JSON.stringify({
      p_provider: 'unsplash',
      p_endpoint: 'search/photos',
      p_city_profile_id: cityProfileId,
      p_request_count: 1,
      p_status: 'success',
      p_meta: { returned, source: 'local_backfill_script' },
    }),
  });
}

async function supabaseFetch(path, init = {}) {
  const response = await fetch(`${SUPABASE_URL}${path}`, {
    ...init,
    headers: {
      ...headers,
      ...(init.headers ?? {}),
    },
  });
  if (!response.ok) {
    throw new Error(`Supabase request failed (${response.status}) ${path}: ${await response.text()}`);
  }
  return response;
}

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env: ${name}`);
  }
  return value;
}

function clampNumber(value, fallback, min, max) {
  const parsed = Number(value ?? fallback);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(parsed)));
}
