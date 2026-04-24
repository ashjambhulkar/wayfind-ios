-- App V1 uses kind = 'transport' (train/bus/ferry/cruise were merged in client + 20260403180000 data migration).
-- Older Postgres enums for trip_bookings.kind may not list 'transport', causing inserts from Add Booking to fail.

DO $$
DECLARE
  enum_oid oid;
  enum_name text;
BEGIN
  SELECT t.oid, t.typname::text
  INTO enum_oid, enum_name
  FROM pg_type t
  JOIN pg_attribute a ON a.atttypid = t.oid
  JOIN pg_class c ON a.attrelid = c.oid
  WHERE c.relname = 'trip_bookings'
    AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    AND a.attname = 'kind'
    AND NOT a.attisdropped
    AND t.typtype = 'e';

  IF enum_name IS NULL THEN
    RAISE NOTICE 'trip_bookings.kind is not an enum; no ALTER TYPE needed';
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_enum e WHERE e.enumlabel = 'transport' AND e.enumtypid = enum_oid
  ) THEN
    RETURN;
  END IF;

  EXECUTE format('ALTER TYPE %I ADD VALUE ''transport''', enum_name);
END $$;
