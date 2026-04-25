-- Phase E.1 + E.2 — User-driven place reports.
--
-- Lets a signed-in user flag a `city_places` row as broken/wrong/etc. Three
-- distinct reports flip the row's status to 'reported' so the next call to
-- `claim_city_place_enrichment_jobs` re-validates it (or hides it from the
-- pool until a moderator inspects).
--
-- Audit table is keyed by (place, reporter, reason) so the same user can't
-- spam the same complaint to inflate the count, but is allowed to file
-- different reasons against the same place (e.g. "closed" *and* "incorrect").

-- 1. Audit table
CREATE TABLE IF NOT EXISTS public.city_place_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_place_id uuid NOT NULL REFERENCES public.city_places (id) ON DELETE CASCADE,
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (reason IN ('closed', 'incorrect', 'inappropriate', 'other')),
  details text,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- Same user, same reason, same place → only one row. Different reasons
  -- against the same place ARE allowed (the user might be reporting both
  -- "closed" and "inappropriate" — both are legitimate signals).
  UNIQUE (city_place_id, reporter_user_id, reason)
);

CREATE INDEX IF NOT EXISTS city_place_reports_place_idx
  ON public.city_place_reports (city_place_id, created_at DESC);

CREATE INDEX IF NOT EXISTS city_place_reports_reporter_idx
  ON public.city_place_reports (reporter_user_id, created_at DESC);

COMMENT ON TABLE public.city_place_reports IS
  'Phase E.1: user reports against city_places rows. Three distinct reports '
  'against the same place flip its status to ''reported'' (see report_city_place RPC).';

-- 2. RLS
ALTER TABLE public.city_place_reports ENABLE ROW LEVEL SECURITY;

-- Users can see their own reports (so the iOS UI can disable the button if
-- they've already reported with that reason). They cannot see others'
-- reports (PII / abuse vector).
CREATE POLICY city_place_reports_self_read ON public.city_place_reports
  FOR SELECT
  USING (reporter_user_id = auth.uid());

-- Inserts always go through the report_city_place RPC (SECURITY DEFINER),
-- which validates inputs and bumps reported_count atomically. Direct
-- INSERTs from clients are forbidden so we don't have two ways to write
-- this table.
GRANT SELECT ON public.city_place_reports TO authenticated;

-- 3. RPC: report_city_place
--
-- Atomically:
--   1. Inserts the audit row (no-op if the user already reported this
--      reason — the unique key takes care of it).
--   2. Recomputes the unique reporter count from the audit table.
--   3. Updates city_places.reported_count + reported_at.
--   4. Flips status to 'reported' once 3+ distinct reporters complain.
CREATE OR REPLACE FUNCTION public.report_city_place(
  p_city_place_id uuid,
  p_reason text,
  p_details text DEFAULT NULL
)
RETURNS public.city_places
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_reporter_count integer;
  v_row public.city_places%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;
  IF p_reason NOT IN ('closed', 'incorrect', 'inappropriate', 'other') THEN
    RAISE EXCEPTION 'invalid reason: %', p_reason USING ERRCODE = '22023';
  END IF;

  -- Audit row (idempotent on (place, user, reason)).
  INSERT INTO public.city_place_reports (city_place_id, reporter_user_id, reason, details)
  VALUES (p_city_place_id, v_user_id, p_reason, p_details)
  ON CONFLICT (city_place_id, reporter_user_id, reason) DO NOTHING;

  -- Distinct reporters across all reasons. We use distinct user count, not
  -- raw audit row count, so a single user filing two complaints against the
  -- same place isn't worth more than one signal toward the threshold.
  SELECT COUNT(DISTINCT reporter_user_id)
    INTO v_reporter_count
    FROM public.city_place_reports
   WHERE city_place_id = p_city_place_id;

  UPDATE public.city_places
     SET reported_count = v_reporter_count,
         reported_at = now(),
         status = CASE
           WHEN v_reporter_count >= 3 AND status = 'active' THEN 'reported'
           ELSE status
         END
   WHERE id = p_city_place_id
   RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'city_place not found: %', p_city_place_id USING ERRCODE = 'P0002';
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.report_city_place(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_city_place(uuid, text, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.report_city_place(uuid, text, text) IS
  'Phase E.2: idempotent per-user report; flips city_places.status to ''reported'' once 3+ distinct users complain.';
