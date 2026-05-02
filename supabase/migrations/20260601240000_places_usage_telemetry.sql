-- Phase G.1 (places-cost-and-owned-data plan) — telemetry pipeline.
--
-- Two tables:
--   * places_usage_events  — raw per-call events, append-only,
--     auto-pruned at 35 days. Bucket key is `day` (UTC date) so the
--     nightly rollup can `GROUP BY day, api, status` without touching
--     a timestamp index.
--   * places_usage_daily   — pre-aggregated rollup the dashboard
--     reads from. Updated by the `places-usage-rollup` Edge Function
--     (cron-scheduled, see migration's pg_cron section).
--
-- The split is deliberate: raw events are useful for ad-hoc
-- forensics (e.g. "which place_id triggered a Place Details call
-- yesterday at 03:14") while the dashboard only ever joins on the
-- summary, which stays small enough to query without indexes.
--
-- Both tables are SERVICE-ROLE-ONLY. No anon/auth role gets read or
-- write — the Edge Functions write events directly and the dashboard
-- queries via service role.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------
-- places_usage_events: raw call log
-- ---------------------------------------------------------------

create table if not exists public.places_usage_events (
  id          uuid primary key default gen_random_uuid(),
  ts          timestamptz not null default now(),
  -- Logical UTC bucket. STORED so the rollup index doesn't need a
  -- functional expression on every group-by.
  day         date generated always as ((ts at time zone 'UTC')::date) stored,
  -- Logical API name (e.g. 'place_details', 'compute_routes',
  -- 'mk_directions', 'mk_local_search', 'apple_geocode').
  api         text not null,
  -- Coarse outcome classifier (e.g. 'cached_call', 'cache_hit',
  -- 'city_travel_times_hit', 'miss', 'error').
  status      text not null,
  -- Optional opaque key — usually a SHA-256 hash of the request key
  -- so we can spot hot keys without storing PII or business data.
  key_hash    text,
  -- Optional payload. Keep small; the dashboard never reads this.
  meta        jsonb
);

comment on table public.places_usage_events is
  'Phase G.1 raw telemetry for every Google + MapKit call we make. '
  'Auto-pruned after 35 days by `places-usage-rollup`.';

create index if not exists places_usage_events_day_api_status_idx
  on public.places_usage_events (day, api, status);

-- We never want anon or auth to even see this exists.
alter table public.places_usage_events enable row level security;

-- (No policies: service role bypasses RLS; everyone else is denied.)

-- ---------------------------------------------------------------
-- places_usage_daily: rollup table
-- ---------------------------------------------------------------

create table if not exists public.places_usage_daily (
  day        date not null,
  api        text not null,
  status     text not null,
  count      bigint not null,
  updated_at timestamptz not null default now(),
  primary key (day, api, status)
);

comment on table public.places_usage_daily is
  'Phase G.1 nightly aggregate of `places_usage_events`. The cost '
  'dashboard reads from here.';

alter table public.places_usage_daily enable row level security;

-- ---------------------------------------------------------------
-- RPC: record_places_usage_event
-- ---------------------------------------------------------------
-- Called fire-and-forget by Edge Functions whenever they hit
-- Google or MapKit. Returns void so callers don't need to read the
-- response. SECURITY DEFINER so callers don't need direct insert
-- on the underlying table.

create or replace function public.record_places_usage_event(
  p_api      text,
  p_status   text,
  p_key_hash text default null,
  p_meta     jsonb default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_api is null or p_status is null then
    return;
  end if;
  insert into public.places_usage_events (api, status, key_hash, meta)
  values (p_api, p_status, p_key_hash, p_meta);
end;
$$;

revoke all on function public.record_places_usage_event(text, text, text, jsonb) from public;
grant execute on function public.record_places_usage_event(text, text, text, jsonb) to service_role;

comment on function public.record_places_usage_event is
  'Phase G.1 — append a raw usage event. Called by Edge Functions on '
  'every Google/MapKit hit. Service-role only.';

-- ---------------------------------------------------------------
-- Cron schedule (idempotent): nightly rollup at 02:30 UTC
-- ---------------------------------------------------------------
-- The actual rollup logic lives in the
-- `places-usage-rollup` Edge Function (Deno). pg_cron triggers it
-- via supabase_functions.http_request when present; if pg_cron is
-- unavailable (local dev), the schedule entry is still created but
-- inert, and the function can be invoked manually.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('places-usage-rollup-nightly');
    exception when others then
      -- First install — nothing to unschedule. Swallow.
      null;
    end;

    perform cron.schedule(
      'places-usage-rollup-nightly',
      '30 2 * * *',
      $cron$
        select net.http_post(
          url := current_setting('app.supabase_functions_url', true)
                 || '/places-usage-rollup',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' ||
              current_setting('app.supabase_service_role_key', true)
          ),
          body := '{}'::jsonb
        );
      $cron$
    );
  end if;
end
$$;
