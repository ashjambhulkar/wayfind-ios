-- Durable audit trail for manual flight lookup attempts. Edge Function console
-- logs are not always surfaced by the management log feed, so this table lets
-- support/debugging answer exactly why a lookup fell back to manual entry.

BEGIN;

CREATE TABLE IF NOT EXISTS public.flight_lookup_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  carrier_iata text,
  flight_number text,
  departure_date date,
  status text NOT NULL CHECK (status IN ('found', 'not_found', 'error')),
  reason text,
  http_status integer,
  origin_airport_iata text,
  destination_airport_iata text,
  provider text DEFAULT 'aerodatabox',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS flight_lookup_attempts_created_at_idx
  ON public.flight_lookup_attempts (created_at DESC);

CREATE INDEX IF NOT EXISTS flight_lookup_attempts_flight_idx
  ON public.flight_lookup_attempts (carrier_iata, flight_number, departure_date);

ALTER TABLE public.flight_lookup_attempts ENABLE ROW LEVEL SECURITY;

COMMIT;
