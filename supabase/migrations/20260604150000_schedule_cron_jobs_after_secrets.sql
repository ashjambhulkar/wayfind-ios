-- Follow-up scheduling pass after Vault cron secrets are configured.
--
-- The original cron migrations intentionally no-op when
-- `edge_function_base_url` / `edge_cron_secret` are missing. This migration
-- can be safely re-run after those secrets are present.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

DO $$
BEGIN
  PERFORM cron.unschedule('gc-storage-objects-nightly');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('poll-flight-status-every-5min');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('reconcile-revenuecat-nightly');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
DECLARE
  v_url text;
  v_secret text;
BEGIN
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets
  WHERE name = 'edge_function_base_url';

  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'edge_cron_secret';

  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE EXCEPTION 'Cannot schedule cron jobs: edge_function_base_url or edge_cron_secret is missing';
  END IF;

  PERFORM cron.schedule(
    'gc-storage-objects-nightly',
    '17 3 * * *',
    format(
      $sql$
        SELECT net.http_post(
          url := %L,
          headers := jsonb_build_object(
            'Authorization', %L,
            'Content-Type', 'application/json'
          ),
          body := '{}'::jsonb,
          timeout_milliseconds := 60000
        );
      $sql$,
      v_url || '/functions/v1/gc-storage-objects',
      'Bearer ' || v_secret
    )
  );

  PERFORM cron.schedule(
    'poll-flight-status-every-5min',
    '*/5 * * * *',
    format(
      $sql$
        SELECT net.http_post(
          url := %L,
          headers := jsonb_build_object(
            'Authorization', %L,
            'Content-Type', 'application/json'
          ),
          body := '{}'::jsonb,
          timeout_milliseconds := 60000
        );
      $sql$,
      v_url || '/functions/v1/poll-flight-status',
      'Bearer ' || v_secret
    )
  );

  PERFORM cron.schedule(
    'reconcile-revenuecat-nightly',
    '23 4 * * *',
    format(
      $sql$
        SELECT net.http_post(
          url := %L,
          headers := jsonb_build_object(
            'Authorization', %L,
            'Content-Type', 'application/json'
          ),
          body := '{}'::jsonb,
          timeout_milliseconds := 300000
        );
      $sql$,
      v_url || '/functions/v1/reconcile-revenuecat',
      'Bearer ' || v_secret
    )
  );
END $$;
