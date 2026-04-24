-- Disable pg_cron job: cleanup-old-trip-routes
-- Use cron.alter_job (supported API). Direct UPDATE on cron.job often returns permission denied on hosted Supabase.

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname = 'cleanup-old-trip-routes' LIMIT 1),
  active := false
);
