-- Wave 4.4 — schedule the `reconcile-revenuecat` Edge Function nightly.
--
-- Runs at 04:23 UTC. Off-peak for both US and EU traffic so the
-- nightly RevenueCat REST burst doesn't compete with daytime
-- entitlement reads. The 23-minute offset within the hour is
-- intentional: keeps this job out of the same minute as
-- `gc-storage-objects-nightly` (00:00 UTC) and any other cleanups,
-- so a single Postgres slot doesn't get serialised behind another
-- long-running job.
--
-- Pattern mirrors `poll-flight-status` and `gc-storage-objects` so
-- ops can read all `wf:*` schedules at a glance.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

DO $$
BEGIN
  PERFORM cron.unschedule('reconcile-revenuecat-nightly');
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

DO $$
DECLARE
  v_url text;
  v_secret text;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_url
    FROM vault.decrypted_secrets WHERE name = 'edge_function_base_url';
  EXCEPTION WHEN OTHERS THEN
    v_url := NULL;
  END;

  BEGIN
    SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets WHERE name = 'edge_cron_secret';
  EXCEPTION WHEN OTHERS THEN
    v_secret := NULL;
  END;

  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'reconcile-revenuecat cron not scheduled — vault secrets missing';
    RETURN;
  END IF;

  PERFORM cron.schedule(
    'reconcile-revenuecat-nightly',
    '23 4 * * *',  -- 04:23 UTC daily
    format(
      $sql$
        SELECT net.http_post(
          url := %L,
          headers := jsonb_build_object(
            'Authorization', %L,
            'Content-Type', 'application/json'
          ),
          body := '{}'::jsonb,
          -- Reconcile may take a while when the active cohort is large
          -- (sequential RC REST calls). 5 minutes is the comfortable
          -- ceiling for the current scale; bump if we ever process
          -- > 10K active subs per night.
          timeout_milliseconds := 300000
        );
      $sql$,
      v_url || '/functions/v1/reconcile-revenuecat',
      'Bearer ' || v_secret
    )
  );
END $$;
