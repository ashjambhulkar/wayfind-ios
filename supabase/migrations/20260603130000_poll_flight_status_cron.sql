-- Wave 3.2 — schedule the `poll-flight-status` Edge Function.
--
-- Runs every 5 minutes. The function itself is the rate-limiter: it
-- selects only `flight_statuses` rows whose `next_poll_at <= now()`,
-- so 5-minute ticks are cheap when nothing is due (a single
-- `select count(*) where ...` query) and self-throttling when the
-- batch is large (capped at MAX_ROWS_PER_INVOCATION inside the
-- function).
--
-- Pattern intentionally mirrors gc-storage-objects-nightly so ops
-- understands all `wf:*` cron jobs at a glance.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

DO $$
BEGIN
  PERFORM cron.unschedule('poll-flight-status-every-5min');
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
    RAISE NOTICE 'poll-flight-status cron not scheduled — vault secrets missing';
    RETURN;
  END IF;

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
END $$;
