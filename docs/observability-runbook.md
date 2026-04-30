# Observability Runbook

Wayfind uses Sentry for actionable crashes/exceptions and Grafana Loki for operational log trends. Do not forward arbitrary app logs, request bodies, provider payloads, tokens, emails, invite links, LLM prompts/responses, or attachment names.

## Sentry

### iOS

1. Create an iOS project in Sentry and copy the public DSN.
2. Set `AppConfig.sentryDSN` in `wayfind/AppConfig.swift` for the target environment. Leaving it empty disables Sentry at runtime.
3. Keep `AppConfig.sentryTraceSampleRate` at `0.0` until production errors are understood.
4. Upload dSYMs from release/TestFlight builds using Sentry's recommended Xcode or CI upload step before relying on symbolicated crash reports.

The iOS wrapper sends only:

- Sentry crashes and selected handled errors.
- `wayfind.domain` and `wayfind.reason` tags.
- Sanitized `wayfind` context with primitive allowlisted values.
- Supabase user id through Sentry user context, without email or profile fields.

### Supabase Edge Functions

Set secrets per Supabase project:

```sh
supabase secrets set SENTRY_DSN=<edge-sentry-dsn>
supabase secrets set SENTRY_ENVIRONMENT=production
supabase secrets set SENTRY_RELEASE=<git-sha-or-release>
```

`supabase/functions/_shared/observability.ts` initializes Sentry only when `SENTRY_DSN` is present. It disables default integrations and captures exceptions with request-local tags to avoid leaking context between reused Edge isolates.

## Grafana Loki

1. In Supabase, create a Log Drain for the project.
2. Choose Grafana Loki as the destination.
3. Use the Loki push URL from Grafana Cloud and the required auth headers.
4. Start with a short retention window, then raise it after log volume is measured.

Prefer low-cardinality labels such as `fn`, `evt`, `lvl`, and coarse `status`. Keep `trace_id`, `user_id`, `trip_id`, and booking/flight ids as searchable JSON fields, not labels.

Useful Loki queries:

```logql
{service="wayfind-edge"} | json | fn="lookup-flight" | lvl="warn"
```

```logql
{service="wayfind-edge"} | json | fn="poll-flight-status" | evt=~"provider_.*|update_error|push_exception"
```

```logql
{service="wayfind-edge"} | json | fn="itinerary-ai" | trace_id="<trace-id>"
```

## Dashboards

Create panels for:

- Edge error and warning rate by `fn` and `evt`.
- Flight lookup outcomes: `lookup_found`, `lookup_not_found`, `lookup_provider_exception`.
- Flight polling health: processed rows, provider exceptions, update failures, push exceptions.
- AI planner status by `trace_id`, response status, and handler exceptions.
- Existing Places cost/usage rollups from `places_usage_daily`.

## Alerts

Alert only after at least one observation window establishes baseline volume.

- Page on repeated 5xx or handler exceptions.
- Page when cron workers have no successful run in the expected interval.
- Warn on provider exception spikes.
- Warn on Sentry issue volume growth.

Do not alert on expected validation failures, OAuth cancellation, user quota limits, cache misses, provider 404 not-found responses, or user input mistakes.

## Noise And Privacy Checklist

Before enabling a new event or dashboard field, confirm it is:

- A primitive string, number, or boolean.
- Useful for debugging, alerting, or trend analysis.
- Truncated if it can be long.
- Not a secret, token, email, request/response body, invite link, full URL, LLM content, user note, or provider payload.
- Not high-cardinality if used as a Loki label.
