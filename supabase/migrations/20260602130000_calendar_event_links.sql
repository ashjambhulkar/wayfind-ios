-- Wave 0 (shared infra) — calendar_event_links table.
--
-- Plan §0.5 E9 + §3.1: `@AppStorage`-based EKEvent.eventIdentifier mapping
-- breaks on reinstall, restore-from-backup, and second device. Server-side
-- mapping keyed by (user_id, activity_id, device_id) so each device
-- maintains its own EKEvent identifier but state survives reinstall on the
-- same device (device_id is stable per-install via UIDevice.identifierForVendor).
--
-- Bookings are also synced — booking_id is mutually exclusive with
-- activity_id (exactly one set per row). This avoids two parallel tables.

CREATE TABLE IF NOT EXISTS public.calendar_event_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  device_id text NOT NULL,
  activity_id uuid REFERENCES public.trip_activities (id) ON DELETE CASCADE,
  booking_id uuid,
  external_event_id text NOT NULL,
  external_calendar_id text,
  source text NOT NULL DEFAULT 'eventkit',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT calendar_event_links_one_target CHECK (
    (activity_id IS NOT NULL AND booking_id IS NULL)
    OR (activity_id IS NULL AND booking_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS calendar_event_links_activity_uniq
  ON public.calendar_event_links (user_id, device_id, activity_id)
  WHERE activity_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS calendar_event_links_booking_uniq
  ON public.calendar_event_links (user_id, device_id, booking_id)
  WHERE booking_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS calendar_event_links_trip_idx
  ON public.calendar_event_links (trip_id);

COMMENT ON TABLE public.calendar_event_links IS
  'Wave 0 — EventKit identifier mapping per (user, device, target). Lets calendar sync survive reinstall.';
COMMENT ON COLUMN public.calendar_event_links.device_id IS
  'Stable per-install id from UIDevice.identifierForVendor.';
COMMENT ON COLUMN public.calendar_event_links.external_event_id IS
  'EKEvent.eventIdentifier (or equivalent for non-EventKit sources).';

ALTER TABLE public.calendar_event_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS calendar_event_links_select_own ON public.calendar_event_links;
CREATE POLICY calendar_event_links_select_own
  ON public.calendar_event_links FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS calendar_event_links_insert_own ON public.calendar_event_links;
CREATE POLICY calendar_event_links_insert_own
  ON public.calendar_event_links FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND public.can_view_trip(trip_id)
  );

DROP POLICY IF EXISTS calendar_event_links_update_own ON public.calendar_event_links;
CREATE POLICY calendar_event_links_update_own
  ON public.calendar_event_links FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS calendar_event_links_delete_own ON public.calendar_event_links;
CREATE POLICY calendar_event_links_delete_own
  ON public.calendar_event_links FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.calendar_event_links_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS calendar_event_links_set_updated_at ON public.calendar_event_links;
CREATE TRIGGER calendar_event_links_set_updated_at
  BEFORE UPDATE ON public.calendar_event_links
  FOR EACH ROW
  EXECUTE FUNCTION public.calendar_event_links_bump_updated_at();
