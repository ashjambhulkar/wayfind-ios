# Wayfind Architecture

Use this file as the first stop when you come back to the project after time away. Keep it short enough to read before making a change.

## Runtime Shape

`WayfindApp` is the SwiftUI app entry point. It configures auth, owns the root environment objects, handles cold-start links and notification links, and switches between loading, signed-out, and signed-in surfaces.

In signed-in mode, `AppRootTabView` owns the active navigation mode:

```text
WayfindApp
  -> AppRootTabView
     -> trip list mode
     -> trip detail mode
        -> Map tab
        -> Budget tab
        -> Bookings tab
        -> AI tab
```

`TabNavigationCoordinator` is the source of truth for whether the user is looking at the trip list or a specific trip. It also owns the selected trip-detail tab.

## Data Flow

Most app features follow this path:

```text
SwiftUI View
  -> @Observable ViewModel or Store
  -> DataService or feature service
  -> SupabaseManager / Supabase Swift / Edge Function
  -> Supabase table, RPC, Storage bucket, or Function
```

`DataService` is the app-facing facade. It chooses the real backend (`SupabaseManager`) when `AppConfig.useRealBackend` is true and the mock backend (`MockDataService`) otherwise. Prefer adding new app-facing methods here unless a feature already has a focused service such as `BudgetService`, `CollaboratorService`, or `TripDocumentsService`.

## State Ownership

Use one owner per piece of state.

- Root session, environment objects, paywall surface, invite deep links: `WayfindApp`.
- Trip-list vs trip-detail navigation: `TabNavigationCoordinator`.
- Current trip collaboration permissions and member list: `CollaborationStore`.
- Trip detail itinerary data: `TripDetailViewModel`.
- Budget snapshot and optimistic budget mutations: `BudgetViewModel`.
- Map-specific sheet/search/filter state: currently `TripMapView` and `TripMapState`.
- Realtime trip refresh and collaborator kick/demotion handling: `TripRealtimeService`.

When state needs to cross feature boundaries, pass a binding, a closure, or an environment store. Avoid copying the same backend data into multiple `@State` variables unless one copy is a temporary UI draft.

## Backend Boundaries

`SupabaseManager` owns core trip/profile/timeline/place reads and writes. It also contains several newer backend bridges for city places, user photos, storage-backed uploads, and usage telemetry.

Focused backend services own feature-specific tables:

- `BudgetService`: collaborative budget tables.
- `InviteService` and `CollaboratorService`: invite and member RPCs/tables.
- `TripDocumentsService`: document metadata and the `trip-documents` storage bucket.
- `ActivityAttachmentService`, `BookingAttachmentService`, `ExpenseAttachmentService`: upload metadata plus storage cleanup.
- `ItineraryAIService`: authenticated calls to the `itinerary-ai` Edge Function.
- `EntitlementService`: RevenueCat entitlement state plus Supabase fallback mirrors.

If a feature needs a new table, update `docs/SUPABASE_BACKEND.md` in the same change so the table has an owner and a consumer before it spreads through the codebase.

## Change Rule

Every meaningful feature change should update at least one of:

- The feature README, if the flow or state ownership changed.
- `docs/SUPABASE_BACKEND.md`, if a table, RPC, policy, trigger, cron, storage bucket, or Edge Function changed.
- `docs/DECISIONS.md`, if you made a tradeoff that future-you should not have to rediscover.
- `docs/AI_CHANGE_PROTOCOL.md`, if AI repeatedly makes the same kind of confusing change.
