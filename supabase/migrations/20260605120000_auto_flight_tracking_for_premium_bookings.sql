-- Auto-enable flight tracking for eligible users.
--
-- A flight booking becomes trackable once it has:
--   carrier IATA, flight number, scheduled departure, and scheduled arrival.
-- The polling worker owns live provider data; this trigger only maintains the
-- tracking subscription row that the worker reads.

BEGIN;

CREATE OR REPLACE FUNCTION public.has_effective_premium_access(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_pro boolean;
  v_expires timestamptz;
  -- Mirrors AppConfig.grantFreeLaunchPremiumAccess. Flip false when launch
  -- access ends so only active paid subscriptions auto-track flights.
  v_free_launch_premium_access constant boolean := true;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT us.is_pro, us.expires_at
  INTO v_is_pro, v_expires
  FROM public.user_subscriptions us
  WHERE us.user_id = p_user_id;

  IF coalesce(v_is_pro, false)
     AND (v_expires IS NULL OR v_expires > now()) THEN
    RETURN true;
  END IF;

  RETURN v_free_launch_premium_access;
END;
$$;

REVOKE ALL ON FUNCTION public.has_effective_premium_access(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_effective_premium_access(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.normalized_flight_number(
  p_flight_number text,
  p_carrier_iata text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
    regexp_replace(
      CASE
        WHEN p_carrier_iata IS NOT NULL
         AND upper(regexp_replace(coalesce(p_flight_number, ''), '\s+', '', 'g')) LIKE upper(p_carrier_iata) || '%'
          THEN substr(
            upper(regexp_replace(coalesce(p_flight_number, ''), '\s+', '', 'g')),
            length(upper(p_carrier_iata)) + 1
          )
        ELSE upper(regexp_replace(coalesce(p_flight_number, ''), '\s+', '', 'g'))
      END,
      '[^0-9A-Z]',
      '',
      'g'
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.extract_flight_carrier_iata(p_booking public.trip_bookings)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_candidate text;
  v_flight_number text;
BEGIN
  v_candidate := upper(nullif(trim(coalesce(
    p_booking.details_json->>'carrier_iata',
    p_booking.details_json->>'carrierIATA',
    p_booking.details_json->>'iata',
    p_booking.details_json->>'airline_iata'
  )), ''));

  IF v_candidate ~ '^[A-Z0-9]{2,3}$' THEN
    RETURN v_candidate;
  END IF;

  v_flight_number := upper(regexp_replace(coalesce(
    p_booking.details_json->>'flight_number',
    p_booking.details_json->>'flightNumber',
    p_booking.title
  ), '\s+', '', 'g'));

  v_candidate := substring(v_flight_number from '^[A-Z]{2,3}');
  IF v_candidate ~ '^[A-Z]{2,3}$' THEN
    RETURN v_candidate;
  END IF;

  RETURN NULL;
END;
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

  IF NEW.kind <> 'flight' THEN
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

  IF v_arrival IS NULL AND v_departure IS NOT NULL THEN
    v_arrival := v_departure + interval '2 hours';
  END IF;

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
    upper(nullif(trim(NEW.start_location), '')),
    upper(nullif(trim(NEW.end_location), '')),
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

DROP TRIGGER IF EXISTS trip_bookings_auto_flight_status ON public.trip_bookings;
CREATE TRIGGER trip_bookings_auto_flight_status
  AFTER INSERT OR UPDATE OF kind, user_id, trip_id, title, starts_at, ends_at, start_location, end_location, details_json
  ON public.trip_bookings
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_auto_upsert_flight_status();

-- Backfill existing eligible flight bookings.
WITH normalized AS (
  SELECT
    b.id AS booking_id,
    b.trip_id,
    b.user_id,
    public.extract_flight_carrier_iata(b) AS carrier_iata,
    public.normalized_flight_number(
      coalesce(
        b.details_json->>'flight_number',
        b.details_json->>'flightNumber',
        b.title
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
