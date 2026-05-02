-- V1 booking kinds (app): flight, lodging, restaurant, car, activity, transport.
-- Map legacy `kind` text values before relying on the six-type set in the client.
-- Adjust or skip if your table uses a Postgres enum (add new values first, then migrate).

DO $body$
BEGIN
  IF to_regclass('public.trip_bookings') IS NULL THEN
    RETURN;
  END IF;
  UPDATE public.trip_bookings
  SET kind = 'transport'
  WHERE kind IN ('train', 'bus', 'ferry', 'cruise');
  UPDATE public.trip_bookings
  SET kind = 'activity'
  WHERE kind IN ('concert', 'theater', 'tour');
END
$body$;
