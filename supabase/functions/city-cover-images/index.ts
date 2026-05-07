import { createClient } from 'npm:@supabase/supabase-js@2';

type SupabaseClient = ReturnType<typeof createClient>;

type WorkerArgs = {
  batch_size?: number;
  download_batch_size?: number;
  backfill_missing?: boolean;
};

type CoverFetchJob = {
  id: string;
  city_profile_id: string;
  attempts: number;
};

type CityProfile = {
  id: string;
  display_name: string;
  country_code: string | null;
  city_search_label: string | null;
};

type UnsplashResult = {
  id: string;
  width?: number;
  height?: number;
  /** Community likes — used to prefer stronger photos when many match the search. */
  likes?: number;
  urls?: { regular?: string };
  user?: {
    name?: string;
    username?: string;
    links?: { html?: string };
  };
  links?: {
    html?: string;
    download_location?: string;
  };
};

type UnsplashSearchResponse = {
  results?: UnsplashResult[];
  errors?: string[];
};

type CoverAssignment = {
  id: string;
  download_location: string | null;
};

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const UNSPLASH_ACCESS_KEY = Deno.env.get('UNSPLASH_ACCESS_KEY') ?? '';
const WORKER_SECRET =
  Deno.env.get('CITY_COVER_WORKER_SECRET') ?? Deno.env.get('WORKER_SECRET') ?? '';

/**
 * Unsplash quota — **search/photos only** (one HTTP GET = one billable search).
 *
 * - **50** calls max per rolling hour (override with `UNSPLASH_SEARCH_HOURLY_MAX` or legacy `UNSPLASH_HOURLY_BUDGET`).
 * - **30** images returned per search (`per_page`; Unsplash API maximum for this endpoint).
 */
const UNSPLASH_SEARCH_HOURLY_MAX = (() => {
  const raw = Number(
    Deno.env.get('UNSPLASH_SEARCH_HOURLY_MAX') ??
      Deno.env.get('UNSPLASH_HOURLY_BUDGET') ??
      '50'
  );
  if (!Number.isFinite(raw)) return 50;
  return Math.max(1, Math.min(500, Math.trunc(raw)));
})();
/** Unsplash allows at most 30 results per `GET /search/photos` — do not raise. */
const UNSPLASH_SEARCH_PER_PAGE = 30;

const SEARCH_ENDPOINT = 'search/photos';
const DOWNLOAD_ENDPOINT = 'photos/download';
/** How many curated rows we keep per city profile (after ranking candidates). */
const TARGET_POOL_SIZE = 12;
/** Drop tiny thumbnails that look bad as trip hero covers. */
const MIN_SHORT_EDGE_PX = 1080;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }

  if (WORKER_SECRET && req.headers.get('x-worker-secret') !== WORKER_SECRET) {
    return json({ error: 'forbidden' }, 403);
  }

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: 'missing_supabase_env' }, 500);
  }

  let args: WorkerArgs = {};
  try {
    args = (await req.json()) as WorkerArgs;
  } catch {
    args = {};
  }

  const batchSize = clamp(args.batch_size ?? 5, 1, 25);
  const downloadBatchSize = clamp(args.download_batch_size ?? 25, 1, 100);

  try {
    let enqueued = 0;
    if (args.backfill_missing) {
      enqueued = await enqueueMissingPools(supabase, batchSize);
    }

    const jobs = await claimFetchJobs(supabase, batchSize);
    const fetchResults = [];
    for (const job of jobs) {
      fetchResults.push(await processFetchJob(supabase, job));
    }

    const assignments = await claimDownloadAssignments(
      supabase,
      downloadBatchSize
    );
    const downloadResults = [];
    for (const assignment of assignments) {
      downloadResults.push(await processDownloadAssignment(supabase, assignment));
    }

    return json({
      ok: true,
      enqueued,
      claimed: jobs.length,
      fetch_results: fetchResults,
      downloads_claimed: assignments.length,
      download_results: downloadResults,
      unsplash_search_policy: {
        hourly_max_requests: UNSPLASH_SEARCH_HOURLY_MAX,
        images_per_search_request: UNSPLASH_SEARCH_PER_PAGE,
      },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[city-cover-images] failed:', message);
    return json({ error: message }, 500);
  }
});

async function enqueueMissingPools(
  client: SupabaseClient,
  limit: number
): Promise<number> {
  const { data, error } = await client.rpc(
    'enqueue_missing_city_profile_cover_fetches',
    { p_limit: limit }
  );
  if (error) throw new Error(`enqueue missing: ${error.message}`);
  return typeof data === 'number' ? data : 0;
}

async function claimFetchJobs(
  client: SupabaseClient,
  batchSize: number
): Promise<CoverFetchJob[]> {
  const { data, error } = await client.rpc('claim_city_profile_cover_fetch_jobs', {
    p_batch_size: batchSize,
  });
  if (error) throw new Error(`claim fetch jobs: ${error.message}`);
  return (data ?? []) as CoverFetchJob[];
}

async function processFetchJob(client: SupabaseClient, job: CoverFetchJob) {
  if (!UNSPLASH_ACCESS_KEY) {
    await failJob(client, job.id, 'missing_unsplash_access_key');
    return { job_id: job.id, status: 'failed', reason: 'missing_key' };
  }

  const city = await loadCityProfile(client, job.city_profile_id);
  if (!city) {
    await failJob(client, job.id, 'city_profile_not_found');
    return { job_id: job.id, status: 'failed', reason: 'city_not_found' };
  }

  const currentCount = await activeCoverCount(client, city.id);
  if (currentCount >= TARGET_POOL_SIZE) {
    await completeJob(client, job.id);
    return { job_id: job.id, status: 'skipped', reason: 'pool_full' };
  }

  const usedThisHour = await hourlyUsage(client, SEARCH_ENDPOINT);
  if (usedThisHour >= UNSPLASH_SEARCH_HOURLY_MAX) {
    await requeueJob(client, job.id, 'unsplash_search_hourly_cap_exhausted', 15);
    return { job_id: job.id, status: 'deferred', reason: 'quota' };
  }

  try {
    const photos = await fetchUnsplashPhotos(city);
    await recordUsage(client, SEARCH_ENDPOINT, city.id, 'success', {
      returned: photos.length,
    });

    if (photos.length > 0) {
      await upsertCoverImages(client, city.id, photos);
    }

    await completeJob(client, job.id);
    return { job_id: job.id, status: 'done', inserted_or_updated: photos.length };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await recordUsage(client, SEARCH_ENDPOINT, city.id, 'error', { message });
    await failJob(client, job.id, message);
    return { job_id: job.id, status: 'failed', reason: message };
  }
}

async function loadCityProfile(
  client: SupabaseClient,
  cityProfileId: string
): Promise<CityProfile | null> {
  const { data, error } = await client
    .from('city_profiles')
    .select('id,display_name,country_code,city_search_label')
    .eq('id', cityProfileId)
    .maybeSingle();
  if (error) throw new Error(`load city profile: ${error.message}`);
  return (data as CityProfile | null) ?? null;
}

async function activeCoverCount(
  client: SupabaseClient,
  cityProfileId: string
): Promise<number> {
  const { count, error } = await client
    .from('city_profile_cover_images')
    .select('id', { count: 'exact', head: true })
    .eq('city_profile_id', cityProfileId)
    .eq('is_active', true);
  if (error) throw new Error(`count covers: ${error.message}`);
  return count ?? 0;
}

async function hourlyUsage(
  client: SupabaseClient,
  endpoint: string
): Promise<number> {
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { data, error } = await client
    .from('external_api_usage_events')
    .select('request_count')
    .eq('provider', 'unsplash')
    .eq('endpoint', endpoint)
    .gte('created_at', since);
  if (error) throw new Error(`quota lookup: ${error.message}`);
  return ((data ?? []) as { request_count: number }[]).reduce(
    (sum, row) => sum + (row.request_count ?? 0),
    0
  );
}

function rankCoverCandidates(photos: UnsplashResult[]): UnsplashResult[] {
  const basic = photos.filter((p) => p.id && p.urls?.regular);
  const hiRes = basic.filter((photo) => {
    const w = photo.width ?? 0;
    const h = photo.height ?? 0;
    if (w <= 0 || h <= 0) return true;
    return Math.min(w, h) >= MIN_SHORT_EDGE_PX;
  });
  const pool = hiRes.length >= TARGET_POOL_SIZE ? hiRes : basic;

  return [...pool]
    .sort((a, b) => {
      const likeA = a.likes ?? 0;
      const likeB = b.likes ?? 0;
      if (likeB !== likeA) return likeB - likeA;
      const areaA = (a.width ?? 0) * (a.height ?? 0);
      const areaB = (b.width ?? 0) * (b.height ?? 0);
      return areaB - areaA;
    })
    .slice(0, TARGET_POOL_SIZE);
}

async function fetchUnsplashPhotos(
  city: CityProfile
): Promise<UnsplashResult[]> {
  // Prefer `city_search_label` (usually "City, Region/Country" from Places) over
  // bare `display_name` to avoid ambiguous names (e.g. multiple "Springfield"s).
  const primary =
    city.city_search_label?.trim() ||
    city.display_name?.trim() ||
    '';
  const country = city.country_code?.trim();
  const query = [
    primary,
    country,
    'cityscape architecture travel',
  ]
    .filter((part) => Boolean(part && String(part).length > 0))
    .join(' ');

  const url = new URL('https://api.unsplash.com/search/photos');
  url.searchParams.set('query', query);
  url.searchParams.set('orientation', 'landscape');
  url.searchParams.set('per_page', String(UNSPLASH_SEARCH_PER_PAGE));
  url.searchParams.set('content_filter', 'high');
  // Default is relevant; set explicitly so behavior stays predictable if API changes.
  url.searchParams.set('order_by', 'relevant');

  const response = await fetch(url, {
    headers: { Authorization: `Client-ID ${UNSPLASH_ACCESS_KEY}` },
  });
  const body = (await response.json().catch(() => ({}))) as UnsplashSearchResponse;
  if (!response.ok) {
    const detail = body.errors?.join(', ') || response.statusText;
    throw new Error(`unsplash_search_${response.status}: ${detail}`);
  }

  return rankCoverCandidates(body.results ?? []);
}

async function upsertCoverImages(
  client: SupabaseClient,
  cityProfileId: string,
  photos: UnsplashResult[]
) {
  const rows = photos.map((photo, index) => {
    const photographerName = photo.user?.name?.trim() || null;
    const photographerUsername = photo.user?.username?.trim() || null;
    const photographerUrl = photo.user?.links?.html?.trim() || null;
    const photoPageUrl = photo.links?.html?.trim() || null;

    return {
      city_profile_id: cityProfileId,
      source: 'unsplash',
      source_photo_id: photo.id,
      image_url: photo.urls?.regular ?? '',
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
      position: index,
      is_active: true,
      fetched_at: new Date().toISOString(),
    };
  });

  const { error } = await client
    .from('city_profile_cover_images')
    .upsert(rows, {
      onConflict: 'city_profile_id,source,source_photo_id',
    });
  if (error) throw new Error(`upsert covers: ${error.message}`);
}

async function completeJob(client: SupabaseClient, jobId: string) {
  const { error } = await client
    .from('city_profile_cover_fetch_jobs')
    .update({
      status: 'done',
      last_error: null,
      finished_at: new Date().toISOString(),
    })
    .eq('id', jobId);
  if (error) throw new Error(`complete job: ${error.message}`);
}

async function failJob(client: SupabaseClient, jobId: string, message: string) {
  const { error } = await client
    .from('city_profile_cover_fetch_jobs')
    .update({
      status: 'failed',
      last_error: message.slice(0, 1000),
      run_after: minutesFromNow(30),
      finished_at: new Date().toISOString(),
    })
    .eq('id', jobId);
  if (error) throw new Error(`fail job: ${error.message}`);
}

async function requeueJob(
  client: SupabaseClient,
  jobId: string,
  message: string,
  delayMinutes: number
) {
  const { error } = await client
    .from('city_profile_cover_fetch_jobs')
    .update({
      status: 'pending',
      last_error: message.slice(0, 1000),
      run_after: minutesFromNow(delayMinutes),
      finished_at: null,
    })
    .eq('id', jobId);
  if (error) throw new Error(`requeue job: ${error.message}`);
}

async function claimDownloadAssignments(
  client: SupabaseClient,
  batchSize: number
): Promise<CoverAssignment[]> {
  const { data, error } = await client.rpc(
    'claim_city_profile_cover_download_assignments',
    { p_batch_size: batchSize }
  );
  if (error) throw new Error(`claim downloads: ${error.message}`);
  return (data ?? []) as CoverAssignment[];
}

async function processDownloadAssignment(
  client: SupabaseClient,
  assignment: CoverAssignment
) {
  if (!assignment.download_location || !UNSPLASH_ACCESS_KEY) {
    await markDownloadTrackingFailed(
      client,
      assignment.id,
      'missing_download_location_or_key'
    );
    return { assignment_id: assignment.id, status: 'failed' };
  }

  try {
    const url = new URL(assignment.download_location);
    url.searchParams.set('client_id', UNSPLASH_ACCESS_KEY);
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`unsplash_download_${response.status}`);
    }

    await markDownloadTracked(client, assignment.id);
    await recordUsage(client, DOWNLOAD_ENDPOINT, null, 'success', null);
    return { assignment_id: assignment.id, status: 'tracked' };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await markDownloadTrackingFailed(client, assignment.id, message);
    await recordUsage(client, DOWNLOAD_ENDPOINT, null, 'error', { message });
    return { assignment_id: assignment.id, status: 'failed', reason: message };
  }
}

async function markDownloadTracked(client: SupabaseClient, assignmentId: string) {
  const { error } = await client
    .from('city_profile_cover_assignments')
    .update({
      download_tracked_at: new Date().toISOString(),
      download_track_last_error: null,
    })
    .eq('id', assignmentId);
  if (error) throw new Error(`mark download tracked: ${error.message}`);
}

async function markDownloadTrackingFailed(
  client: SupabaseClient,
  assignmentId: string,
  message: string
) {
  const { error } = await client
    .from('city_profile_cover_assignments')
    .update({ download_track_last_error: message.slice(0, 1000) })
    .eq('id', assignmentId);
  if (error) throw new Error(`mark download failed: ${error.message}`);
}

async function recordUsage(
  client: SupabaseClient,
  endpoint: string,
  cityProfileId: string | null,
  status: string,
  meta: Record<string, unknown> | null
) {
  const { error } = await client.rpc('record_external_api_usage_event', {
    p_provider: 'unsplash',
    p_endpoint: endpoint,
    p_city_profile_id: cityProfileId,
    p_request_count: 1,
    p_status: status,
    p_meta: meta,
  });
  if (error) {
    console.warn('[city-cover-images] usage event failed:', error.message);
  }
}

function minutesFromNow(minutes: number): string {
  return new Date(Date.now() + minutes * 60 * 1000).toISOString();
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.max(min, Math.min(max, Math.trunc(value)));
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
