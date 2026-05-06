-- Expand the source check constraint to include values produced by the
-- email-forwarding pipeline ('forwarded_email') and future trusted sources.
-- Previously only 'manual', 'upload', 'email' were allowed, which blocked
-- flight tracking since flight_booking_is_trackable() whitelists 'forwarded_email'.

BEGIN;

ALTER TABLE trip_bookings DROP CONSTRAINT trip_bookings_source_check;

ALTER TABLE trip_bookings ADD CONSTRAINT trip_bookings_source_check
  CHECK (source = ANY (ARRAY[
    'manual'::text,
    'upload'::text,
    'email'::text,
    'forwarded_email'::text,
    'email_import'::text,
    'trusted_import'::text
  ]));

COMMIT;
