-- pg_cron + pg_net: POST city-place-enricher every minute.
-- Enable extensions (Dashboard → Database → Extensions): pg_cron, pg_net, if not already on.
--
-- One-time Vault setup (SQL Editor on the project — use your real values):
--
--   1) Project API URL (no trailing slash required; we rtrim below). Skip if a secret named
--      `supabase_url` already exists (e.g. used by other jobs).
--      select vault.create_secret('https://YOUR_PROJECT_REF.supabase.co', 'supabase_url');
--
--   2) Same string as Edge secret WORKER_SECRET (supabase secrets set WORKER_SECRET=...).
--      select vault.create_secret('YOUR_LONG_RANDOM_SECRET', 'worker_secret');
--
-- Deploy: set [functions.city-place-enricher] verify_jwt = false so the gateway accepts
-- this call with only x-worker-secret (auth is enforced in the function).

DO $$
DECLARE
  jid integer;
BEGIN
  SELECT jobid INTO jid FROM cron.job WHERE jobname = 'city-place-enricher-every-minute' LIMIT 1;
  IF jid IS NOT NULL THEN
    PERFORM cron.unschedule(jid);
  END IF;
END $$;

SELECT cron.schedule(
  'city-place-enricher-every-minute',
  '* * * * *',
  $cron$
  SELECT net.http_post(
    url := rtrim(
      (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1),
      '/'
    ) || '/functions/v1/city-place-enricher',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-worker-secret',
      (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'worker_secret' LIMIT 1)
    ),
    body := jsonb_build_object('batch_size', 5)
  );
  $cron$
);
