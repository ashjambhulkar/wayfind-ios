-- Append-only-ish logs for AI itinerary generation runs: inputs, LLM artifacts, scores, retries, timing.

CREATE TABLE public.itinerary_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid REFERENCES public.city_profiles (id) ON DELETE SET NULL,

  -- User inputs
  user_pace text,
  user_trip_depth text,
  user_travel_style text,
  user_interests text[],
  day_date date,

  -- LLM I/O
  wishlist_prompt_hash text,
  wishlist_response jsonb,

  -- Final output
  final_itinerary jsonb,
  stop_count integer,
  total_route_km numeric,

  -- Quality scores (Layer 1 + 2)
  algo_score numeric,
  temporal_feasibility numeric,
  spatial_coherence numeric,
  variety_and_energy numeric,
  city_rules_compliance numeric,
  practical_completeness numeric,

  -- Shadow rule results (rules with is_active=false)
  city_rules_shadow jsonb,

  -- Quality scores (Layer 3, nullable)
  llm_eval_score jsonb,
  llm_eval_suggestion text,

  -- Retry tracking
  was_retried boolean NOT NULL DEFAULT false,
  retry_reason text,
  retry_count integer NOT NULL DEFAULT 0,

  -- Performance
  generation_time_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_itinerary_logs_city ON public.itinerary_logs (city_profile_id);
CREATE INDEX idx_itinerary_logs_score ON public.itinerary_logs (algo_score);

COMMENT ON TABLE public.itinerary_logs IS
  'Per-generation audit trail for itinerary AI: preferences, wishlist I/O, final plan, quality scores, shadow rules, retries.';

COMMENT ON COLUMN public.itinerary_logs.city_rules_shadow IS
  'e.g. [{"rule_id":"abc","would_penalize":true,"reason":"...","penalty":-0.08}]';

ALTER TABLE public.itinerary_logs ENABLE ROW LEVEL SECURITY;

-- No policies for anon/authenticated — clients must not read/write; Edge uses service_role (bypasses RLS).
REVOKE ALL ON TABLE public.itinerary_logs FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.itinerary_logs TO service_role;
