-- Expose trip_bookings to Supabase Realtime so the app can refresh booking counts on trip detail
-- when rows are inserted/updated/deleted (e.g. email forwarding pipeline).
-- Filtered postgres_changes subscriptions require REPLICA IDENTITY FULL on the table.

DO $migration$
BEGIN
  IF to_regclass('public.trip_bookings') IS NULL THEN
    RETURN;
  END IF;
  ALTER TABLE public.trip_bookings REPLICA IDENTITY FULL;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'trip_bookings'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.trip_bookings;
  END IF;
END
$migration$;
