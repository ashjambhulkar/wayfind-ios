# Supabase Backend Map

This is the backend memory file. Update it whenever AI or you add/change a table, RPC, RLS policy, trigger, cron job, storage bucket, or Edge Function.

## How To Read The Backend

Start here, in order:

1. `supabase/migrations/` for schema, RLS, triggers, RPCs, cron, and storage policies.
2. `supabase/config.toml` for Edge Function JWT gateway settings.
3. `supabase/functions/<function>/index.ts` for function entry points.
4. `supabase/functions/_shared/` for shared planning, enrichment, cache, and utility logic.
5. Swift service owner in `wayfind/Services/`.

Do not rely on memory for table shape. Open the latest migration that created or altered the table, then check the Swift DTO that decodes it.

## Table Ownership

| Area | Tables / Buckets | Main Swift owner | Notes |
|---|---|---|---|
| Auth profile | `profiles`, `avatars` bucket | `AuthSessionService`, `SupabaseManager` | Profile creation/upsert, display name, avatar URL, preferences, payment handles. |
| Trips | `trips`, `trip_days`, `trip_activities` | `DataService`, `SupabaseManager`, `TripDetailViewModel` | Core itinerary data. `trip_days` includes day 0 "Ideas" plus scheduled days. |
| Timeline bookings | `trip_bookings`, `trip_booking_attachments` | `SupabaseManager`, `BookingAttachmentService` | Bookings render as `Place`-like timeline rows in the app. |
| Notes/checklist | `trip_notes`, `trip_checklists`, `checklist_items` | `SupabaseManager`, trip detail views | Checklist templates are ensured by RPC/function logic before rendering progress. |
| Documents | `trip_documents`, `trip-documents` bucket | `TripDocumentsService` | Metadata table plus storage policies and pending storage cleanup. |
| Activity attachments | `trip_activity_attachments`, `activity-attachments` bucket | `ActivityAttachmentService` | Photo/file attachments for itinerary activities. |
| Collaborative budget | `trip_expenses`, `expense_splits`, `trip_budgets`, `expense_settlements`, expense attachment tables | `BudgetService`, `BudgetViewModel` | Money values should use `DecimalCodec`; triggers denormalize split trip IDs and log collaboration activity. |
| Collaboration | `trip_collaborators`, `trip_invites`, `trip_activity_log` | `CollaboratorService`, `InviteService`, `TripRealtimeService`, `ActivityFeedService` | Stores membership/access flags and activity feed events. |
| Notifications | `fcm_tokens`, `notifications`, collaboration throttle tables | `PushNotificationService`, `NotificationManager` | Edge Functions send pushes through the shared notification worker. |
| Places cache/search | `city_profiles`, `city_places`, `city_profile_cover_images`, `city_profile_cover_fetch_jobs`, `city_profile_cover_assignments`, `city_travel_times`, `place_cache`, `place_id_bridge`, usage telemetry tables | `CityPlacesSearchService`, `AppleTravelTimesService`, `PlaceIdBridgeService`, `SupabaseManager` | Powers suggested places, trip cover pools, travel times, Apple-to-Google bridge, and usage rollups. |
| User photos | `place_user_photos`, photo events/reports/appeals tables | `PlacePhotoUploadService`, `SupabaseManager` | Moderation and DSA flow lives in functions plus migration triggers. |
| Payments/subscriptions | `user_subscriptions`, `usage_events`, `processed_webhook_events`, pro gate tables | `EntitlementService`, `PaywallPresenter` | RevenueCat webhook, reconciliation, validation, idempotency, and usage limits. |
| Forwarded email/imports | `email_forwarding_queue`, `user_forwarding_addresses`, parsed booking tables | booking/import services and functions | Inbound email, extraction, processing, and notification flow. |
| Flight tracking | `flight_statuses` | `FlightTrackingService` | Cron polls status and sends notification changes. |
| Calendar sync | `calendar_event_links` | `CalendarSyncService` | Local calendar event linkage for trip items. |

## Edge Functions

| Function | Triggered by | Responsibility |
|---|---|---|
| `itinerary-ai` | iOS client via `ItineraryAIService` | Generate plan-day previews and apply itinerary ops with auth/quota checks. |
| `places-cache` | authenticated client/server calls | Cached place detail lookups. |
| `lookup-place-id` | iOS place bridge flow | Resolve Apple/coordinate/name data to Google place IDs with rate limiting. |
| `sync-city-place-from-trip` | app/backend after adding place-backed activities | Upsert trip places into the city place pool. |
| `city-place-enricher` | cron/worker secret | Claim enrichment jobs and hydrate city place details. |
| `city-cover-images` | cron/worker secret | Fill per-city Unsplash cover pools, enforce Unsplash quota, and track download events. |
| `ingest-open-data-for-city` | service-role worker | Ingest open data sources for a city pool. |
| `serp-consumer` / `ai-consumer` | queued workers | Consume enrichment/planning queues and shared pipeline modules. |
| `commit-attachment` | uploader flow | Finalize uploaded files and metadata after background upload. |
| `moderate-place-photo` | photo upload flow | Moderate user photos and emit lifecycle events. |
| `gc-storage-objects` | cron | Delete orphaned storage objects from pending deletion table. |
| `send-notification` | other functions | Send push notifications through a single worker surface. |
| `collaboration-notify` | database webhook / activity trigger | Convert activity events into collaboration notifications. |
| `send-invite-email` | invite flow | Send email invitations. |
| `receive-forwarded-email` | SendGrid inbound webhook | Receive raw forwarded emails. |
| `process-forwarded-email` | worker/manual invocation | Parse/attach forwarded booking email payloads. |
| `extract-booking` | client/import flow | Extract structured booking data and notify. |
| `poll-flight-status` | cron | Poll flight status and notify changes. |
| `currency-rates` | client/service flow | Fetch currency rates. |
| `validate-subscription` | entitlement validation | Validate RevenueCat/Supabase subscription state. |
| `revenuecat-webhook` | RevenueCat webhook | Mirror subscription events with idempotency. |
| `reconcile-revenuecat` | cron/manual | Repair subscription mirror drift. |
| `delete-user` | authenticated account deletion | Delete user data with admin privileges. |
| `upload-travel-leg` | iOS travel time/route flow | Upload Apple-sourced travel leg data. |
| `places-usage-rollup` | cron | Aggregate place usage telemetry. |

## Cron, Triggers, And Hidden Side Effects

These are the places most likely to surprise future-you:

- `city_place_enricher_cron` calls `city-place-enricher` through `pg_cron` + `pg_net` and Vault secrets.
- `city-cover-images-every-15-minutes` calls `city-cover-images` with `backfill_missing` to seed/refill city cover pools under the Unsplash hourly budget. The function also drains pending Unsplash download tracking events from cover assignments.
- `places_usage_telemetry` schedules rollups into usage daily tables.
- `reconcile_revenuecat_cron`, `poll_flight_status_cron`, and `gc_storage_objects_cron` call Edge Functions from the database.
- `claim_ai_usage` currently includes a temporary free-launch override for AI
  planner access. See `docs/free-launch-paywall-runbook.md` before changing
  paid-plan gates.
- Collaboration activity triggers write `trip_activity_log` and may invoke `collaboration-notify`.
- Budget triggers sync booking expenses, split trip IDs, updated timestamps, and collaboration log rows.
- Storage cleanup triggers enqueue pending deletes instead of deleting files inline.

When debugging "why did this row change?", search migrations for the table name plus `TRIGGER`, then search functions for the table name.

## Change Checklist

For every backend change:

- Add a new timestamped migration. Do not edit an old migration unless it has never been shared.
- Write the table/RPC/function owner in this file.
- Update the Swift model/DTO and the owning service in the same change.
- Check RLS for owner, collaborator, and service-role paths.
- If a trigger writes side effects, document it under "Cron, Triggers, And Hidden Side Effects".
- If an Edge Function needs auth, update `supabase/config.toml` and mention whether JWT is gateway-verified or checked inside the function.
- Add or update a Supabase SQL smoke test when money, permissions, invite acceptance, or destructive cleanup is involved.

## AI Prompt To Use Before Backend Work

Paste this when asking AI to modify Supabase code:

```text
Before changing backend code, read docs/SUPABASE_BACKEND.md, the latest migration touching the affected tables, the owning Swift service/DTO, and supabase/config.toml if an Edge Function is involved. After the change, update docs/SUPABASE_BACKEND.md with any new/changed table, RPC, RLS policy, trigger, cron, storage bucket, Edge Function, auth mode, and Swift owner.
```
