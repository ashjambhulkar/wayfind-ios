-- Wave 4.4b — add a per-user *daily* safety cap to claim_ai_usage.
--
-- Why: the existing function only enforces a monthly cap for Free
-- users; Pro users get an unconditional `(true, 'pro')` short-circuit.
-- That's the right product story (Pro = "unlimited") but it leaves
-- two real risks uncovered:
--
--   1. A jailbroken / cracked Pro account could be hammered to drive
--      arbitrary OpenAI spend before we notice.
--   2. A bug in the iOS client (auto-retry storm, accidental loop in
--      the wizard, background regeneration tied to an observable that
--      mutates) could burn $1000+ in a single day on a single user.
--
-- A 50-call/day ceiling for *every* user (Pro and Free) absorbs both
-- failure modes. Headroom is generous: the 99th percentile in our
-- prelaunch cohort was 14 calls/day. We chose the cap so that an
-- attacker can't run more than ~$2/day of OpenAI spend per account
-- (gpt-4o-mini at our prompt size), which is small enough that we
-- have time to react when our ops dashboard pages on the daily cap
-- exceeding rate.
--
-- Implementation: extend the function so it always counts the
-- caller's `usage_events` rows for the rolling UTC day before any
-- per-tier short-circuit. Counting both Pro and Free in the same
-- table lets us answer "how much did this account use today?" from
-- a single query — no second counter table to keep in sync.
--
-- Forward-only: dropping & recreating with same signature so existing
-- GRANTs persist.

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
  -- Wave 4.4b daily safety cap. Mirrors
  -- supabase/functions/_shared/v2b_ai_constants.ts:
  -- V2B_DAILY_SAFETY_CAP_AI_DAY_PLANNER. We intentionally hard-code
  -- the same number in both places because the constant is enforced
  -- at two layers (server-side function for security, Edge Function
  -- for the analytics shape) — drift here is the kind of thing
  -- ops would notice in the limit_exceeded ratio dashboard.
  v_daily_safety_cap constant integer := 50;
BEGIN
  IF p_user_id IS NULL OR p_feature IS NULL OR length(trim(p_feature)) = 0 THEN
    RETURN QUERY SELECT false, 'invalid_arguments'::text;
    RETURN;
  END IF;

  SELECT us.is_pro, us.expires_at
  INTO v_is_pro, v_expires
  FROM public.user_subscriptions us
  WHERE us.user_id = p_user_id;

  -- Same per-user-feature-month advisory lock as before. We acquire
  -- it before *any* count query so concurrent calls serialise on the
  -- same lock and can't both squeeze through the same `count < cap`
  -- check.
  v_lock_key := hashtext(
    p_user_id::text || '|' || p_feature || '|' || to_char(v_month_start, 'YYYY-MM')
  )::bigint;
  PERFORM pg_advisory_xact_lock(v_lock_key);

  -- Daily safety cap applies to **every** caller — including Pro.
  SELECT count(*)::integer
  INTO v_daily_count
  FROM public.usage_events ue
  WHERE ue.user_id = p_user_id
    AND ue.feature = p_feature
    AND ue.created_at >= v_day_start;

  IF v_daily_count >= v_daily_safety_cap THEN
    -- A distinct reason so the Edge Function / client can render a
    -- different message ("Try again tomorrow — daily safety cap
    -- reached") instead of the standard upsell paywall, and so ops
    -- can alert on a non-zero rate (which would indicate either an
    -- abuse pattern or a client bug).
    RETURN QUERY SELECT false, 'daily_safety_cap_reached'::text;
    RETURN;
  END IF;

  IF coalesce(v_is_pro, false)
    AND (v_expires IS NULL OR v_expires > timezone('utc', now())) THEN
    -- Pro: still record the event so the daily safety cap counts it
    -- next time and so dashboards can answer "how many AI plans did
    -- Pro users generate today?" without a second source of truth.
    INSERT INTO public.usage_events (user_id, feature, metadata)
    VALUES (
      p_user_id,
      p_feature,
      jsonb_build_object('source', 'claim_ai_usage', 'tier', 'pro')
    );
    RETURN QUERY SELECT true, 'pro'::text;
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

-- Re-grant — CREATE OR REPLACE preserves grants for existing functions
-- but we're paranoid; service_role is the only legitimate caller.
REVOKE ALL ON FUNCTION public.claim_ai_usage(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_ai_usage(uuid, text, integer) TO service_role;
