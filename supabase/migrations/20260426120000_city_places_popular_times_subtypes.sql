-- Popular times (e.g. Google-style weekly histograms) and finer-grained place subtypes for city_places.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS popular_times jsonb,
  ADD COLUMN IF NOT EXISTS subtypes text[];

COMMENT ON COLUMN public.city_places.popular_times IS
  'Optional JSON payload for busy-hour / popular times data when enriched from a provider.';

COMMENT ON COLUMN public.city_places.subtypes IS
  'Optional finer-grained type tags (e.g. additional Google types) alongside `types`.';
