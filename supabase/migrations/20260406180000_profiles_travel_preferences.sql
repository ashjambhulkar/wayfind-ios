-- Lightweight travel context on profile (display + future formatting).
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS preferred_airport text,
  ADD COLUMN IF NOT EXISTS preferred_currency text;

COMMENT ON COLUMN public.profiles.preferred_airport IS 'Home or preferred airport (IATA or short label).';
COMMENT ON COLUMN public.profiles.preferred_currency IS 'Preferred ISO 4217 currency code (e.g. USD).';
