# Module Ownership

This file answers "where should I look first?" Keep entries short. If a module gets complicated, add or update a README inside that feature folder.

## App Shell

Primary files:

- `wayfind/wayfindApp.swift`
- `wayfind/ViewModels/TabNavigationCoordinator.swift`
- `wayfind/Services/AuthSessionService.swift`
- `wayfind/Services/AppDelegate.swift`

Owns app startup, auth routing, environment injection, push notification launch payloads, invite deep links, paywall surface attachment, and trip-list vs trip-detail navigation.

## Trips And Itinerary

Primary files:

- `wayfind/Views/Trips/`
- `wayfind/Views/TripDetail/TripDetailView.swift`
- `wayfind/ViewModels/TripDetailViewModel.swift`
- `wayfind/Services/DataService.swift`
- `wayfind/Services/SupabaseManager.swift`

Owns trip list, trip detail home, itinerary days, timeline places, bookings rendered in the itinerary, documents/notes/checklist entry points, and the add/edit/move place flows.

## Map And Place Discovery

Primary files:

- `wayfind/Views/Map/`
- `wayfind/Services/AppleMapSearchService.swift`
- `wayfind/Services/CityPlacesSearchService.swift`
- `wayfind/Services/PlaceSearchService.swift`
- `wayfind/Services/MapSearchResultMerger.swift`
- `wayfind/Services/PlaceIdBridgeService.swift`

Owns trip map rendering, day filtering, search overlay, suggested places, selected place preview, add-to-day flow, map places accessory/sheet, Apple MapKit search, city place suggestions, and Apple-to-Google place ID bridging.

Read `wayfind/Views/Map/README.md` before changing sheet sequencing, search state, or map accessory behavior.

## Budget

Primary files:

- `wayfind/Views/Budget/`
- `wayfind/Views/TripDetail/TripBudgetTabView.swift`
- `wayfind/ViewModels/BudgetViewModel.swift`
- `wayfind/Services/BudgetService.swift`
- `wayfind/Services/CategoryRollup.swift`

Owns collaborative expenses, category budgets, home-currency summaries, split editing, settlements, receipt attachments, and CSV export. `BudgetService` is the backend owner; `BudgetViewModel` owns UI snapshot, derived rollups, and optimistic mutations.

## Collaboration And Invites

Primary files:

- `wayfind/ViewModels/CollaborationStore.swift`
- `wayfind/ViewModels/TripCollaborationUiStore.swift`
- `wayfind/Services/CollaboratorService.swift`
- `wayfind/Services/InviteService.swift`
- `wayfind/Services/Realtime/TripRealtimeService.swift`
- `wayfind/Views/Invites/`
- `wayfind/Views/TripDetail/Members/`

Owns trip members, access flags, invite creation/acceptance, collaborator role changes, activity feed flashes, and realtime refresh/kick behavior.

## Bookings And Attachments

Primary files:

- `wayfind/Views/Bookings/`
- `wayfind/Services/BookingAttachmentService.swift`
- `wayfind/Services/CalendarSyncService.swift`
- `wayfind/Services/FlightTrackingService.swift`
- `wayfind/Services/BackgroundUploader.swift`

Owns manual bookings, parsed/forwarded bookings, booking attachment upload/commit, calendar event links, and flight status polling/rendering.

## AI Planning

Primary files:

- `wayfind/Views/TripDetail/AIPlanWizardSheet.swift`
- `wayfind/Views/TripDetail/AIStayAreaPickerSheet.swift`
- `wayfind/ViewModels/AIDayPlannerViewModel.swift`
- `wayfind/Services/ItineraryAIService.swift`
- `wayfind/Models/ItineraryAIModels.swift`

Owns day-plan preview generation, stay-area selection, quota/paywall presentation, and applying AI-generated itinerary ops. The Swift client calls the `itinerary-ai` Edge Function; the database commit path goes through itinerary ops/RPCs.

## Documents, Notes, Checklist

Primary files:

- `wayfind/Views/TripDetail/TripDocumentsView.swift`
- `wayfind/Views/TripDetail/TripNotesView.swift`
- `wayfind/Models/TripChecklistModels.swift`
- `wayfind/Services/TripDocumentsService.swift`

Owns trip documents, notes, checklist template state, document storage metadata, and document category UI.

## Profile, Entitlements, And Settings

Primary files:

- `wayfind/Views/Profile/`
- `wayfind/Services/EntitlementService.swift`
- `wayfind/Services/PaywallPresenter.swift`
- `wayfind/Services/UserPreferencesStore.swift`

Owns profile editing, avatar upload, subscription display, RevenueCat mirror/fallback state, usage caps, appearance preference, and global paywall presentation.

## Backend And Database

Primary files:

- `supabase/migrations/`
- `supabase/functions/`
- `supabase/config.toml`
- `supabase/seed.sql`
- `docs/SUPABASE_BACKEND.md`

Owns schema, RLS, triggers, RPCs, Edge Functions, cron jobs, service-role workers, storage cleanup, and local seed data.
