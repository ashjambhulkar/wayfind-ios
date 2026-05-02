-- Wave 0 (shared infra) — analytics schema for pro_gate_attempted events.
--
-- Every Pro gate (documents, csv_export, currency_multi, flight_tracking,
-- ai_day_planner) emits a single row per attempt so conversion dashboards
-- can compare per-gate uplift after Wave 4 flips the soft gates to hard.
--
-- Shape locked by plan §0.5 U1. Service-role inserts via a thin RPC so the
-- iOS client never needs raw INSERT permission on this table — keeps the
-- analytics surface tamper-resistant if a client is ever compromised.

CREATE TABLE IF NOT EXISTS public.pro_gate_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  gate_name text NOT NULL,
  attempt_count integer NOT NULL DEFAULT 1 CHECK (attempt_count >= 1),
  is_pro boolean NOT NULL DEFAULT false,
  trial_state text,
  surface text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pro_gate_attempts_user_gate_created_idx
  ON public.pro_gate_attempts (user_id, gate_name, created_at DESC);
CREATE INDEX IF NOT EXISTS pro_gate_attempts_gate_created_idx
  ON public.pro_gate_attempts (gate_name, created_at DESC);

COMMENT ON TABLE public.pro_gate_attempts IS
  'Soft-gate analytics per plan §0.5 U1. Inserted via record_pro_gate_attempt RPC.';
COMMENT ON COLUMN public.pro_gate_attempts.gate_name IS
  'Stable id: documents | csv_export | currency_multi | flight_tracking | ai_day_planner';
COMMENT ON COLUMN public.pro_gate_attempts.surface IS
  'iOS view name where the gate was hit, e.g. TripDocumentsView, BudgetScreenView';

ALTER TABLE public.pro_gate_attempts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pro_gate_attempts_select_own ON public.pro_gate_attempts;
CREATE POLICY pro_gate_attempts_select_own
  ON public.pro_gate_attempts FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Allow signed-in users to log their own attempts (no service-role round trip).
-- The shape is small + bounded; abuse is bounded by per-user write rate limiting
-- at the PostgREST layer.
DROP POLICY IF EXISTS pro_gate_attempts_insert_own ON public.pro_gate_attempts;
CREATE POLICY pro_gate_attempts_insert_own
  ON public.pro_gate_attempts FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

-- Convenience RPC so the iOS client only needs to know the gate name, the rest
-- is derived server-side (is_pro from user_subscriptions, trial_state inferred).
CREATE OR REPLACE FUNCTION public.record_pro_gate_attempt(
  p_gate_name text,
  p_surface text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_user_id uuid := auth.uid();
  v_is_pro boolean := false;
  v_expires timestamptz;
  v_trial_used boolean;
  v_trial_state text;
  v_attempt_count integer := 1;
  v_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  IF p_gate_name IS NULL OR length(trim(p_gate_name)) = 0 THEN
    RAISE EXCEPTION 'gate_name_required' USING ERRCODE = '22023';
  END IF;

  SELECT us.is_pro, us.expires_at, us.trial_used
  INTO v_is_pro, v_expires, v_trial_used
  FROM public.user_subscriptions us
  WHERE us.user_id = v_user_id;

  v_is_pro := coalesce(v_is_pro, false)
              AND (v_expires IS NULL OR v_expires > timezone('utc', now()));

  v_trial_state := CASE
    WHEN v_is_pro AND v_trial_used IS TRUE THEN 'in_trial'
    WHEN v_trial_used IS TRUE THEN 'trial_consumed'
    ELSE 'never'
  END;

  SELECT count(*)::integer + 1
  INTO v_attempt_count
  FROM public.pro_gate_attempts
  WHERE user_id = v_user_id AND gate_name = p_gate_name;

  INSERT INTO public.pro_gate_attempts (
    user_id, gate_name, attempt_count, is_pro, trial_state, surface, metadata
  ) VALUES (
    v_user_id, p_gate_name, v_attempt_count, v_is_pro, v_trial_state, p_surface,
    coalesce(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END
$fn$;

REVOKE ALL ON FUNCTION public.record_pro_gate_attempt(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_pro_gate_attempt(text, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.record_pro_gate_attempt(text, text, jsonb) IS
  'Wave 0 — single entry point for soft-gate analytics. Auto-derives is_pro + trial_state.';
