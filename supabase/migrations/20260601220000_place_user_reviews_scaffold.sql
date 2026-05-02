-- Phase I.4 (FUTURE) — Owned reviews scaffold.
--
-- Mirrors `place_user_photos` (F.1) so the same moderation pipeline,
-- DSA appeal table, and per-row community-report mechanism can be
-- pointed at user reviews when we ship the feature. Nothing in the
-- iOS app reads or writes these tables yet — the migration exists so
-- that:
--
--   1. The schema is reviewable as part of the Phase I.4 plan item.
--   2. We can backfill / soft-launch reviews behind a feature flag
--      without a follow-up migration burst.
--   3. `city_places.review_summary_user` aggregates can be wired into
--      the existing AI summary flow as soon as enough reviews exist.
--
-- Tables created here are off the hot path: they have no inbound
-- foreign keys from existing app tables and the RLS policies default
-- to private-until-approved, identical to F.1 photos.

CREATE TABLE IF NOT EXISTS public.place_user_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_place_id uuid NOT NULL REFERENCES public.city_places (id) ON DELETE CASCADE,
  uploader_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  body text NOT NULL CHECK (char_length(body) BETWEEN 20 AND 2000),
  language text,
  -- Lifecycle mirrors place_user_photos.status. Same moderation
  -- pipeline (`moderate-place-review` Edge Function in a follow-up)
  -- transitions rows through these states.
  status text NOT NULL DEFAULT 'pending_moderation' CHECK (status IN (
    'pending_moderation', 'approved', 'pending_review',
    'rejected', 'removed'
  )),
  reject_reason text,
  reject_detail text,
  helpful_count integer NOT NULL DEFAULT 0,
  reported_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  removed_at timestamptz,
  -- Anti-spam: one review per user per place. Edits land in-place via
  -- UPDATE; lifetime versioning is a future concern.
  CONSTRAINT place_user_reviews_unique_per_user
    UNIQUE (city_place_id, uploader_user_id)
);

CREATE INDEX IF NOT EXISTS place_user_reviews_place_status_idx
  ON public.place_user_reviews (city_place_id, status, approved_at DESC);

CREATE INDEX IF NOT EXISTS place_user_reviews_uploader_idx
  ON public.place_user_reviews (uploader_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS place_user_reviews_pending_review_idx
  ON public.place_user_reviews (created_at)
  WHERE status = 'pending_review';

ALTER TABLE public.place_user_reviews ENABLE ROW LEVEL SECURITY;

-- Public visibility is identical to photos: only `approved` rows are
-- world-readable. Uploaders can always see their own (any status).
CREATE POLICY place_user_reviews_public_read_approved
  ON public.place_user_reviews
  FOR SELECT USING (status = 'approved');

CREATE POLICY place_user_reviews_self_read
  ON public.place_user_reviews
  FOR SELECT USING (uploader_user_id = auth.uid());

CREATE POLICY place_user_reviews_self_insert
  ON public.place_user_reviews
  FOR INSERT WITH CHECK (uploader_user_id = auth.uid());

-- Self-edit window: uploader can amend their own review until it's
-- approved. After approval, edits go through a re-moderation flow
-- that we'll wire up alongside the moderation function.
CREATE POLICY place_user_reviews_self_update
  ON public.place_user_reviews
  FOR UPDATE
  USING (uploader_user_id = auth.uid()
         AND status IN ('pending_moderation', 'rejected'))
  WITH CHECK (uploader_user_id = auth.uid());

GRANT SELECT ON public.place_user_reviews TO anon, authenticated;
GRANT INSERT, UPDATE ON public.place_user_reviews TO authenticated;

-- Community report ledger for reviews. Same shape as
-- `place_user_photo_reports` (F.8) so the moderation backend can be
-- generalised across content types.
CREATE TABLE IF NOT EXISTS public.place_user_review_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id uuid NOT NULL REFERENCES public.place_user_reviews (id) ON DELETE CASCADE,
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (reason IN (
    'inappropriate', 'misleading', 'spam_or_ad', 'other'
  )),
  details text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT place_user_review_reports_unique_per_user
    UNIQUE (review_id, reporter_user_id)
);

CREATE INDEX IF NOT EXISTS place_user_review_reports_review_idx
  ON public.place_user_review_reports (review_id, created_at DESC);

ALTER TABLE public.place_user_review_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY place_user_review_reports_self_read
  ON public.place_user_review_reports
  FOR SELECT USING (reporter_user_id = auth.uid());

GRANT SELECT ON public.place_user_review_reports TO authenticated;

-- city_places aggregate columns. Kept nullable so existing rows
-- without any reviews stay quiet. The aggregate refresh is the job of
-- a future Edge Function (`aggregate-place-user-reviews`); the column
-- exists now so the iOS read path doesn't need a follow-up migration
-- when the feature ships.
ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS user_review_average numeric(3,2),
  ADD COLUMN IF NOT EXISTS user_review_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS user_review_summary text,
  ADD COLUMN IF NOT EXISTS user_review_summary_at timestamptz;

COMMENT ON COLUMN public.city_places.user_review_summary IS
  'AI-generated summary of approved place_user_reviews. Phase I.4 scaffold; '
  'populated by a future aggregate-place-user-reviews Edge Function.';
