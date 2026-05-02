-- V2b Stage 1: usage tracking, subscription row, atomic AI quota claim.
-- Enforced from Edge Functions (service role) via claim_ai_usage.

-- ─── usage_events ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.usage_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  feature text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_usage_events_user_feature_created_at
  ON public.usage_events (user_id, feature, created_at DESC);

ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "usage_events_select_own" ON public.usage_events;
CREATE POLICY "usage_events_select_own"
  ON public.usage_events FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "usage_events_insert_own" ON public.usage_events;
CREATE POLICY "usage_events_insert_own"
  ON public.usage_events FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- ─── user_subscriptions (written by validate-subscription Edge Function) ──
CREATE TABLE IF NOT EXISTS public.user_subscriptions (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  is_pro boolean NOT NULL DEFAULT false,
  plan_id text,
  platform text,
  original_transaction_id text,
  expires_at timestamptz,
  trial_used boolean NOT NULL DEFAULT false,
  is_in_billing_retry boolean NOT NULL DEFAULT false,
  validated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_subscriptions_expires_at
  ON public.user_subscriptions (expires_at)
  WHERE is_pro = true;

ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_subscriptions_select_own" ON public.user_subscriptions;
CREATE POLICY "user_subscriptions_select_own"
  ON public.user_subscriptions FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP TRIGGER IF EXISTS user_subscriptions_set_updated_at ON public.user_subscriptions;
CREATE OR REPLACE FUNCTION public.user_subscriptions_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$fn$;

CREATE TRIGGER user_subscriptions_set_updated_at
  BEFORE UPDATE ON public.user_subscriptions
  FOR EACH ROW
  EXECUTE PROCEDURE public.user_subscriptions_bump_updated_at();

-- ─── claim_ai_usage: advisory lock + count + optional insert (atomic) ─────
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
  v_month_start timestamptz := date_trunc('month', timezone('utc', now()));
  v_lock_key bigint;
BEGIN
  IF p_user_id IS NULL OR p_feature IS NULL OR length(trim(p_feature)) = 0 THEN
    RETURN QUERY SELECT false, 'invalid_arguments'::text;
    RETURN;
  END IF;

  SELECT us.is_pro, us.expires_at
  INTO v_is_pro, v_expires
  FROM public.user_subscriptions us
  WHERE us.user_id = p_user_id;

  IF coalesce(v_is_pro, false)
    AND (v_expires IS NULL OR v_expires > timezone('utc', now())) THEN
    RETURN QUERY SELECT true, 'pro'::text;
    RETURN;
  END IF;

  IF p_monthly_limit <= 0 THEN
    RETURN QUERY SELECT false, 'feature_requires_pro'::text;
    RETURN;
  END IF;

  -- Single-transaction lock per user+feature+calendar month (hashtext = int4 → bigint).
  v_lock_key := hashtext(
    p_user_id::text || '|' || p_feature || '|' || to_char(v_month_start, 'YYYY-MM')
  )::bigint;
  PERFORM pg_advisory_xact_lock(v_lock_key);

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
    jsonb_build_object('source', 'claim_ai_usage')
  );

  RETURN QUERY SELECT true, 'claimed'::text;
  RETURN;
END
$fn$;

REVOKE ALL ON FUNCTION public.claim_ai_usage(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_ai_usage(uuid, text, integer) TO service_role;
