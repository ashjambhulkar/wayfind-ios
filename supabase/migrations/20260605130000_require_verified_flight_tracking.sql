-- Only verified or trusted structured flight bookings should auto-create
-- flight tracking rows. Manual fallback bookings remain visible bookings but
-- intentionally do not poll AeroDataBox.

BEGIN;

CREATE OR REPLACE FUNCTION public.flight_booking_is_trackable(p_booking public.trip_bookings)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_booking.kind = 'flight'
     AND (
       coalesce((p_booking.details_json->>'lookup_verified')::boolean, false)
       OR lower(coalesce(p_booking.source, '')) IN ('email_import', 'forwarded_email', 'trusted_import')
     );
$$;

CREATE OR REPLACE FUNCTION public.tg_auto_upsert_flight_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_carrier_iata text;
  v_flight_number text;
  v_departure timestamptz;
  v_arrival timestamptz;
  v_now timestamptz := now();
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF NOT public.flight_booking_is_trackable(NEW) THEN
    DELETE FROM public.flight_statuses WHERE booking_id = NEW.id;
    RETURN NEW;
  END IF;

  IF NOT public.has_effective_premium_access(NEW.user_id) THEN
    DELETE FROM public.flight_statuses WHERE booking_id = NEW.id;
    RETURN NEW;
  END IF;

  v_carrier_iata := public.extract_flight_carrier_iata(NEW);
  v_flight_number := public.normalized_flight_number(
    coalesce(
      NEW.details_json->>'flight_number',
      NEW.details_json->>'flightNumber',
      NEW.title
    ),
    v_carrier_iata
  );
  v_departure := NEW.starts_at;
  v_arrival := NEW.ends_at;

  IF v_carrier_iata IS NULL
     OR v_flight_number IS NULL
     OR length(v_flight_number) NOT BETWEEN 1 AND 5
     OR v_departure IS NULL
     OR v_arrival IS NULL THEN
    DELETE FROM public.flight_statuses WHERE booking_id = NEW.id;
    RETURN NEW;
  END IF;

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
  VALUES (
    NEW.id,
    NEW.trip_id,
    NEW.user_id,
    v_carrier_iata,
    v_flight_number,
    v_departure,
    v_arrival,
    upper(nullif(trim(coalesce(NEW.details_json->>'origin_airport_iata', NEW.start_location)), '')),
    upper(nullif(trim(coalesce(NEW.details_json->>'destination_airport_iata', NEW.end_location)), '')),
    nullif(trim(NEW.details_json->>'gate'), ''),
    nullif(trim(NEW.details_json->>'terminal'), ''),
    v_now,
    v_now
  )
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
      next_poll_at = LEAST(coalesce(flight_statuses.next_poll_at, v_now), v_now),
      updated_at = v_now;

  RETURN NEW;
END;
$$;

DELETE FROM public.flight_statuses fs
USING public.trip_bookings b
WHERE b.id = fs.booking_id
  AND NOT public.flight_booking_is_trackable(b);

COMMIT;
