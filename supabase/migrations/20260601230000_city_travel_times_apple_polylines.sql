-- Phase J.1 — Apple Maps polylines + per-mode provider tracking on
-- `city_travel_times`.
--
-- Today the table stores a single ETA per mode + a single `provider`
-- column for the row, which is wrong: in practice, walking + driving
-- can both come from Apple while transit still falls back to Google
-- or haversine. We need per-mode provenance and per-mode polylines so
-- the iOS map can render the actual route and the AI seed can prefer
-- Apple-sourced legs over the older `cached_google.cachedDirections`
-- fallback.
--
-- Polyline encoding: Google's polyline algorithm format 5 (precision
-- 1e-5). MapKit's `MKPolyline` is encoded with the same algorithm via
-- `AppleTravelTimesService` on the iOS side (Phase J.3) so the bytes
-- are interchangeable with anything we already cache from Google.
--
-- Apple cycling: NOT exposed via `MKDirections`. We deliberately do
-- NOT add a `cycling_polyline` column — fall back to walking_polyline
-- and let the iOS layer add a "cycling estimate" badge instead. This
-- doc comment is the audit trail.

-- Per-mode polylines (Google polyline algo, precision 1e-5).
ALTER TABLE public.city_travel_times
  ADD COLUMN IF NOT EXISTS walking_polyline text,
  ADD COLUMN IF NOT EXISTS driving_polyline text,
  ADD COLUMN IF NOT EXISTS transit_polyline text;

-- Per-mode provider so we can mix sources within a single row.
-- 'apple' = MKDirections via the iOS uploader (preferred when
-- available — free + Apple-quality routing in most regions).
-- 'google' = cached_google.cachedDirections fallback.
-- 'haversine' = straight-line estimate, the baseline.
ALTER TABLE public.city_travel_times
  ADD COLUMN IF NOT EXISTS walking_provider text
    CHECK (walking_provider IS NULL
      OR walking_provider IN ('apple', 'google', 'haversine')),
  ADD COLUMN IF NOT EXISTS driving_provider text
    CHECK (driving_provider IS NULL
      OR driving_provider IN ('apple', 'google', 'haversine')),
  ADD COLUMN IF NOT EXISTS transit_provider text
    CHECK (transit_provider IS NULL
      OR transit_provider IN ('apple', 'google', 'haversine'));

-- Tracks the most recent `apple` write so the upload Edge Function
-- (Phase J.2) can short-circuit when we already have a fresh Apple
-- row (skip writes when existing Apple row is fresher than 30 days).
ALTER TABLE public.city_travel_times
  ADD COLUMN IF NOT EXISTS apple_refreshed_at timestamptz;

-- Partial index for the iOS read path: "give me the freshest Apple
-- row for this leg if any". Keeps the planner away from the existing
-- composite when the read explicitly wants Apple-sourced data only.
CREATE INDEX IF NOT EXISTS city_travel_times_apple_lookup
  ON public.city_travel_times (city_profile_id, from_place_id, to_place_id)
  WHERE apple_refreshed_at IS NOT NULL;

-- Backfill the per-mode provider columns from the legacy single
-- provider column so existing rows don't show up as "unknown source"
-- the moment the iOS app starts reading the new fields. Idempotent —
-- this migration may be run on top of a partially-migrated database.
--
-- Legacy rows may carry providers outside our new allow-list
-- ('mapbox', etc. from older experiments). Sanitize anything we
-- don't recognize to NULL so we don't trip the CHECK constraint —
-- the iOS layer treats NULL provider as "unknown source" and will
-- re-resolve via the normal Apple/Google/haversine path.
UPDATE public.city_travel_times
   SET walking_provider = COALESCE(
         walking_provider,
         CASE WHEN provider IN ('apple', 'google', 'haversine')
              THEN provider END
       ),
       driving_provider = COALESCE(
         driving_provider,
         CASE WHEN provider IN ('apple', 'google', 'haversine')
              THEN provider END
       ),
       transit_provider = COALESCE(
         transit_provider,
         CASE WHEN provider IN ('apple', 'google', 'haversine')
              THEN provider END
       )
 WHERE walking_provider IS NULL
    OR driving_provider IS NULL
    OR transit_provider IS NULL;

COMMENT ON COLUMN public.city_travel_times.walking_polyline IS
  'Google polyline algorithm (precision 1e-5) for the walking route. '
  'Phase J.1 — populated by the upload-travel-leg Edge Function from '
  'MKPolyline data captured client-side.';
COMMENT ON COLUMN public.city_travel_times.apple_refreshed_at IS
  'Most recent successful write of an apple-sourced row. The upload '
  'function skips writes when this is < 30 days old to avoid burning '
  'iOS battery on routes the cache already covers.';
