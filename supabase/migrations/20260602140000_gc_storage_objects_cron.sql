-- Wave 0 (shared infra) — schedule the gc-storage-objects Edge Function nightly.
--
-- Pattern matches existing pg_cron schedules in the repo
-- (see 20260430110000_city_place_enricher_cron.sql). Runs at 03:17 UTC to
-- avoid the top-of-the-hour stampede that hits when many other crons fire.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Drop any prior schedule with the same name so reruns of this migration
-- against a previously-deployed environment stay clean.
DO $$
BEGIN
  PERFORM cron.unschedule('gc-storage-objects-nightly');
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END $$;

DO $$
DECLARE
  v_url text;
  v_secret text;
BEGIN
  -- Secrets are stored in vault.secrets per the Supabase pattern. Skip
  -- silently if not configured (local dev) — the function can still be
  -- invoked manually for testing.
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
    RAISE NOTICE 'gc-storage-objects cron not scheduled — vault secrets missing';
    RETURN;
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
END $$;
