-- Wave 3.1 — flight_statuses table for the Pro flight-tracking feature.
--
-- One row per *tracked* flight booking. Lives separately from
-- `trip_bookings` so:
--   • Polling can update high-frequency fields without churning the user-
--     facing booking row (and its triggers).
--   • Realtime subscriptions can be filtered by trip_id without leaking
--     other booking edits.
--   • RLS for status data can stay minimal (read-only for trip
--     collaborators; only the Edge Function service role writes).
--
-- The polling cadence (60m → 15m → 5m → 10m post-landing) is driven by
-- `next_poll_at`. Wave 3.2 implements the `poll-flight-status` Edge
-- Function that selects rows where `next_poll_at <= now()`, fetches a
-- fresh snapshot from AeroDataBox, and updates here. The kill-switch
-- (`flight_tracking_enabled` feature_flag) is checked before any
-- outbound call so we can shut the cost off in seconds if a provider
-- prices spike.
--
-- ActivityKit / Live Activity payload schema is documented separately
-- in `docs/flight-tracking-push-payload.md` so the V5 client work has a
-- frozen contract to build against.

BEGIN;

CREATE TABLE IF NOT EXISTS public.flight_statuses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- One status row per booking. Cascade so deleting the booking nukes
  -- its status (no orphaned polling work).
  booking_id uuid NOT NULL UNIQUE
    REFERENCES public.trip_bookings (id) ON DELETE CASCADE,
  -- Denormalised for RLS performance and partition-safe Realtime
  -- subscriptions; both kept in sync with their authoritative source.
  trip_id uuid NOT NULL
    REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL
    REFERENCES auth.users (id) ON DELETE CASCADE,

  -- Canonical flight identity. AeroDataBox indexes by (carrier_iata,
  -- flight_number, scheduled_departure_date_utc). We store the full
  -- timestamp so we always pick the right segment when an airline
  -- runs the same flight number every day.
  carrier_iata text NOT NULL CHECK (length(carrier_iata) BETWEEN 2 AND 3),
  flight_number text NOT NULL CHECK (length(flight_number) BETWEEN 1 AND 5),
  scheduled_departure_utc timestamptz NOT NULL,
  scheduled_arrival_utc timestamptz NOT NULL,

  -- Live state. NULL until the provider returns it. `status` is the
  -- compact UX label; the badge in §3.3 maps it to colour.
  status text NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled','active','landed','cancelled','diverted','unknown')),
  estimated_departure_utc timestamptz,
  estimated_arrival_utc timestamptz,
  actual_departure_utc timestamptz,
  actual_arrival_utc timestamptz,

  -- Operational metadata pulled from the provider response.
  origin_airport_iata text,
  destination_airport_iata text,
  gate_origin text,
  gate_destination text,
  terminal_origin text,
  terminal_destination text,
  baggage_claim text,
  delay_minutes integer,

  -- Provider bookkeeping. We keep the raw payload (truncated client
  -- side) for a few days so the support ops can reproduce a "why did
  -- the badge go red" complaint without re-querying.
  provider text NOT NULL DEFAULT 'aerodatabox',
  provider_payload jsonb,

  -- Polling state machine driven by `poll-flight-status`.
  polled_at timestamptz NOT NULL DEFAULT now(),
  next_poll_at timestamptz,
  -- Updated only when something user-visible (status, ETA, gate)
  -- changed since the last poll. Drives push delivery — we don't FCM
  -- for noisy provider payload diffs.
  last_change_at timestamptz,
  last_change_summary text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Index supports the cron worker's hot path:
--   SELECT id FROM flight_statuses
--   WHERE next_poll_at IS NOT NULL AND next_poll_at <= now()
--   ORDER BY next_poll_at ASC LIMIT N;
CREATE INDEX IF NOT EXISTS idx_flight_statuses_next_poll
  ON public.flight_statuses (next_poll_at)
  WHERE next_poll_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_flight_statuses_trip
  ON public.flight_statuses (trip_id);

CREATE INDEX IF NOT EXISTS idx_flight_statuses_user
  ON public.flight_statuses (user_id);

-- Standard updated_at maintenance (matches the existing trigger pattern).
DROP TRIGGER IF EXISTS trg_flight_statuses_updated_at ON public.flight_statuses;
CREATE TRIGGER trg_flight_statuses_updated_at
  BEFORE UPDATE ON public.flight_statuses
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- RLS. Owners + accepted collaborators can read; only the service role
-- (Edge Function) writes. iOS clients call an RPC to "start tracking"
-- which inserts the stub server-side; they never INSERT here directly.
ALTER TABLE public.flight_statuses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "flight_statuses_select_for_trip_members"
  ON public.flight_statuses;
CREATE POLICY "flight_statuses_select_for_trip_members"
  ON public.flight_statuses
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR trip_id IN (
      SELECT trip_id FROM public.trip_collaborators
       WHERE user_id = auth.uid() AND accepted_at IS NOT NULL
    )
    OR trip_id IN (
      SELECT id FROM public.trips WHERE user_id = auth.uid()
    )
  );

-- Owners may DELETE their own tracking subscription (stop tracking).
DROP POLICY IF EXISTS "flight_statuses_delete_owner"
  ON public.flight_statuses;
CREATE POLICY "flight_statuses_delete_owner"
  ON public.flight_statuses
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- Realtime publication so the iOS client receives push-style updates
-- when the Edge Function writes a status change. We rely on
-- supabase_realtime subscriptions filtered by trip_id (clients pass
-- `trip_id=eq.<uuid>` when subscribing) so users never see other
-- trips' rows over the wire.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    BEGIN
      EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.flight_statuses';
    EXCEPTION WHEN duplicate_object THEN
      -- already added; safe to ignore
      NULL;
    END;
  END IF;
END $$;

-- Seed the kill switches. `flight_tracking_enabled` lets us hard-stop
-- the polling worker in seconds if AeroDataBox prices unexpectedly.
-- `flight_tracking_daily_call_budget` caps the worker; once exceeded,
-- the function early-exits without making outbound calls.
INSERT INTO public.feature_flags (flag, value, description) VALUES
  ('flight_tracking_enabled',
   'true'::jsonb,
   'Kill switch for the poll-flight-status Edge Function. Set to false to immediately halt all AeroDataBox polling without redeploying.'),
  ('flight_tracking_daily_call_budget',
   '6000'::jsonb,
   'Max AeroDataBox calls per UTC day across all users. Sized to the $30/mo Ultra tier (200 calls/day default + headroom). Worker checks daily count before each batch and idles when exceeded.')
ON CONFLICT (flag) DO NOTHING;

COMMIT;
