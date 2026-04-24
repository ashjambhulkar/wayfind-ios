-- Scoring / itinerary rules per city profile, or global (city_profile_id NULL). Shadow vs active via is_active.

CREATE TABLE public.city_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid REFERENCES public.city_profiles (id) ON DELETE CASCADE,
  -- NULL city_profile_id = global rule (applies to all cities)

  rule_type text NOT NULL,

  rule_data jsonb NOT NULL,

  -- Safety controls
  weight numeric NOT NULL DEFAULT 0.5,
  is_active boolean NOT NULL DEFAULT false,
  applies_when jsonb,

  -- Audit
  version integer NOT NULL DEFAULT 1,
  created_by text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT city_rules_weight_range CHECK (weight >= 0::numeric AND weight <= 1::numeric)
);

CREATE INDEX idx_city_rules_city ON public.city_rules (city_profile_id);
CREATE INDEX idx_city_rules_profile_type ON public.city_rules (city_profile_id, rule_type);
CREATE INDEX idx_city_rules_active ON public.city_rules (is_active);

COMMENT ON TABLE public.city_rules IS
  'Itinerary quality rules: per-city or global (NULL city_profile_id). is_active=false runs in shadow mode (log only).';

COMMENT ON COLUMN public.city_rules.city_profile_id IS
  'NULL = global rule applying to all cities; otherwise scoped to this city_profiles row.';

COMMENT ON COLUMN public.city_rules.rule_type IS
  'e.g. exhaustion_conflict | highlights | category_cap | neighborhood_cluster | best_time | season';

COMMENT ON COLUMN public.city_rules.rule_data IS
  'Structured payload for this rule_type (shape defined by the planner).';

COMMENT ON COLUMN public.city_rules.weight IS
  '0.0–1.0 relative influence on score when is_active is true.';

COMMENT ON COLUMN public.city_rules.is_active IS
  'false = shadow mode (evaluate/log only, no score impact).';

COMMENT ON COLUMN public.city_rules.applies_when IS
  'Optional contextual gate; null = always. e.g. {"pace":["relaxed","moderate"],"min_trip_days":2,"trip_depth":["highlights"]}';

COMMENT ON COLUMN public.city_rules.created_by IS
  'e.g. llm_draft | human | data_derived';

DROP TRIGGER IF EXISTS city_rules_set_updated_at ON public.city_rules;
CREATE TRIGGER city_rules_set_updated_at
  BEFORE UPDATE ON public.city_rules
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

ALTER TABLE public.city_rules ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.city_rules FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.city_rules TO service_role;
