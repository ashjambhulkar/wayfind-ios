-- Phase F.4 — `check_photo_upload_quota` RPC.
--
-- Pre-flight gate the iOS upload flow runs BEFORE asking for a signed
-- upload URL. Returns a structured verdict so the client can show the
-- right error copy ("come back tomorrow", "Pro unlocks more uploads",
-- "your account is too new") without parsing strings.
--
-- Tier rules (Section 7.6 of places-cost-and-owned-data plan):
--
--   Free tier:
--     * Account must be ≥ 24 hours old (anti-throwaway).
--     * Max 1 photo per (place, day).
--     * Max 3 photos per (user, day) across all places.
--     * Place must already exist in `city_places`.
--
--   Pro tier (`user_subscriptions.is_pro = true`):
--     * Max 10 photos per (place, day).
--     * No daily user-wide cap.
--
-- Account-locked uploaders (banned via the CSAM workflow) are blocked
-- with `account_locked` regardless of tier.

CREATE OR REPLACE FUNCTION public.check_photo_upload_quota(
  p_city_place_id uuid
)
RETURNS TABLE (allowed boolean, reason text, remaining integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_user_id uuid := auth.uid();
  v_is_pro boolean;
  v_pro_expires timestamptz;
  v_account_age interval;
  v_banned_until timestamptz;
  v_today date := (timezone('utc', now()))::date;
  v_per_place_count integer;
  v_per_user_count integer;
  v_place_exists boolean;
  v_per_place_cap integer;
  v_per_user_cap integer; -- only enforced on free tier
BEGIN
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'unauthenticated'::text, 0;
    RETURN;
  END IF;
  IF p_city_place_id IS NULL THEN
    RETURN QUERY SELECT false, 'missing_place_id'::text, 0;
    RETURN;
  END IF;

  SELECT (id IS NOT NULL)
    INTO v_place_exists
    FROM public.city_places
   WHERE id = p_city_place_id;
  IF NOT COALESCE(v_place_exists, false) THEN
    RETURN QUERY SELECT false, 'unknown_place'::text, 0;
    RETURN;
  END IF;

  SELECT (now() - created_at), banned_until
    INTO v_account_age, v_banned_until
    FROM auth.users
   WHERE id = v_user_id;

  IF v_banned_until IS NOT NULL AND v_banned_until > now() THEN
    RETURN QUERY SELECT false, 'account_locked'::text, 0;
    RETURN;
  END IF;

  SELECT us.is_pro, us.expires_at
    INTO v_is_pro, v_pro_expires
    FROM public.user_subscriptions us
   WHERE us.user_id = v_user_id;

  IF COALESCE(v_is_pro, false)
     AND (v_pro_expires IS NULL OR v_pro_expires > now()) THEN
    v_per_place_cap := 10;
    v_per_user_cap := NULL; -- unlimited
  ELSE
    -- Free tier: 24h account age requirement.
    IF v_account_age IS NULL OR v_account_age < interval '24 hours' THEN
      RETURN QUERY SELECT false, 'account_too_new'::text, 0;
      RETURN;
    END IF;
    v_per_place_cap := 1;
    v_per_user_cap := 3;
  END IF;

  -- Per-(place, day) count. Includes pending so we don't allow bursting
  -- 10 uploads to dodge moderation.
  SELECT count(*)::integer
    INTO v_per_place_count
    FROM public.place_user_photos
   WHERE city_place_id = p_city_place_id
     AND uploader_user_id = v_user_id
     AND created_at >= v_today::timestamptz;

  IF v_per_place_count >= v_per_place_cap THEN
    RETURN QUERY SELECT false, 'place_daily_cap'::text, 0;
    RETURN;
  END IF;

  IF v_per_user_cap IS NOT NULL THEN
    SELECT count(*)::integer
      INTO v_per_user_count
      FROM public.place_user_photos
     WHERE uploader_user_id = v_user_id
       AND created_at >= v_today::timestamptz;
    IF v_per_user_count >= v_per_user_cap THEN
      RETURN QUERY SELECT false, 'user_daily_cap'::text, 0;
      RETURN;
    END IF;
    RETURN QUERY SELECT
      true,
      'ok'::text,
      LEAST(v_per_place_cap - v_per_place_count, v_per_user_cap - v_per_user_count);
    RETURN;
  END IF;

  -- Pro tier path.
  RETURN QUERY SELECT true, 'ok'::text, (v_per_place_cap - v_per_place_count);
END
$fn$;

REVOKE ALL ON FUNCTION public.check_photo_upload_quota(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_photo_upload_quota(uuid)
  TO authenticated, service_role;

-- Account-lock helper used by the moderate-place-photo function on a
-- confirmed CSAM match. Soft no-op if already banned (don't shorten
-- existing bans).
CREATE OR REPLACE FUNCTION public.lock_user_account(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $fn$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;
  UPDATE auth.users
     SET banned_until = GREATEST(
       COALESCE(banned_until, now()),
       now() + interval '100 years'
     )
   WHERE id = p_user_id;
END
$fn$;

REVOKE ALL ON FUNCTION public.lock_user_account(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lock_user_account(uuid) TO service_role;
