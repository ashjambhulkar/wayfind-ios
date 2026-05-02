# Wayfind — screen inventory

Functional, user-visible surfaces in the **production app** (not SwiftUI `#Preview`-only hosts). The shell is **not** a system `TabView`: after sign-in, `AppRootTabView` shows either **My Trips** (`TripsListView`) or an in-trip **NavigationStack** with `TripDetailView` at the root.

**Reachability:** **`signed in`** — all post-auth flows. **`has trip`** — itinerary, pushed map/budget/bookings/documents, trip sheets. **`owner / gates`** — budget/documents/notes may show lock or empty states for collaborators when `CollaborationStore` denies access.

---

## Auth & account

| Screen / flow | Entry | Notes |
|---------------|--------|------|
| Launch loading | Cold start while `AuthViewModel` resolves | Logo + “Wayfind” (`WayfindApp`, `.loading`). |
| Sign in | Signed out | `SignInView` (email/password, Apple, Google). |
| Sign up | From sign in (`NavigationLink`) | `SignUpView`. |
| Password reset | “Forgot password?” on sign in | Sheet with `NavigationStack` (`SignInView`). |
| Display name prompt | After sign-in when name missing | Sheet `DisplayNamePromptView` (`WayfindApp` + `.signedIn`). |

## Invites & deep links

| Screen / flow | Entry | Notes |
|---------------|--------|------|
| Invite accept | `wayfind://invite/…`, notification, cold start | Full-screen `InviteAcceptView` over root. |
| Invitee welcome | After successful join (first time per trip) | `InviteeWelcomeSheet` from `AppRootTabView`. |

## Trips list (home)

| Screen / flow | Entry | Notes |
|---------------|--------|------|
| My Trips | Signed in, no `activeTrip` | `TripsListView` — hero, upcoming, past, search, sort menu, FAB create trip. |
| Notifications | Toolbar on My Trips | `NotificationsView`. |
| Create trip | FAB / empty state | Sheet `CreateTripView`. |

## Trip detail hub (itinerary)

| Screen / flow | Entry | Notes |
|---------------|--------|------|
| Trip itinerary / timeline | Open any trip | `TripDetailView` — scrollable hero, day sections, timeline cards, toolbar (notes, checklists, overflow). |
| Edit trip | Trip actions | Sheet `EditTripView`. |
| Add activity | `+` / add flows | `AddActivitySheet` (+ nested suggested places, schedule Look Around, etc.). |
| Add booking | Toolbar / timeline | Sheet `AddBookingView` (variants by booking type). |
| Place detail | Tap place | `PlaceDetailSheet` (+ report, photos, nested sheets). |
| Edit / move place | From place detail or row | `EditPlaceView`, `MoveToDaySheet`. |
| Booking attachments | Booking row | `BookingAttachmentsSheet`. |
| Trip notes (primary task) | Toolbar shortcut or **More** menu | Push `TripNotesView` (+ `TripNoteEditorView` via navigation). |
| Trip checklists | Toolbar / **More** | Push `TripChecklistsView`. |
| Budget (sheet) | Bottom bar **Budget** | Sheet with `TripBudgetTabView` (+ add/edit expense, category budget, settlement, CSV share, etc.). |
| Bookings (sheet) | Bottom bar **Bookings** | Sheet `BookingsScreenView` (+ add/edit booking flows, `AddBookingView`, form screens). |
| Documents | **More** → Documents (pushes hub tab) | `TripDocumentsView` on `NavigationStack` (`AppRootTabView` module) — picker, category, preview sheets. |
| Map | Hub / “View on map” style actions | Push `TripMapView` or `MapTabWrapper` (iOS 26+) — places sheet, search overlay, mode sheet, add-place sheets, preview sheets. |
| AI day planner (primary task) | Sparkles / root AI entry | `AIPlanWizardSheet` (+ `AIStayAreaPickerSheet`, nested pickers). |
| Members | Toolbar avatars / invite | `TripMembersSheet` (+ `InviteComposeSheet`, `EditAccessSheet`). |
| Recent activity | From trip surfaces | `RecentActivitySheet`. |
| Activity / itinerary photos | Photo stacks | `ActivityPhotosSheet`, `ActivityPhotoGallerySheet`. |
| Calendar sync onboarding | Calendar entry / prompts | `CalendarSyncOnboardingView` (includes `TabView` pager inside). |
| Report place | Place flows | `ReportPlaceSheet`. |
| Place photos / upload / appeal | Place photos | `PhotoUploadFlow`, `ReportUserPhotoSheet`, `PhotoAppealSheet`, `FullscreenPhotoViewer` (UIKit carousel — documented exception for gallery). |
| Forwarding / booking review | Booking forwarding | `ReviewForwardedBookingsView`, `ForwardingEmailCardView` (when presented). |

## Profile & settings

| Screen / flow | Entry | Notes |
|---------------|--------|------|
| Profile | Toolbar initials on My Trips | `ProfileView`. |
| Edit profile | From profile | `EditProfileView`. |
| Pro / subscription | Profile | `ProSubscriptionSection`, Customer Center sheet. |

## Global paywall & premium gates

| Screen / flow | Entry | Notes |
|---------------|--------|------|
| Paywall | Feature gates (CSV, documents, AI cap, flight tracking, settings, etc.) | `PaywallPresenter` presents RevenueCat UI in `NavigationStack` sheet. |

## Misc / supporting (still user-visible when shown)

| Area | Examples |
|------|-----------|
| Map search & discovery | `MapSearchOverlay`, `MapSearchPreviewSheet`, `SuggestedPlacesAllSheet`, `PlaceIdAmbiguityChooserSheet`, `MapAddToDaySheet`, `TripMapModesSheet`. |
| Notifications permission | `NotificationPermissionView`, `InviteeWelcomeSheet` path. |
| Toasts / overlays | `ToastView`, `KickFadeOverlay` (kick from trip). |
| **Defined but not wired to root:** | `TripsSearchTabView` in `wayfindApp.swift` (search tab pattern) — not referenced by current shell; keep out of automated screenshot flows until wired. |

---

## Automated screenshots (`wayfindUITests`)

`ScreenshotUITests` covers roughly: **sign-in → My Trips → open seeded mock trip → itinerary → budget sheet → bookings sheet → notes → back → profile**. See `screenshots/README.md` for limits and **live-backend** behavior.
