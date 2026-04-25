-- Wave 4.4 — Idempotency table for RevenueCat webhook deliveries.
--
-- Why: RevenueCat retries webhook POSTs (network blips, 5xx, deploys
-- mid-delivery) up to ~30 attempts over 72 hours. Without an idempotency
-- check the same INITIAL_PURCHASE event can flip `user_subscriptions`
-- back into Pro after a CANCELLATION arrives between retries — the
-- last-write-wins ordering RevenueCat doesn't promise. Indexing on
-- the `id` field of every webhook payload (RevenueCat ships a stable
-- UUID per event) lets us return 200 immediately on a retry without
-- mutating state again.
--
-- Why a `processed_at` timestamp instead of just a row presence:
-- diagnostic. When we get a tail event arriving 71 hours late we want
-- to know whether the original landed inside the SLA or whether the
-- retry was the first successful delivery. Cheap to add.
--
-- Retention: 90 days via a daily `pg_cron` job — RevenueCat's retry
-- window is 72h so anything older than 90d can't possibly collide.
-- Cron lives in the same migration to avoid a "table without GC"
-- drift between deploys.

CREATE TABLE IF NOT EXISTS public.processed_webhook_events (
  -- RevenueCat's per-event UUID, propagated as `event.id` in the body.
  -- We accept any text shape because some webhook providers (e.g. the
  -- nightly reconcile job, see Wave 4.4) compose synthetic event ids
  -- like `reconcile:<run_at_iso>:<user_id>`.
  event_id text PRIMARY KEY,
  -- The event type — INITIAL_PURCHASE, RENEWAL, CANCELLATION, REFUND, etc.
  -- Useful for analytics ("how many REFUND events did we process
  -- this month?") without re-parsing the body.
  event_type text NOT NULL,
  -- The Wayfind user id we resolved the event to. Nullable for cases
  -- where `app_user_id` wasn't a UUID and we early-returned 200; we
  -- still record the event so retries don't re-spam the warning log.
  user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
  -- Source of the delivery. `webhook` for live RevenueCat callbacks,
  -- `reconcile` for the nightly reconcile-revenuecat job (Wave 4.4),
  -- `validate` for the iOS-client-initiated validate-subscription
  -- backup. Three sources, one ledger — if they ever disagree we can
  -- pivot a single audit query to find out which path won and why.
  source text NOT NULL DEFAULT 'webhook'
    CHECK (source IN ('webhook', 'reconcile', 'validate')),
  processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_processed_webhook_events_user_id
  ON public.processed_webhook_events (user_id, processed_at DESC)
  WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_processed_webhook_events_processed_at
  ON public.processed_webhook_events (processed_at DESC);

-- RLS: never read from the client. Service role only.
ALTER TABLE public.processed_webhook_events ENABLE ROW LEVEL SECURITY;
-- No SELECT policy = no client access. Edge Functions go through the
-- service role which bypasses RLS by design.

-- Daily GC — drop entries older than 90 days. Unconditional on
-- `processed_at` so a slow re-deploy doesn't accidentally re-process
-- a legitimately-stale event.
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  PERFORM cron.unschedule('processed-webhook-events-gc-daily');
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.schedule(
    'processed-webhook-events-gc-daily',
    '17 3 * * *',  -- 03:17 UTC, off-peak for both US and EU.
    $sql$
      DELETE FROM public.processed_webhook_events
      WHERE processed_at < now() - interval '90 days';
    $sql$
  );
END $$;
