-- Backfill valid structured flight bookings after tightening carrier identity.

BEGIN;

WITH normalized AS (
  SELECT
    b.id AS booking_id,
    b.trip_id,
    b.user_id,
    public.extract_flight_carrier_iata(b) AS carrier_iata,
    public.normalized_flight_number(
      coalesce(
        b.details_json->>'flight_number',
        b.details_json->>'flightNumber'
      ),
      public.extract_flight_carrier_iata(b)
    ) AS flight_number,
    b.starts_at AS scheduled_departure_utc,
    coalesce(b.ends_at, b.starts_at + interval '2 hours') AS scheduled_arrival_utc,
    upper(nullif(trim(b.start_location), '')) AS origin_airport_iata,
    upper(nullif(trim(b.end_location), '')) AS destination_airport_iata,
    nullif(trim(b.details_json->>'gate'), '') AS gate_origin,
    nullif(trim(b.details_json->>'terminal'), '') AS terminal_origin
  FROM public.trip_bookings b
  WHERE b.kind = 'flight'
    AND public.has_effective_premium_access(b.user_id)
)
INSERT INTO public.flight_statuses (
  booking_id,
  trip_id,
  user_id,
  carrier_iata,
  flight_number,
  scheduled_departure_utc,
  scheduled_arrival_utc,
  origin_airport_iata,
  destination_airport_iata,
  gate_origin,
  terminal_origin,
  next_poll_at,
  polled_at
)
SELECT
  booking_id,
  trip_id,
  user_id,
  carrier_iata,
  flight_number,
  scheduled_departure_utc,
  scheduled_arrival_utc,
  origin_airport_iata,
  destination_airport_iata,
  gate_origin,
  terminal_origin,
  now(),
  now()
FROM normalized
WHERE carrier_iata IS NOT NULL
  AND flight_number IS NOT NULL
  AND length(flight_number) BETWEEN 1 AND 5
  AND scheduled_departure_utc IS NOT NULL
  AND scheduled_arrival_utc IS NOT NULL
ON CONFLICT (booking_id) DO UPDATE
SET trip_id = EXCLUDED.trip_id,
    user_id = EXCLUDED.user_id,
    carrier_iata = EXCLUDED.carrier_iata,
    flight_number = EXCLUDED.flight_number,
    scheduled_departure_utc = EXCLUDED.scheduled_departure_utc,
    scheduled_arrival_utc = EXCLUDED.scheduled_arrival_utc,
    origin_airport_iata = EXCLUDED.origin_airport_iata,
    destination_airport_iata = EXCLUDED.destination_airport_iata,
    gate_origin = EXCLUDED.gate_origin,
    terminal_origin = EXCLUDED.terminal_origin,
    next_poll_at = now(),
    updated_at = now();

COMMIT;
