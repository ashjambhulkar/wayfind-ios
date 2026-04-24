-- Stage 8: filtered postgres_changes on `trips` (e.g. name/cover/date updates from collaborators).
ALTER TABLE public.trips REPLICA IDENTITY FULL;

DO $realtime$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'trips'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.trips;
  END IF;
END
$realtime$;
