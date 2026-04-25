# Wave 4.4 — RevenueCat reconcile + secret rotation runbook

Companion to:
* `supabase/functions/revenuecat-webhook/index.ts`
* `supabase/functions/reconcile-revenuecat/index.ts`
* `supabase/migrations/20260604120000_processed_webhook_events.sql`
* `supabase/migrations/20260604130000_reconcile_revenuecat_cron.sql`

## Architecture

Three components keep `public.user_subscriptions` honest:

1. **Webhook** (`revenuecat-webhook`) — sub-second freshness on every
   lifecycle event. Idempotent via `processed_webhook_events`.
2. **Reconcile cron** (`reconcile-revenuecat`) — nightly drift catcher
   for events that were dropped, misordered, or stuck in retry.
3. **iOS client backup** (`validate-subscription`) — kept in place for
   the iOS app to call when it suspects local mirror staleness right
   after a purchase. Not deprecated.

The reconcile cron and the iOS backup both write through the *same*
`processed_webhook_events` audit table (`source` distinguishes
`webhook` from `reconcile`), so any forensic question — "why is this
user marked Pro?" — has a single ledger to read.

## Required Supabase secrets

Set via `supabase secrets set` (or the dashboard):

| Secret                                | Purpose                                              |
|----------------------------------------|------------------------------------------------------|
| `REVENUECAT_WEBHOOK_SECRET`            | Bearer token RevenueCat presents on webhook delivery |
| `REVENUECAT_WEBHOOK_SECRET_NEXT`       | Optional rotation slot (see below)                    |
| `REVENUECAT_ENTITLEMENT_ID`            | Defaults to `wayfind_pro`; set explicitly to be safe |
| `RC_PROJECT_ID`                        | RevenueCat project id (for reconcile REST API)       |
| `RC_SECRET_API_KEY`                    | RevenueCat **secret** API key (Project → API Keys → Secret) |

Plus the existing infrastructure secrets the rest of the Edge
Functions assume:

| Secret                       | Purpose                                  |
|------------------------------|------------------------------------------|
| `SUPABASE_URL`               | Auto-injected by the Supabase runtime    |
| `SUPABASE_SERVICE_ROLE_KEY`  | Auto-injected by the Supabase runtime    |
| `edge_function_base_url`     | Vault — base URL for cron HTTP POSTs     |
| `edge_cron_secret`           | Vault — bearer token for cron HTTP POSTs |

## Webhook secret rotation (zero downtime)

The webhook accepts the value of *either* `REVENUECAT_WEBHOOK_SECRET`
or `REVENUECAT_WEBHOOK_SECRET_NEXT`. To rotate without a delivery gap:

1. **Generate** a new secret (32+ random chars, e.g. `openssl rand -hex 24`).
2. **Stage** it on Supabase as the *next* secret:
   ```
   supabase secrets set REVENUECAT_WEBHOOK_SECRET_NEXT=<new>
   ```
3. **Switch** the value RevenueCat sends — Project → Integrations →
   Webhooks → edit the Authorization header value to `<new>`.
4. **Verify** delivery in the RevenueCat webhook log + the Supabase
   Edge Function log. New deliveries should succeed; queued retries
   from the old secret should also succeed (we accept both during the
   overlap).
5. **Promote**: `supabase secrets set REVENUECAT_WEBHOOK_SECRET=<new>`
   then `supabase secrets unset REVENUECAT_WEBHOOK_SECRET_NEXT`.

If step 4 reveals that new deliveries are 401-ing, RevenueCat is
likely caching the old value — re-save the integration in the
RevenueCat dashboard to flush.

## What reconcile catches

Run nightly at 04:23 UTC. Pulls every row in `user_subscriptions`
where `is_pro = true` OR `expires_at <= now() + 7 days`. For each
row, calls `GET /v1/subscribers/{user_id}` against RevenueCat REST
and:

* If RC's `wayfind_pro` entitlement state agrees → no-op.
* If RC says **Pro**, local says **Free** → drift (the webhook missed
  an INITIAL_PURCHASE / RENEWAL / UNCANCELLATION). Upserts to Pro,
  audit row with `source = 'reconcile'`.
* If RC says **Free**, local says **Pro** → drift (the webhook
  missed an EXPIRATION / REFUND / CANCELLATION-past-expiration).
  Upserts to Free, audit row.

The reconcile job *only* writes when state disagrees, so the
`processed_webhook_events` table doesn't fill up on the no-op
nights. Audit rows are kept for 90 days by the GC schedule that
ships in the same migration as the table.

## Failure modes & mitigations

| Failure                                          | Detection                                 | Mitigation                                                                |
|--------------------------------------------------|-------------------------------------------|---------------------------------------------------------------------------|
| RevenueCat REST API down                         | reconcile logs `reconcile_rc_non_ok`      | reconcile skips the row; tomorrow's run retries.                         |
| Webhook returns 5xx for a real event             | RevenueCat retries up to 30x over 72h     | Idempotent — first successful delivery writes, retries return `deduplicated:true`. |
| SUBSCRIBER_ALIAS arrives before INITIAL_PURCHASE | No alias row to copy; webhook 200s no-op  | reconcile sees the merged user under the new id and writes the truth.    |
| App Review rejects "providing access to refund"  | RC fires REFUND, webhook flips Pro → Free | REFUND handler explicitly sets `expires_at` to the past so downstream gates revoke immediately. |
| Drift opens between webhook and reconcile        | `processed_webhook_events.source = 'reconcile'` row appears | Audit row tells ops which event we missed; correct webhook config / RC retry config. |

## Manual reconcile invocation

The reconcile function is idempotent — safe to invoke any time:

```bash
supabase functions invoke reconcile-revenuecat
```

Returns `{ ok: true, processed, matches, drifts, skipped, run_at }`.
A non-zero `drifts` count is the signal to investigate the webhook
log for the run window between the previous and current invocation.
