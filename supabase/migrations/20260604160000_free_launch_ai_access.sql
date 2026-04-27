-- Free launch: temporarily grant AI day-planner access to every signed-in
-- user without marking them as paid Pro. This mirrors the iOS
-- AppConfig.grantFreeLaunchPremiumAccess flag while preserving the daily
-- safety cap so runaway clients still stop at the abuse ceiling.
--
-- When paid plans return, ship a follow-up migration that flips
-- v_free_launch_premium_access to false (or removes this override).

CREATE OR REPLACE FUNCTION public.claim_ai_usage(
  p_user_id uuid,
  p_feature text,
  p_monthly_limit integer
)
RETURNS TABLE (ok boolean, reason text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_is_pro boolean;
  v_expires timestamptz;
  v_count integer;
  v_daily_count integer;
  v_month_start timestamptz := date_trunc('month', timezone('utc', now()));
  v_day_start timestamptz := date_trunc('day', timezone('utc', now()));
  v_lock_key bigint;
  v_daily_safety_cap constant integer := 50;
  v_free_launch_premium_access constant boolean := true;
BEGIN
  IF p_user_id IS NULL OR p_feature IS NULL OR length(trim(p_feature)) = 0 THEN
    RETURN QUERY SELECT false, 'invalid_arguments'::text;
    RETURN;
  END IF;

  SELECT us.is_pro, us.expires_at
  INTO v_is_pro, v_expires
  FROM public.user_subscriptions us
  WHERE us.user_id = p_user_id;

  -- Same per-user-feature-month advisory lock as before. We acquire it
  -- before any count query so concurrent calls serialize on the same lock.
  v_lock_key := hashtext(
    p_user_id::text || '|' || p_feature || '|' || to_char(v_month_start, 'YYYY-MM')
  )::bigint;
  PERFORM pg_advisory_xact_lock(v_lock_key);

  -- Daily safety cap applies to every caller, including paid Pro and
  -- free-launch users.
  SELECT count(*)::integer
  INTO v_daily_count
  FROM public.usage_events ue
  WHERE ue.user_id = p_user_id
    AND ue.feature = p_feature
    AND ue.created_at >= v_day_start;

  IF v_daily_count >= v_daily_safety_cap THEN
    RETURN QUERY SELECT false, 'daily_safety_cap_reached'::text;
    RETURN;
  END IF;

  IF coalesce(v_is_pro, false)
    AND (v_expires IS NULL OR v_expires > timezone('utc', now())) THEN
    INSERT INTO public.usage_events (user_id, feature, metadata)
    VALUES (
      p_user_id,
      p_feature,
      jsonb_build_object('source', 'claim_ai_usage', 'tier', 'pro')
    );
    RETURN QUERY SELECT true, 'pro'::text;
    RETURN;
  END IF;

  IF v_free_launch_premium_access THEN
    INSERT INTO public.usage_events (user_id, feature, metadata)
    VALUES (
      p_user_id,
      p_feature,
      jsonb_build_object('source', 'claim_ai_usage', 'tier', 'free_launch')
    );
    RETURN QUERY SELECT true, 'free_launch'::text;
    RETURN;
  END IF;

  IF p_monthly_limit <= 0 THEN
    RETURN QUERY SELECT false, 'feature_requires_pro'::text;
    RETURN;
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.usage_events ue
  WHERE ue.user_id = p_user_id
    AND ue.feature = p_feature
    AND ue.created_at >= v_month_start;

  IF v_count >= p_monthly_limit THEN
    RETURN QUERY SELECT false, 'limit_exceeded'::text;
    RETURN;
  END IF;

  INSERT INTO public.usage_events (user_id, feature, metadata)
  VALUES (
    p_user_id,
    p_feature,
    jsonb_build_object('source', 'claim_ai_usage', 'tier', 'free')
  );

  RETURN QUERY SELECT true, 'claimed'::text;
  RETURN;
END
$fn$;

REVOKE ALL ON FUNCTION public.claim_ai_usage(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_ai_usage(uuid, text, integer) TO service_role;
