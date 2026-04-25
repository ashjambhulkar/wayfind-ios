# Wayfind V1 — Expo React Native Implementation Plan

> **Overview:** Complete V1 build plan for Expo React Native (iOS + Android). 2-week sprint. Built on EXISTING Supabase backend (26 tables, 6 Edge Functions, RLS policies, Storage buckets — ALL already deployed). Key architectural facts: trip_activities (not 'places') with travel legs + directions, trip_bookings with 11 kinds, FCM push via send-notification Edge Function, SendGrid inbound for email forwarding, itinerary-ai for AI planning, places-cache with Upstash Redis — all deployed. NO Google Places photos (decided early — use Lucide category icons on timeline, user-uploaded photos only via trip_activity_attachments). Columns to drop: place_cache_photo_reference, trip_activities_place_photo_ref. Backend: places-cache photo/batch_photos actions unused. Pure frontend build — zero backend work needed. Tech: Expo SDK 52+, expo-router, react-native-reanimated, @gorhom/bottom-sheet, react-native-maps, zustand, react-native-iap, supabase-js.

## Implementation checklist

- [ ] **v1-day1** — Day 1: Expo project setup (SDK 52, TypeScript strict, expo-router). Install core dependencies (supabase-js, zustand, react-native-reanimated, @gorhom/bottom-sheet, react-native-maps, expo-haptics, expo-image-picker, expo-clipboard, expo-notifications). Supabase client singleton. TypeScript interfaces matching all 26 existing tables. Theme system (colors, typography, spacing).
- [ ] **v1-day2** — Day 2: Auth system (email/password via supabase-js auth, profile auto-creation trigger or client-side). Auth gate in root layout. Sign In / Sign Up screens with warm cream design. Secure session persistence.
- [ ] **v1-day3** — Day 3: Trips List screen (active hero, upcoming horizontal scroll, past collapsed). Trip card component. Search + sort. Pull-to-refresh. Empty state. FAB for create trip. Avatar in header → Profile.
- [ ] **v1-day4** — Day 4: Create Trip bottom sheet (destination with Google Places autocomplete via places-cache Edge Function, date pickers, auto-title, auto-generate trip_days). Trip Detail header (cover photo with parallax, status pill, pills row).
- [ ] **v1-day5** — Day 5: Timeline core — ScrollView with collapsible day sections (sticky headers), ActivityCard for trip_activities, BookingCard for trip_bookings (11 kinds, colored left border), TimelineGap with travel time, NowIndicator, OngoingBookingBanner.
- [ ] **v1-day6** — Day 6: Timeline interaction — collapse/expand with Reanimated, drag-to-reorder, swipe-to-delete with undo toast. Ideas/wishlist section (day_number=0 activities). InlineAddButton. Speed Dial FAB (Add Activity, Add Booking).
- [ ] **v1-day7** — Day 7: Add Activity bottom sheet (Google Places search via places-cache, wishlist section, quick-add + detail form). Add Booking screen (horizontal chip selector for 11 kinds, kind-specific forms, auto-day-assignment).
- [ ] **v1-day8** — Day 8: Bookings screen (grouped by kind, 11 sections). Email forwarding section (user_forwarding_addresses, copy address, forwarding discovery banner). Parsed bookings review (email_forwarding_queue status: pending/processing/processed/failed).
- [ ] **v1-day9** — Day 9: Map view (react-native-maps with day-colored pins for activities + kind-colored pins for bookings, day filter chips, pin tap detail sheet, auto-fit region). Place/activity detail bottom sheet (name, address, rating from place_cache, travel times, Navigate/Edit/Delete).
- [x] **v1-day10** — Day 10: Edit Trip sheet (title, destination, dates with cascade logic, cover photo via expo-image-picker → Supabase Storage). Profile screen (from profiles table — username, avatar, display_name, bio, sign out). FCM push notification setup (expo-notifications + fcm_tokens registration).
- [x] **v1-day11** — Day 11: Push notifications (register FCM token on login, handle incoming via send-notification Edge Function: booking parsed, trip tomorrow). In-app notifications (notifications table — badge dots, toast overlays). Backend cleanup: drop unused Google Places photo columns (place_cache_photo_reference, trip_activities_place_photo_ref), remove photo/batch_photos actions from places-cache usage. (RLS policies + Storage buckets already deployed — no security work needed.)
- [x] **v1-day12** — Day 12: Dark mode (useColorScheme + theme tokens). Haptic feedback on all interactions. Skeleton loading states. Error handling + network error toasts. Accessibility labels.
- [ ] **v1-day13** — Day 13: Testing on iOS Simulator + Android Emulator + physical devices. Edge case testing (empty states, offline, long trip names, many activities). Performance profiling.
- [ ] **v1-day14** — Day 14: App icons + splash screen (expo-splash-screen). EAS Build for iOS + Android. TestFlight + Google Play Internal Testing. App Store / Play Store metadata. Submit both platforms.

---

## Architecture Overview

### What's Already Built (Backend — Zero Changes Needed for V1)

The Supabase backend is fully deployed — database, Edge Functions, RLS policies, and Storage buckets are all in place. V1 is a **pure frontend build**. Zero backend work needed.

**Already deployed (confirmed):**

- 26 database tables with all constraints

- RLS policies on all tables (user isolation + collaborator access)

- Storage buckets (trip-documents, place-photos, etc.)

- 6 Edge Functions (receive-forwarded-email, process-forwarded-email, extract-booking, send-notification, places-cache, itinerary-ai)

- Upstash Redis cache layer

- SendGrid inbound email parsing webhook

- Firebase FCM for push notifications

**Decision: No Google Places Photos.** The app uses Lucide category icons on timeline cards (attraction, restaurant, transport, etc.) and user-uploaded photos via `trip_activity_attachments`. Google Places photos are NOT fetched. The `places-cache` Edge Function's `photo` and `batch_photos` actions are unused. Columns `place_cache.photo_reference` and `trip_activities.place_photo_ref` should be dropped in a cleanup migration.

**Existing Edge Functions (6):**

| Function                  | Purpose                                                                                   | Used in V1?                     |
| ------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------- |
| `receive-forwarded-email` | SendGrid inbound webhook → stores raw email → queues for processing                       | Yes — email forwarding pipeline |
| `process-forwarded-email` | Loads queued email → AI extracts bookings → inserts into `trip_bookings`                  | Yes — automatic booking parsing |
| `extract-booking`         | User uploads document/screenshot → AI extracts bookings                                   | Yes — manual document upload    |
| `send-notification`       | Creates notification row + sends FCM push to all user devices                             | Yes — push notifications        |
| `places-cache`            | Cached Google Places proxy (details, search, distance, directions, photos)                | Yes — place search + details    |
| `itinerary-ai`            | AI trip planning (activities, travel times, place resolution) + RPC `apply_itinerary_ops` | V2b — not used in V1            |

**Existing Tables (26) — key ones for V1:**

| Table                       | V1 Usage                                                                                           |
| --------------------------- | -------------------------------------------------------------------------------------------------- |
| `profiles`                  | User profile (username, avatar, display_name, bio)                                                 |
| `trips`                     | Trip CRUD (name, destination, dates, cover, status, privacy, budget)                               |
| `trip_days`                 | Days within a trip (date, label, notes, timezone, day_number)                                      |
| `trip_activities`           | Places/activities on timeline (name, category, times, location, place_id, travel legs, sort_order) |
| `trip_activity_attachments` | Photos/files/links per activity                                                                    |
| `trip_bookings`             | Bookings (11 kinds, confirmation_code, provider, times, locations, details_json, price)            |
| `trip_booking_attachments`  | Documents per booking                                                                              |
| `user_forwarding_addresses` | Per-trip email forwarding address tokens                                                           |
| `email_forwarding_queue`    | Email processing pipeline status                                                                   |
| `notifications`             | In-app notification history                                                                        |
| `fcm_tokens`                | Push notification device registration                                                              |
| `place_cache`               | Cached Google Places data                                                                          |

**External Services:**

| Service                                                      | How Used                                        | Existing?                                     |
| ------------------------------------------------------------ | ----------------------------------------------- | --------------------------------------------- |
| Supabase (Postgres, Auth, Storage, Realtime, Edge Functions) | Everything                                      | Yes                                           |
| OpenAI (GPT-4o-mini, GPT-4o)                                 | Booking extraction, AI planning                 | Yes — in Edge Functions                       |
| Google Places / Maps / Routes                                | Place search, details, directions, photos       | Yes — via `places-cache` + `cached_google.ts` |
| Upstash Redis                                                | Places cache, rate limiting                     | Yes — via `_shared/redis_cache.ts`            |
| SendGrid                                                     | Inbound email parsing (forwards booking emails) | Yes — webhook → `receive-forwarded-email`     |
| Firebase FCM                                                 | Cross-platform push notifications               | Yes — via `send-notification` Edge Function   |

### Frontend Tech Stack (New — Expo React Native)

| Layer              | Technology                                                           |
| ------------------ | -------------------------------------------------------------------- |
| Framework          | Expo SDK 52+ (managed workflow with dev client for native modules)   |
| Language           | TypeScript (strict mode)                                             |
| Routing            | expo-router (file-based, native stack navigation under the hood)     |
| State Management   | Zustand (lightweight, React-native optimized)                        |
| Animations         | react-native-reanimated (UI thread, 60-120fps)                       |
| Bottom Sheets      | @gorhom/bottom-sheet (closest to iOS sheet detents)                  |
| Maps               | react-native-maps (MapKit on iOS, Google Maps on Android)            |
| Backend Client     | @supabase/supabase-js (official JS SDK)                              |
| Icons              | Lucide React Native (consistent cross-platform, replaces SF Symbols) |
| Haptics            | expo-haptics                                                         |
| Image Picker       | expo-image-picker                                                    |
| Clipboard          | expo-clipboard                                                       |
| Push Notifications | expo-notifications (registers FCM token with existing backend)       |
| Secure Storage     | expo-secure-store (session persistence)                              |
| Build & Deploy     | EAS Build + EAS Submit (iOS + Android simultaneously)                |

---

## Data Model — TypeScript Interfaces (Matching Existing Schema)

These interfaces match the deployed Supabase tables exactly. No backend changes needed.

```typescript
// types/database.ts
// ─── Core ────────────────────────────────────────────────
interface Profile {
  id: string;                    // FK → auth.users
  username: string;              // unique
  display_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  default_pin_color: string;     // default '#E53935'
  created_at: string;
  updated_at: string;
}
interface Trip {
  id: string;
  user_id: string;               // FK → profiles
  name: string;
  description: string | null;
  cover_image_url: string | null;
  cover_attribution: string | null;
  start_date: string | null;     // date
  end_date: string | null;
  destination: string;
  destination_place_id: string | null;
  destinations: object | null;   // jsonb — multi-destination
  display_timezone: string | null;
  is_active: boolean;
  privacy: 'private' | 'public';
  status: 'planned' | 'active' | 'completed';
  total_budget: number;
  budget_currency: string;       // default 'USD'
  created_at: string;
  updated_at: string;
}
interface TripDay {
  id: string;
  trip_id: string;               // FK → trips
  user_id: string;
  date: string;                  // date
  label: string | null;
  notes: string | null;
  day_number: number;
  timezone: string | null;
  created_at: string;
  updated_at: string;
}
// ─── Activities (the "places" on timeline) ───────────────
type ActivityCategory =
  'attraction' | 'restaurant' | 'transport' |
  'shopping' | 'nature' | 'nightlife' | 'custom';
type ActivitySource = 'manual' | 'ai_suggestion' | 'search';
type TravelMode = 'driving' | 'walking' | 'transit' | 'bicycling';
interface TripActivity {
  id: string;
  day_id: string;               // FK → trip_days
  trip_id: string;
  user_id: string;
  name: string;
  description: string | null;
  category: ActivityCategory | null;
  starts_at: string | null;     // timestamptz
  duration_minutes: number | null;
  latitude: number | null;
  longitude: number | null;
  address: string | null;
  place_id: string | null;      // Google place_id
  // place_photo_ref: DROPPED — no Google Places photos (use category icons + user photos via trip_activity_attachments)
  rating: number | null;
  price_level: number | null;
  estimated_cost: number | null;
  currency: string | null;
  booking_id: string | null;    // FK → trip_bookings (linked booking)
  source: ActivitySource;
  sort_order: number;
  travel_from_previous_minutes: number | null;
  directions_url: string | null;
  travel_mode: TravelMode;
  created_at: string;
  updated_at: string;
}
// ─── Bookings ────────────────────────────────────────────
type BookingKind =
  'flight' | 'car' | 'lodging' | 'restaurant' | 'train' |
  'bus' | 'ferry' | 'cruise' | 'concert' | 'theater' | 'tour';
type BookingSource = 'manual' | 'upload' | 'email';
interface TripBooking {
  id: string;
  trip_id: string;
  user_id: string;
  kind: BookingKind;
  title: string;
  confirmation_code: string | null;
  provider: string | null;
  starts_at: string | null;
  ends_at: string | null;
  start_location: string | null;
  end_location: string | null;
  start_lat: number | null;
  start_lng: number | null;
  end_lat: number | null;
  end_lng: number | null;
  details_json: Record<string, any>;
  total_price: number | null;
  currency: string;
  source: BookingSource;
  sort_order: number;
  created_at: string;
  updated_at: string;
}
// ─── Email Forwarding ────────────────────────────────────
interface UserForwardingAddress {
  id: string;
  user_id: string;
  trip_id: string;
  address_token: string;        // unique — forms [trips+{token}@domain.com](mailto:trips+{token}@domain.com)
  is_active: boolean;
  created_at: string;
}
type QueueStatus = 'received' | 'pending' | 'processing' |
                   'processed' | 'failed' | 'no_user' | 'needs_assignment';
interface EmailForwardingQueue {
  id: string;
  user_id: string | null;
  trip_id: string | null;
  sender_email: string;
  subject: string | null;
  message_id_hash: string;      // unique
  raw_email_storage_path: string | null;
  extracted_bookings: object | null;
  status: QueueStatus;
  error_message: string | null;
  created_at: string;
  processed_at: string | null;
}
// ─── Notifications ───────────────────────────────────────
interface Notification {
  id: string;
  user_id: string;
  type: string;
  title: string;
  body: string;
  data: Record<string, any>;
  idempotency_key: string | null;
  is_read: boolean;
  created_at: string;
}
interface FcmToken {
  id: string;
  user_id: string;
  token: string;
  platform: 'android' | 'ios';
  created_at: string;
  updated_at: string;
}
```

---

## V1 Feature Set — What We Ship

| #   | Feature               | Description                                                                  | Backend Dependency                                                                |
| --- | --------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1   | Auth (email/password) | Sign in, sign up, session persistence                                        | `auth.users` + `profiles` — exists                                                |
| 2   | Trips List            | Active hero, upcoming scroll, past collapsed, search, sort                   | `trips` — exists                                                                  |
| 3   | Create Trip           | Destination autocomplete, dates, auto-title, auto-generate days              | `trips` + `trip_days` + `places-cache` — exists                                   |
| 4   | Trip Detail Timeline  | Collapsible day sections, activity cards, booking cards, gaps, NOW indicator | `trip_days` + `trip_activities` + `trip_bookings` — exists                        |
| 5   | Add Activity          | Google Places search, wishlist, quick-add, detail form                       | `trip_activities` + `places-cache` — exists                                       |
| 6   | Ideas/Wishlist        | Unscheduled activities (day_number=0), assign to day                         | `trip_activities` where day has day_number=0 — exists                             |
| 7   | Add Booking           | 11 kind-specific forms, auto-day-assignment                                  | `trip_bookings` — exists                                                          |
| 8   | Bookings Screen       | Grouped by kind, email forwarding section, parsed booking review             | `trip_bookings` + `user_forwarding_addresses` + `email_forwarding_queue` — exists |
| 9   | Email Forwarding      | Forward confirmations, AI parses, user reviews                               | `receive-forwarded-email` + `process-forwarded-email` — exists                    |
| 10  | Document Upload       | Upload PDF/screenshot, AI extracts booking                                   | `extract-booking` — exists                                                        |
| 11  | Map View              | Day-colored pins, kind pins, day filter, detail sheet                        | `trip_activities` + `trip_bookings` — exists                                      |
| 12  | Activity Detail       | Name, address, rating from cache, travel times, actions                      | `place_cache` via `places-cache` — exists                                         |
| 13  | Edit Trip             | Title, destination, dates, cover photo                                       | `trips` — exists                                                                  |
| 14  | Profile               | Username, avatar, display_name, bio, sign out                                | `profiles` — exists                                                               |
| 15  | Push Notifications    | Booking parsed, trip tomorrow, parse failed                                  | `send-notification` + `fcm_tokens` — exists                                       |
| 16  | In-App Notifications  | Badge dots, toast overlays, notification history                             | `notifications` — exists                                                          |
| 17  | Dark Mode             | System-aware light/dark theme                                                | Frontend only                                                                     |
| 18  | Drag-and-drop reorder | Reorder activities within a day                                              | `trip_activities.sort_order` — exists                                             |

**Backend work needed for V1: None.** RLS policies, Storage buckets, Edge Functions — all already deployed. Only cleanup task: drop unused Google Places photo columns.

---

## Project Structure (Expo Router — File-Based Routing)

```
wayfind/
├── app/                              ← expo-router file-based routes
│   ├── _layout.tsx                   ← Root layout (auth gate, providers, theme)
│   ├── (auth)/
│   │   ├── _layout.tsx
│   │   ├── sign-in.tsx
│   │   └── sign-up.tsx
│   ├── (tabs)/
│   │   ├── _layout.tsx              ← Tab navigator (Trips, Map, Profile)
│   │   ├── index.tsx                ← Trips List (home)
│   │   ├── world-map.tsx            ← World Map (pins — uses existing pins table)
│   │   └── profile.tsx              ← Profile screen
│   ├── trip/
│   │   ├── [id]/
│   │   │   ├── _layout.tsx
│   │   │   ├── index.tsx            ← Trip Detail (timeline)
│   │   │   ├── map.tsx              ← Trip Map
│   │   │   ├── bookings.tsx         ← Bookings screen
│   │   │   ├── add-activity.tsx     ← Add Activity (modal)
│   │   │   ├── add-booking.tsx      ← Add Booking (modal)
│   │   │   └── edit.tsx             ← Edit Trip (modal)
│   │   └── create.tsx               ← Create Trip (modal)
│   └── notifications.tsx             ← Notification history
├── components/
│   ├── ui/                           ← Design system
│   │   ├── AppButton.tsx
│   │   ├── BottomSheet.tsx           ← @gorhom/bottom-sheet wrapper
│   │   ├── Toast.tsx
│   │   ├── EmptyState.tsx
│   │   ├── Skeleton.tsx
│   │   ├── Chip.tsx
│   │   ├── Badge.tsx
│   │   └── FAB.tsx                   ← Speed Dial FAB
│   ├── trips/
│   │   ├── TripCard.tsx
│   │   ├── ActiveTripHero.tsx
│   │   └── TripListSection.tsx
│   ├── timeline/
│   │   ├── DaySectionHeader.tsx
│   │   ├── ActivityCard.tsx
│   │   ├── BookingCard.tsx
│   │   ├── TimelineRail.tsx
│   │   ├── TimelineGap.tsx
│   │   ├── NowIndicator.tsx
│   │   ├── OngoingBookingBanner.tsx
│   │   └── InlineAddButton.tsx
│   ├── bookings/
│   │   ├── BookingKindChips.tsx      ← 11 booking kinds
│   │   ├── FlightForm.tsx
│   │   ├── LodgingForm.tsx
│   │   ├── RestaurantForm.tsx
│   │   ├── CarForm.tsx
│   │   ├── TrainForm.tsx
│   │   ├── BusForm.tsx
│   │   ├── FerryForm.tsx
│   │   ├── CruiseForm.tsx
│   │   ├── ConcertForm.tsx
│   │   ├── TheaterForm.tsx
│   │   ├── TourForm.tsx
│   │   ├── BookingListCard.tsx
│   │   ├── ForwardingEmailCard.tsx
│   │   └── ParsedBookingCard.tsx
│   ├── map/
│   │   ├── TripMap.tsx
│   │   ├── DayFilterChips.tsx
│   │   └── PinCallout.tsx
│   └── shared/
│       ├── PlaceSearchResults.tsx
│       └── CategoryIcon.tsx
├── stores/                           ← Zustand stores
│   ├── authStore.ts
│   ├── tripsStore.ts
│   ├── tripDetailStore.ts
│   ├── bookingsStore.ts
│   ├── notificationsStore.ts
│   └── themeStore.ts
├── services/
│   ├── supabase.ts                   ← Supabase client singleton
│   ├── placesService.ts              ← Calls places-cache Edge Function
│   ├── bookingService.ts             ← Calls extract-booking Edge Function
│   └── notificationService.ts        ← FCM token registration + handling
├── theme/
│   ├── colors.ts                     ← Warm stone palette (light + dark)
│   ├── typography.ts                 ← System font + Nunito fallback
│   ├── spacing.ts                    ← 4px base unit scale
│   ├── shadows.ts
│   └── bookingKinds.ts               ← Colors + icons for 11 booking kinds
├── utils/
│   ├── dateHelpers.ts
│   ├── haptics.ts                    ← expo-haptics wrapper
│   ├── haversine.ts                  ← Distance calculations
│   └── formatters.ts
├── hooks/
│   ├── useTrips.ts
│   ├── useTripDetail.ts
│   ├── useBookings.ts
│   ├── usePlaceSearch.ts
│   ├── useNotifications.ts
│   └── useColorScheme.ts
├── assets/
│   ├── images/
│   └── fonts/
├── app.json                          ← Expo config
├── eas.json                          ← EAS Build config
├── tsconfig.json
└── package.json
```

---

## Design System (Cross-Platform)

### Colors (Unchanged from UI Spec — Works in React Native)

```typescript
// theme/colors.ts
export const colors = {
  light: {
    background: '#FDF8F0',      // warm cream
    surface: '#FFFFFF',
    primary: '#C26F4B',         // terracotta
    primaryLight: '#F4E8E0',
    secondary: '#2C3E50',
    accent: '#E8A87C',
    textPrimary: '#1A1A1A',
    textSecondary: '#57534E',   // warm stone (WCAG AA ✓)
    textTertiary: '#78716C',    // warm stone light (WCAG AA ✓)
    success: '#059669',
    warning: '#D97706',
    error: '#DC2626',
    divider: '#F3EDE4',
  },
  dark: {
    background: '#0F0F0F',
    surface: '#1A1A1A',
    primary: '#D4845F',
    primaryLight: '#2A1F1A',
    secondary: '#E2E8F0',
    accent: '#E8A87C',
    textPrimary: '#F5F5F5',
    textSecondary: '#D6D3D1',
    textTertiary: '#A8A29E',
    success: '#059669',
    warning: '#D97706',
    error: '#DC2626',
    divider: '#2A2A2A',
  },
};
```

### Booking Kind Colors + Icons (11 Kinds — Matches Existing Schema)

```typescript
// theme/bookingKinds.ts
import { BookingKind } from '../types/database';
export const bookingKindConfig: Record<BookingKind, { color: string; icon: string; label: string }> = {
  flight:     { color: '#3B82F6', icon: 'plane',         label: 'Flight' },
  lodging:    { color: '#A855F7', icon: 'bed-double',    label: 'Hotel' },
  restaurant: { color: '#C26F4B', icon: 'utensils',      label: 'Dining' },
  car:        { color: '#0891B2', icon: 'car',            label: 'Car Rental' },
  train:      { color: '#047857', icon: 'train-front',    label: 'Train' },
  bus:        { color: '#65A30D', icon: 'bus',             label: 'Bus' },
  ferry:      { color: '#0284C7', icon: 'ship',            label: 'Ferry' },
  cruise:     { color: '#7C3AED', icon: 'sailboat',        label: 'Cruise' },
  concert:    { color: '#DB2777', icon: 'music',            label: 'Concert' },
  theater:    { color: '#9333EA', icon: 'drama',            label: 'Theater' },
  tour:       { color: '#CA8A04', icon: 'ticket',           label: 'Tour' },
};
```

### Typography

```typescript
// theme/typography.ts
import { Platform } from 'react-native';
const fontFamily = Platform.select({
  ios: 'System',           // SF Pro on iOS
  android: 'Roboto',       // System font on Android
});
export const typography = {
  screenTitle:   { fontSize: 34, fontWeight: '700' as const, fontFamily },
  sectionHeader: { fontSize: 20, fontWeight: '600' as const, fontFamily },
  cardTitle:     { fontSize: 17, fontWeight: '600' as const, fontFamily },
  body:          { fontSize: 17, fontWeight: '400' as const, fontFamily },
  caption:       { fontSize: 12, fontWeight: '400' as const, fontFamily },
  small:         { fontSize: 11, fontWeight: '500' as const, fontFamily },
  button:        { fontSize: 17, fontWeight: '600' as const, fontFamily },
};
```

---

## Key Architectural Patterns

### Supabase Client

```typescript
// services/supabase.ts
import { createClient } from '@supabase/supabase-js';
import * as SecureStore from 'expo-secure-store';
const supabaseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL!;
const supabaseAnonKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY!;
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    storage: {
      getItem: (key) => SecureStore.getItemAsync(key),
      setItem: (key, value) => SecureStore.setItemAsync(key, value),
      removeItem: (key) => SecureStore.deleteItemAsync(key),
    },
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});
```

### Zustand Store Pattern

```typescript
// stores/tripDetailStore.ts
import { create } from 'zustand';
import { supabase } from '../services/supabase';
import { TripDay, TripActivity, TripBooking } from '../types/database';
interface TripDetailState {
  days: TripDay[];
  activities: Record<string, TripActivity[]>;  // keyed by day_id
  bookings: TripBooking[];
  collapsedDays: Set<string>;
  loading: boolean;
  fetchTripDetail: (tripId: string) => Promise<void>;
  toggleDayCollapse: (dayId: string) => void;
  reorderActivity: (activityId: string, newSortOrder: number) => Promise<void>;
  deleteActivity: (activityId: string) => Promise<void>;
}
export const useTripDetailStore = create<TripDetailState>((set, get) => ({
  days: [],
  activities: {},
  bookings: [],
  collapsedDays: new Set(),
  loading: false,
  fetchTripDetail: async (tripId) => {
    set({ loading: true });
    const [daysRes, activitiesRes, bookingsRes] = await Promise.all([
      supabase.from('trip_days').select('*').eq('trip_id', tripId).order('day_number'),
      supabase.from('trip_activities').select('*').eq('trip_id', tripId).order('sort_order'),
      supabase.from('trip_bookings').select('*').eq('trip_id', tripId).order('sort_order'),
    ]);
    const grouped: Record<string, TripActivity[]> = {};
    (activitiesRes.data ?? []).forEach(a => {
      (grouped[a.day_id] ??= []).push(a);
    });
    set({
      days: daysRes.data ?? [],
      activities: grouped,
      bookings: bookingsRes.data ?? [],
      loading: false,
    });
  },
  toggleDayCollapse: (dayId) => {
    const collapsed = new Set(get().collapsedDays);
    collapsed.has(dayId) ? collapsed.delete(dayId) : collapsed.add(dayId);
    set({ collapsedDays: collapsed });
  },
  reorderActivity: async (activityId, newSortOrder) => {
    await supabase
      .from('trip_activities')
      .update({ sort_order: newSortOrder, updated_at: new Date().toISOString() })
      .eq('id', activityId);
  },
  deleteActivity: async (activityId) => {
    await supabase.from('trip_activities').delete().eq('id', activityId);
  },
}));
```

### Places Search (Uses Existing Edge Function)

```typescript
// services/placesService.ts
import { supabase } from './supabase';
export async function searchPlaces(query: string, lat?: number, lng?: number) {
  const { data, error } = await supabase.functions.invoke('places-cache', {
    body: {
      action: 'text_search',
      query,
      lat,
      lng,
    },
  });
  if (error) throw error;
  return data;
}
export async function getPlaceDetails(placeId: string) {
  const { data, error } = await supabase.functions.invoke('places-cache', {
    body: {
      action: 'details',
      place_id: placeId,
    },
  });
  if (error) throw error;
  return data;
}
export async function getDirections(
  originLat: number, originLng: number,
  destLat: number, destLng: number,
  mode: 'driving' | 'walking' | 'transit' | 'bicycling' = 'driving'
) {
  const { data, error } = await supabase.functions.invoke('places-cache', {
    body: {
      action: 'directions',
      from: { lat: originLat, lng: originLng },
      to: { lat: destLat, lng: destLng },
      mode,
    },
  });
  if (error) throw error;
  return data;
}
```

### FCM Token Registration (Uses Existing send-notification)

```typescript
// services/notificationService.ts
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';
import { supabase } from './supabase';
export async function registerForPush(userId: string) {
  const { status } = await Notifications.requestPermissionsAsync();
  if (status !== 'granted') return;
  const token = (await Notifications.getExpoPushTokenAsync({
    projectId: process.env.EXPO_PUBLIC_PROJECT_ID,
  })).data;
  // Register FCM token in existing fcm_tokens table
  await supabase.from('fcm_tokens').upsert({
    user_id: userId,
    token,
    platform: Platform.OS as 'ios' | 'android',
    updated_at: new Date().toISOString(),
  }, { onConflict: 'user_id,token' });
}
```

---

## 2-Week Sprint Schedule

### Week 1: Core App

| Day   | Focus                | Deliverables                                                                                                                                                                                                                                                                                                                                     |
| ----- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **1** | Project Setup        | Expo init, all npm dependencies, Supabase client, TypeScript interfaces for all 26 tables, theme system (colors, typography, spacing, booking kinds), Lucide icons setup                                                                                                                                                                         |
| **2** | Auth                 | Sign In + Sign Up screens (warm cream design), supabase-js auth (email/password), profile auto-creation, auth gate in root layout, secure session via expo-secure-store                                                                                                                                                                          |
| **3** | Trips List           | Home screen: ActiveTripHero, upcoming horizontal FlatList, past collapsed section (Accordion), search + sort, pull-to-refresh, empty state ("Where to next?"), FAB button                                                                                                                                                                        |
| **4** | Create Trip + Header | Create Trip bottom sheet (destination autocomplete via `places-cache`, date pickers, auto-title "Trip to {destination}", insert trip + auto-generate `trip_days`). Trip Detail header (cover photo with parallax via Reanimated, status pill, pills row: Map + Bookings active)                                                                  |
| **5** | Timeline Core        | ScrollView with `SectionList`-style day sections. `DaySectionHeader` (day-color bar, collapse/expand with Reanimated, chevron rotation). `ActivityCard` (category icon, name, time, address). `BookingCard` (kind-colored left border, kind icon, title, details, confirmation badge). `TimelineGap` (travel time between items). `NowIndicator` |

### Week 2: Features + Polish

| Day    | Focus                         | Deliverables                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------ | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **6**  | Timeline Interaction          | Collapse/expand animation. Swipe-to-delete with undo toast. Ideas/wishlist section (activities with day_number=0 day). `InlineAddButton`. Speed Dial FAB (Add Activity, Add Booking). `OngoingBookingBanner` (multi-day lodging/car)                                                                                                                                                                                                       |
| **7**  | Add Activity + Add Booking    | Add Activity bottom sheet: Google Places search via `places-cache`, wishlist section, quick-add (tap) + detail form (category, time, notes). Add Booking screen: horizontal chip selector for 11 kinds, kind-specific forms (Flight/Lodging/Restaurant/Car/Train/Bus/Ferry/Cruise/Concert/Theater/Tour), auto-day-assignment from dates                                                                                                    |
| **8**  | Bookings Screen + Email       | Bookings screen: grouped by kind (11 sections). ForwardingEmailCard (copy `trips+{token}@domain` via expo-clipboard). Parsed booking review (email_forwarding_queue: show pending/processing/processed/failed items, "Add to Trip" action). Document upload (expo-image-picker → Supabase Storage → `extract-booking` Edge Function)                                                                                                       |
| **9**  | Map + Activity Detail         | Trip Map (react-native-maps): day-colored circle markers for activities, kind-colored markers for bookings, day filter chips, marker tap → detail bottom sheet, auto-fit region. Activity detail sheet: name, address, rating/price from place_cache, travel times (Haversine), Navigate (open platform maps app), Edit, Delete                                                                                                            |
| **10** | Edit Trip + Profile           | Edit Trip modal (title, destination, dates with cascade, cover photo upload via expo-image-picker → Supabase Storage). Profile screen (from `profiles` table: username, display_name, avatar, bio, edit profile, sign out). User stats display (from `user_stats` table: countries visited, total trips, distance). Activity attachments — view/add photos per activity from `trip_activity_attachments`                                   |
| **11** | Notifications + Photo Cleanup | FCM token registration on login `fcm_tokens` table). Push notification handling (booking parsed, trip tomorrow) via `expo-notifications`. In-app notification list (from `notifications` table), badge dot on bell icon, mark-as-read, swipe-to-dismiss. Backend cleanup: `ALTER TABLE trip_activities DROP COLUMN place_photo_ref; ALTER TABLE place_cache DROP COLUMN photo_reference;` — removes unused Google Places photo references |
| **12** | Dark Mode + Polish            | Dark mode (useColorScheme + theme tokens swap). Haptic feedback (expo-haptics) on all taps, toggles, deletes. Skeleton loading states. Error handling (network errors, Supabase errors, empty responses). Toast overlay system                                                                                                                                                                                                             |
| **13** | Testing                       | iOS Simulator + Android Emulator + physical devices. Edge cases: empty states (no trips, no activities, no bookings), offline behavior, long text truncation, many activities per day, many bookings. Performance profiling on older devices                                                                                                                                                                                               |
| **14** | Ship                          | App icons (expo-splash-screen config). Splash screen. EAS Build (iOS + Android). TestFlight + Google Play Internal Testing. App Store Connect + Google Play Console metadata (descriptions, screenshots, keywords). Submit both platforms simultaneously                                                                                                                                                                                   |

---

## RLS Policies — Already Deployed

RLS policies are already in place for all tables. No security work needed for V1. The existing policies handle:

- **User isolation**: users can only access their own data (profiles, trips, activities, bookings, etc.)

- **Collaborator access**: accepted collaborators can view/edit shared trip data based on their role

- **Public trips**: trips with `privacy = 'public'` are readable by anyone

- **Shared cache**: `place_cache` is public read (no user-specific data)

- **Service role access**: Edge Functions use service role key for cross-user operations (email processing, notifications)

## Google Places Photos — Not Used (Cleanup)

**Decision made early: No Google Places photos in the app.** Timeline cards use Lucide category icons (star, utensils, train-front, etc.) and user-uploaded photos via `trip_activity_attachments`. This saves significant API cost (Place Photos SKU: $7/1K calls) and avoids photo licensing complexity.

**Cleanup migration (Day 11):**

```sql
-- Drop unused photo columns
ALTER TABLE trip_activities DROP COLUMN IF EXISTS place_photo_ref;
ALTER TABLE place_cache DROP COLUMN IF EXISTS photo_reference;
```

**Frontend:** Do not call `places-cache` Edge Function with `action: 'photo'` or `action: 'batch_photos'`. These actions exist in the Edge Function but are unused.

**Edge Function cleanup (optional, low priority):** The `photo` and `batch_photos` actions in `places-cache/index.ts` and the photo pipeline in `_shared/cached_google.ts` (which uploads to `place-photos` Storage bucket) can be removed in a future cleanup. Not blocking for V1.

---

## What's Different From the Original Plans

| Original Plan Said                    | Actual Reality                                                                                         | Impact                                          |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------- |
| Build with Swift/SwiftUI              | Building with Expo React Native                                                                        | All frontend changes, backend unchanged         |
| 6 booking types                       | 11 booking kinds (flight, car, lodging, restaurant, train, bus, ferry, cruise, concert, theater, tour) | More kind-specific forms, richer booking cards  |
| `places` table                        | `trip_activities` table (richer model with travel legs, directions, booking link)                      | Use actual field names and relationships        |
| Mailgun for email                     | SendGrid inbound → `receive-forwarded-email`                                                           | Already deployed, no email service setup needed |
| APNs for push                         | FCM via `send-notification` + `fcm_tokens`                                                             | Cross-platform push — perfect for Expo          |
| Build AI planner from scratch         | `itinerary-ai` Edge Function already built                                                             | V2b just needs frontend UI, backend exists      |
| Build Places cache from scratch       | `places-cache` Edge Function + `place_cache` table + Redis                                             | Already deployed, just call it                  |
| Build email parser from scratch       | `process-forwarded-email` + `extract-booking` already working                                          | Already deployed, just show results             |
| No user profiles                      | `profiles` table with username, avatar, bio                                                            | Display profile data, edit flow                 |
| No collaboration                      | `trip_collaborators` with roles already built                                                          | V1: read-only awareness. V2+: full collab UI    |
| Simple checklist                      | `trip_checklists` → `checklist_items` (two-level)                                                      | V2: use two-level hierarchy                     |
| Simple expenses                       | `trip_expenses` + `expense_splits`                                                                     | V2: use split functionality                     |
| Build RLS policies                    | RLS policies already deployed on all tables                                                            | No security work needed — already done          |
| Supabase Realtime for parsed bookings | Supabase Realtime subscription on `email_forwarding_queue`                                             | Subscribe to status changes for live updates    |

---

## V1 Success Metrics

| Metric                                                              | Target                    |
| ------------------------------------------------------------------- | ------------------------- |
| App Store + Play Store launch                                       | Both platforms, same week |
| Trips created per user (first week)                                 | 1.5+                      |
| Activities added per trip                                           | 10+                       |
| Bookings added per trip                                             | 2+                        |
| Email forwarding adoption (% of users who forward at least 1 email) | 15%+                      |
| Day 7 retention                                                     | 30%+                      |
| App Store rating                                                    | 4.3+ stars                |
| Crash-free rate                                                     | 99.5%+                    |

