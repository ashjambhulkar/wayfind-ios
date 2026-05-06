-- Airport timezone cache.
--
-- Populated by `lookup-flight` (AeroDataBox returns IANA tz per airport)
-- and consumed by `flight_enrichment.ts` shared helper to avoid paying
-- for AeroDataBox calls when the TZ for a given IATA is already known.
--
-- Write path: service-role only (Edge Functions).
-- Read path:  service-role (backfill, enrichment helpers).

CREATE TABLE IF NOT EXISTS public.airport_timezones (
  iata          text        PRIMARY KEY,
  iana          text        NOT NULL,
  -- Last time we confirmed this TZ from a provider response.
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.airport_timezones IS 'IANA timezone per IATA airport code, populated from AeroDataBox responses.';
COMMENT ON COLUMN public.airport_timezones.iata IS 'Three-letter IATA airport code (uppercase).';
COMMENT ON COLUMN public.airport_timezones.iana IS 'IANA timezone identifier e.g. America/New_York.';

-- No public read; only service-role reads and writes.
ALTER TABLE public.airport_timezones ENABLE ROW LEVEL SECURITY;

-- Upsert helper used by lookup-flight and poll-flight-status.
CREATE OR REPLACE FUNCTION public.upsert_airport_timezone(
  p_iata text,
  p_iana text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.airport_timezones (iata, iana, last_seen_at)
  VALUES (upper(p_iata), p_iana, now())
  ON CONFLICT (iata) DO UPDATE
    SET iana         = EXCLUDED.iana,
        last_seen_at = now()
  WHERE public.airport_timezones.iana IS DISTINCT FROM EXCLUDED.iana
     OR public.airport_timezones.last_seen_at < now() - INTERVAL '30 days';
END;
$$;
