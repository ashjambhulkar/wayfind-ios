-- Phase H.2 (and G.2 foundation) — generic feature_flags table.
--
-- One row per flag, value is JSONB so we can hold booleans, ints, strings,
-- or richer objects (e.g. per-country rollout maps) under the same schema.
-- Read-only from clients; writable from service_role (Edge Functions /
-- admin tooling).
--
-- Cache: callers should hold values for ~1h before re-reading. Long enough
-- to avoid hot-spotting the table during a deploy, short enough that a
-- kill-switch flag flip propagates within an hour.

CREATE TABLE IF NOT EXISTS public.feature_flags (
  flag text PRIMARY KEY,
  value jsonb NOT NULL,
  description text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL
);

CREATE OR REPLACE FUNCTION public.set_feature_flags_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_feature_flags_updated_at ON public.feature_flags;
CREATE TRIGGER trg_feature_flags_updated_at
BEFORE UPDATE ON public.feature_flags
FOR EACH ROW
EXECUTE FUNCTION public.set_feature_flags_updated_at();

ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;

CREATE POLICY feature_flags_public_read ON public.feature_flags
  FOR SELECT USING (true);

GRANT SELECT ON public.feature_flags TO anon, authenticated;

COMMENT ON TABLE public.feature_flags IS
  'Server-side feature flag registry. Reads cached ~1h client-side. Writes '
  'are restricted to service_role / admin tooling.';

-- Seed rows for Phase H.
--
-- TTLs are in *days* (180 = 6 months). Rationale:
--   • details TTL: 180d strikes a balance between freshness and cost. Most
--     restaurants update hours every few months, but only ~5% of city_places
--     entries change anything material in any given month.
--   • images TTL: same 180d for parity. Photos go stale slower (a building's
--     facade doesn't change), but we don't want a refresh storm where data
--     and images diverge wildly in age.
INSERT INTO public.feature_flags (flag, value, description) VALUES
  ('city_places_data_ttl_days',
   '180'::jsonb,
   'How many days a city_places row''s details (rating, hours, AI summaries) can sit before refresh_city_place_if_stale enqueues a details job.'),
  ('city_places_image_ttl_days',
   '180'::jsonb,
   'How many days a city_places row''s images can sit before refresh_city_place_if_stale enqueues an images job. Independent from data TTL because photos are more expensive to refresh.')
ON CONFLICT (flag) DO NOTHING;

-- Helper RPC for clients/Edge Functions to read a flag with a default.
CREATE OR REPLACE FUNCTION public.feature_flag_int(
  p_flag text,
  p_default integer
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT (value)::text::integer FROM public.feature_flags WHERE flag = p_flag),
    p_default
  );
$$;

GRANT EXECUTE ON FUNCTION public.feature_flag_int(text, integer)
  TO anon, authenticated, service_role;
