-- Observability for inbound email → LLM pipeline (mirrors remote apply_migration).

DO $body$
BEGIN
  IF to_regclass('public.email_forwarding_queue') IS NULL THEN
    RETURN;
  END IF;
  ALTER TABLE public.email_forwarding_queue
    ADD COLUMN IF NOT EXISTS pipeline_debug jsonb DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS ingestion_stage text;
  COMMENT ON COLUMN public.email_forwarding_queue.pipeline_debug IS
    'Structured ingestion diagnostics (sizes, unwrap path). Not user-facing errors.';
  COMMENT ON COLUMN public.email_forwarding_queue.ingestion_stage IS
    'Last pipeline milestone for debugging (e.g. bodies_resolved, completed).';
END
$body$;
