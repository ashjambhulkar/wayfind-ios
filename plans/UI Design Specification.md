# Travel Planner — UI Design Specification

> **Overview:** Complete UI/UX design specification for native iOS (Swift/SwiftUI) with senior design review findings applied. Key corrections: WCAG-compliant contrast ratios (warm stone grays replacing cool grays), cover photo reduced 220px→160px with full scroll collapse via GeometryReader, tab bar removed (Profile behind nav avatar), booking dots use diamond shape to avoid day-color collision, Place Detail action hierarchy (primary/secondary/tertiary), keyboard handling for forms, two-line collapsed day headers, SF Pro Rounded typography (native iOS — no cross-platform concern), booking type selector changed from 2x3 grid to horizontal chips, FAB safe area insets via safeAreaInset, gradient pairs reduced to 4 for V1, form error states and sub-screen empty states added."

## Implementation checklist

- [ ] **design-system-impl** — Implement design system: WCAG-compliant warm stone color palette (light+dark via Asset Catalog + Color extension), typography scale (SF Pro Rounded — native iOS), spacing constants, corner radii, shadow presets, category SF Symbols, booking type colors (offset from day colors) with diamond dot shapes, 4 gradient placeholder pairs — all in Theme/ folder (AppColors.swift, AppTypography.swift, AppSpacing.swift, BookingTypeConstants.swift)
- [ ] **core-components** — Build reusable SwiftUI components: AppButton (primary/outline/destructive/text), ToastView (undo variant), EmptyStateView (for all screens: Trips, Map, Bookings, Ideas), PlaceholderGradientView (4 gradient pairs), SkeletonView (shimmer via .redacted + custom modifier), SpeedDialFABView (with safeAreaInset), PillButtonView (active/disabled/badge)
- [ ] **auth-screens** — Build SignInView + SignUpView: warm cream bg, centered logo, stacked TextField/SecureField (48pt rounded-medium), terracotta CTA, Sign in with Apple + Google buttons, footer NavigationLink toggle
- [ ] **trips-list-screen** — Build TripsListView: .navigationTitle with avatar button in .toolbar (no tab bar), warm search bar (.searchable), hero ActiveTripHeroView (photo/gradient, status pill, 180pt), horizontal ScrollView UpcomingTripCards (160x200pt), DisclosureGroup PastTrips section, terracotta FAB (safeAreaInset aware), empty state
- [ ] **create-trip-sheet** — Build CreateTripView as .sheet(.presentationDetents([.medium, .large])): drag indicator, destination search with autocomplete rows, side-by-side DatePickers, terracotta 'Start Planning' CTA, auto-title logic
- [ ] **timeline-screen** — Build TripDetailView timeline: cover photo header (160pt, full collapse on scroll via GeometryReader, gradient overlay, status pill), pills row, ScrollView + LazyVStack with .pinnedViews([.sectionHeaders]) DaySectionHeaderViews (day-color bar, two-line collapsed format, collapse/expand with withAnimation(.spring), chevron), TimelineRailView (2pt line + circle dots for places + diamond dots for bookings), TimelinePlaceCardView, TimelineBookingCardView (colored leading overlay border), TimelineGapView (mode estimates), NowIndicatorView, OngoingBookingBannerView, InlineAddButtonView, Ideas section, SpeedDialFABView (safeAreaInset aware)
- [ ] **add-place-sheet** — Build AddPlaceView as .sheet: Picker day selector, TextField search bar, wishlist section with + buttons, search results, quick-add (tap) and detailed-add (.contextMenu / long-press)
- [ ] **add-booking-screen** — Build AddBookingView: horizontal ScrollView chip type selector (replaces 2x3 grid), 6 type-specific SwiftUI Form views with grouped inputs, optional DisclosureGroup section, sticky CTA via .safeAreaInset(edge: .bottom), inline validation errors (red border + text), auto-day-assignment
- [ ] **bookings-screen** — Build BookingsScreenView: type-grouped List with Section views and colored section bars, booking cards with conf badges, email forwarding card (Primary Light bg, monospace .font(.system(.body, design: .monospaced)) email, UIPasteboard copy button), parsed bookings review
- [ ] **map-screen** — Build TripMapView: full-screen MapKit Map, day-colored circle MapAnnotations (numbered) + booking-type diamond annotations, floating day filter chips (.ultraThinMaterial bg), MKPolyline route overlay, annotation-tap .sheet, auto-fit MKCoordinateRegion, empty state for 0 places
- [ ] **place-detail-sheet** — Build Place Detail .sheet: name/address, info chips (hours, rating from cache), editorial summary, Haversine travel times (4 modes), action button hierarchy (Navigate=primary full-width, Edit+Move=secondary outline, Delete=text link or .contextMenu overflow)
- [ ] **profile-screen** — Build ProfileView as pushed NavigationLink (no tab bar): avatar with initials, grouped Form settings cells (sort Picker, appearance Picker), sign out button (.role(.destructive)), version/legal NavigationLinks. Accessed via avatar button in TripsListView .toolbar. No forwarding email here — forwarding emails are per-trip.
- [ ] **dark-mode** — Verify all views in dark mode: swap cream→near-black via Asset Catalog color sets, white cards→dark cards, ensure text contrast, booking colors readable on dark bg, gradient placeholders adapt via @Environment(\.colorScheme)
- [ ] **forwarding-touchpoints** — Implement email forwarding discovery: contextual banner below pills (0 bookings, dismissible, UIPasteboard copy), Speed Dial footer tip (<3 bookings), InlineAddButton secondary hint (0 bookings on day), Bookings pill pulse dot (0 bookings), success celebration toast (first forward parsed), smart dismiss logic in @Observable UIState
- [ ] **animations** — Implement full animation system using SwiftUI native animations: feedback animations (button .scaleEffect, copy flash, save checkmark), state change animations (card enter/exit with .transition, reorder with withAnimation(.spring)), navigation animations (.sheet spring, FAB fan-out stagger with .animation(.spring.delay()), NavigationStack transitions), attention animations (NOW pulse via .animation(.easeInOut.repeatForever()), pill dot pulse, ScrollViewReader auto-scroll), delight animations (GeometryReader parallax header, success confetti). All paired with UIImpactFeedbackGenerator/UINotificationFeedbackGenerator. Respect UIAccessibility.isReduceMotionEnabled.

---

## Design Philosophy

**This is a travel companion, not a spreadsheet.**

When a user opens this app, they should feel the same excitement they feel when packing for a trip. Every screen should remind them they're planning an adventure. The UI should be warm, spacious, and photo-forward — never data-dense, never gray, never corporate.

**Five feelings the app should evoke:**

1. **Excitement** — "I can't wait for this trip"

2. **Confidence** — "Everything is organized, I'm ready"

3. **Simplicity** — "This is so easy to use"

4. **Beauty** — "This app looks as good as the places I'm going"

5. **Control** — "I can see my whole trip at a glance"

**Anti-patterns to avoid:**

- No data tables. Ever. This is not Excel.

- No gray backgrounds everywhere. Warm cream, not cold gray.

- No tiny text crammed together. Generous spacing.

- No icon-only buttons without labels. New users get lost.

- No settings pages disguised as features.

- No loading spinners in the center of empty screens. Use skeletons.

---

## Design System

### Color Palette

Warm earth tones inspired by terracotta rooftops, sandy beaches, and golden sunsets.

**Core Colors (Light Mode):**

```
  Background:     #FDF8F0  (warm cream — like aged paper)
  Surface:        #FFFFFF  (pure white cards)
  Primary:        #C26F4B  (terracotta — warm, adventurous)
  Primary Light:  #F4E8E0  (terracotta at 10% — subtle backgrounds)
  Secondary:      #2C3E50  (deep slate — readable, not harsh)
  Accent:         #E8A87C  (warm peach — highlights, badges)
  Text Primary:   #1A1A1A  (near-black, not pure black)
  Text Secondary: #57534E  (warm stone — 6.1:1 on cream ✓ WCAG AA)
  Text Tertiary:  #78716C  (warm stone light — 4.6:1 on cream ✓ WCAG AA)
  Success:        #059669  (emerald green)
  Warning:        #D97706  (amber)
  Error:          #DC2626  (red)
  Divider:        #F3EDE4  (warm separator, barely visible)
```

> **UX Review correction:** Original TextSecondary (#6B7280, 4.0:1) and TextTertiary (#9CA3AF, 2.9:1) were cool blue-grays that failed WCAG AA contrast on the warm cream background. Replaced with warm stone tones from Tailwind's `stone` scale. These match the warm cream undertone AND meet accessibility requirements.

**Core Colors (Dark Mode):**

```
  Background:     #0F0F0F  (near-black, warm undertone)
  Surface:        #1A1A1A  (dark card)
  Primary:        #D4845F  (lighter terracotta for dark bg)
  Primary Light:  #2A1F1A  (terracotta at 10%)
  Secondary:      #E2E8F0  (light slate)
  Accent:         #E8A87C  (same peach)
  Text Primary:   #F5F5F5  (off-white)
  Text Secondary: #D6D3D1  (warm stone — 10.1:1 on dark surface ✓)
  Text Tertiary:  #A8A29E  (warm stone muted — 5.2:1 on dark surface ✓)
```

**Day Colors** (used for timeline rail dots, map pins, day chips):

```
  Day 1:  #4A90D9  (sky blue)
  Day 2:  #D4845F  (terracotta)
  Day 3:  #059669  (emerald)
  Day 4:  #D97706  (amber)
  Day 5:  #8B5CF6  (violet)
  Day 6:  #EC4899  (rose)
  Day 7:  #06B6D4  (cyan)
  Day 8+: cycles from Day 1
```

**Booking Type Colors** (left border on booking cards + diamond dots on timeline rail):

> **UX Review correction:** Original booking colors were identical to day colors (Flight blue = Day 1 blue, Hotel violet = Day 5 violet), creating ambiguity on the timeline rail. Offset palette below ensures no exact matches. Additionally, booking dots use **diamond shape** (◆) while place dots use **circle shape** (●) for shape-based differentiation that works for color-blind users.

```
  Flight:      #3B82F6  (blue — offset from Day 1 #4A90D9)
  Hotel:       #A855F7  (violet — offset from Day 5 #8B5CF6)
  Restaurant:  #C26F4B  (terracotta — unique, no day overlap)
  Car Rental:  #0891B2  (teal — offset from Day 7 #06B6D4)
  Activity:    #CA8A04  (gold — offset from Day 4 #D97706)
  Transport:   #047857  (green — offset from Day 3 #059669)
```

### Typography

Using SF Pro Rounded — the native iOS rounded system font. Since we are building exclusively for iOS, SF Pro Rounded is available system-wide with zero bundle cost. Its rounded terminals add warmth that complements the terracotta color palette and travel photography.

> **iOS-native advantage:** SF Pro Rounded is a built-in iOS system font with full Dynamic Type support, all weights, and zero additional bundle size. This was previously dropped for cross-platform consistency with Android/Roboto — that constraint no longer applies with a native iOS build.

```
  Screen Title:     .largeTitle   Rounded  Bold     (trip name, "My Trips")          ~34pt
  Section Header:   .title3       Rounded  SemiBold (day headers, section titles)     ~20pt
  Card Title:       .headline     Rounded  SemiBold (place names, booking names)      ~17pt
  Body:             .body         Rounded  Regular  (addresses, descriptions)          ~17pt
  Caption:          .caption      Rounded  Regular  (times, metadata)                  ~12pt
  Small:            .caption2     Rounded  Medium   (badges, labels)                   ~11pt
  Button:           .headline     Rounded  SemiBold (CTAs)                             ~17pt
```

Implementation via SwiftUI:

```swift
// Theme/AppTypography.swift
extension Font {
    static let screenTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let sectionHeader = Font.system(.title3, design: .rounded).weight(.semibold)
    static let cardTitle = Font.system(.headline, design: .rounded)
    static let appBody = Font.system(.body, design: .rounded)
    static let appCaption = Font.system(.caption, design: .rounded)
    static let appSmall = Font.system(.caption2, design: .rounded).weight(.medium)
    static let appButton = Font.system(.headline, design: .rounded)
}
```

All text automatically supports Dynamic Type via SwiftUI's built-in text style scaling. Views use flexible height (never fixed frames) to accommodate larger text sizes. Truncation only with `.lineLimit` + "Read more" affordance, never silent clipping.

### Spacing Scale

Base unit: 4px. Everything is a multiple.

```
  xs:   4px    (icon padding, tiny gaps)
  sm:   8px    (between inline elements)
  md:   12px   (card internal padding)
  lg:   16px   (between cards, section margins)
  xl:   24px   (between sections)
  2xl:  32px   (screen edge padding)
  3xl:  48px   (major section gaps)
```

### Corner Radii

```
  Small:   8px   (buttons, chips, badges)
  Medium:  12px  (place cards, input fields)
  Large:   16px  (trip cards, bottom sheets)
  XLarge:  24px  (cover photo overlays, hero cards)
  Full:    9999  (pills, avatar circles)
```

### Shadows

```
  Subtle:  0 1px 3px rgba(0,0,0,0.06)   (cards at rest)
  Medium:  0 4px 12px rgba(0,0,0,0.08)  (elevated cards, FAB)
  Strong:  0 8px 24px rgba(0,0,0,0.12)  (dragged items, bottom sheets)
```

### Category Icons (SF Symbols)

```
  Attraction:   star.fill                ⭐
  Restaurant:   fork.knife               🍴
  Hotel:        bed.double.fill          🏨
  Transport:    car.fill                 🚗
  Shopping:     bag.fill                 🛍️
  Nightlife:    wineglass.fill           🍷
  Nature:       leaf.fill                🌿
  Custom:       mappin.and.ellipse       📍
  Flight:       airplane                 ✈️
  Train:        tram.fill                🚆
  Activity:     ticket.fill              🎟️
```

SF Symbols are native to iOS, scale automatically with Dynamic Type, support all rendering modes (monochrome, hierarchical, palette, multicolor), and require zero asset bundling.

---

## Screen-by-Screen Design

### Screen 0: Splash Screen

The first impression. 1-2 seconds.

```
  ┌─────────────────────────────────┐
  │                                 │
  │                                 │
  │                                 │
  │                                 │
  │                                 │
  │           [App Logo]            │
  │                                 │
  │          TripWeave              │  ← Or your app name
  │                                 │  ← Clean, centered
  │                                 │
  │                                 │
  │                                 │
  │                                 │
  │                                 │
  └─────────────────────────────────┘
  Background: warm cream (#FDF8F0)
  Logo: terracotta color
  Text: secondary color, light weight
```

No loading spinner. No progress bar. Just the brand, warm and confident.

---

### Screen 1: Sign In

**Emotion: "Welcome back, traveler."**

```
  ┌─────────────────────────────────┐
  │                                 │
  │                                 │
  │           [App Logo]            │
  │                                 │
  │      Welcome back               │  ← 28px, SemiBold
  │      Sign in to continue        │  ← 15px, TextSecondary
  │          planning               │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  📧  Email                 │  │  ← Rounded input, 48px height
  │  └───────────────────────────┘  │
  │                                 │  ← 12px gap
  │  ┌───────────────────────────┐  │
  │  │  🔒  Password              │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │       Sign In              │  │  ← Terracotta bg, white text
  │  └───────────────────────────┘  │     Full-width, 52px height
  │                                 │     rounded-lg (16px)
  │  ────────── or ──────────       │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  [G]  Continue with Google │  │  ← White bg, border, 48px
  │  └───────────────────────────┘  │
  │  ┌───────────────────────────┐  │
  │  │  []  Continue with Apple  │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  Don't have an account? Sign up │  ← 15px, terracotta "Sign up"
  │                                 │
  └─────────────────────────────────┘
  Background: warm cream (#FDF8F0)
  All inputs: white bg, 1px #F3EDE4 border,
  rounded-medium (12px), 48px height
```

NOT a full-screen travel photo behind a glassmorphism card. That's overused and makes text hard to read. Clean, warm, simple. The app itself is the experience — the login is just the door.

---

### Screen 1b: Sign Up

Same layout as Sign In but with:

- "Create your account" / "Start planning adventures"

- Name field added above email

- "Already have an account? Sign in"

---

### Screen 2: Trips List (Home) — Empty State

**Emotion: "Your next adventure starts here."**

```
  ┌─────────────────────────────────┐
  │ My Trips                  [AJ]  │  ← Large title (32px, Bold)
  │                                 │     [AJ] = avatar circle (28px)
  ├─────────────────────────────────┤     terracotta bg, white initials
  │                                 │     Tap → pushes to Profile screen
  │                                 │
  │                                 │
  │                                 │
  │        ┌───────────────┐        │
  │        │               │        │
  │        │  🌍 ✈️         │        │  ← Simple illustration
  │        │               │        │     (not clipart, tasteful)
  │        └───────────────┘        │
  │                                 │
  │     Where to next?              │  ← 24px, SemiBold, centered
  │                                 │
  │     Plan your first trip and    │  ← 15px, TextSecondary
  │     keep everything in          │     centered, max 260px width
  │     one place.                  │
  │                                 │
  │     ┌──────────────────────┐    │
  │     │  + Plan a Trip        │    │  ← Terracotta bg, white text
  │     └──────────────────────┘    │     48px height, rounded-lg
  │                                 │
  │                                 │
  └─────────────────────────────────┘
```

> **UX Review correction:** Two-tab tab bar (Home + Profile) removed. Apple HIG recommends 3-5 tabs; a two-tab bar wastes 83px of screen for a binary toggle. Profile is now accessed via the avatar circle in the nav bar (same pattern as Apple Maps). This reclaims 83px on every screen — particularly valuable on the Trip Detail timeline where content density matters most.

---

### Screen 2b: Trips List — With Trips

**Emotion: "Look at all these adventures!"**

```
  ┌─────────────────────────────────┐
  │ My Trips                  [AJ]  │  ← Large title + avatar circle
  │ ┌───────────────────────────┐   │
  │ │ 🔍  Search trips...        │   │  ← Search bar, rounded-full
  │ └───────────────────────────┘   │     warm cream bg, not white
  ├─────────────────────────────────┤
  │                                 │
  │  YOUR CURRENT TRIP              │  ← 11px, uppercase, TextTertiary
  │                                 │     tracking-wider (letter spacing)
  │  ┌───────────────────────────┐  │
  │  │                           │  │
  │  │  🖼️🖼️🖼️🖼️🖼️🖼️🖼️🖼️🖼️🖼️  │  │  ← Destination photo (Unsplash)
  │  │                           │  │     Full-width, 180px height
  │  │                           │  │     rounded-xl (24px)
  │  │  ┌─────────────────────┐  │  │
  │  │  │ Day 3 of 7          │  │  │  ← Pill badge, white bg
  │  │  └─────────────────────┘  │  │     positioned bottom-left
  │  │                           │  │     over gradient overlay
  │  │  Trip to Paris 🇫🇷         │  │  ← 24px Bold, white text
  │  │  Mar 12-18               │  │  ← 15px, white/80%
  │  │                           │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  UPCOMING                       │  ← Section header
  │                                 │
  │  ┌────────────┐ ┌────────────┐  │  ← Horizontal scroll
  │  │ 🖼️          │ │ 🖼️          │  │     of trip cards
  │  │            │ │            │  │     160px wide, 200px tall
  │  │ Tokyo 🇯🇵   │ │ Barcelona  │  │     rounded-large (16px)
  │  │ Apr 2-9    │ │ May 15-22  │  │
  │  │ In 12 days │ │ In 44 days │  │  ← Terracotta text
  │  │ 8 places   │ │ 3 places   │  │  ← TextTertiary
  │  └────────────┘ └────────────┘  │
  │                                 │
  │  PAST TRIPS                  ▼  │  ← Collapsed by default
  │                                 │     tap to expand
  │                                 │
  │                           ┌───┐ │
  │                           │ + │ │  ← Terracotta FAB
  │                           └───┘ │     56px, rounded-full
  │                                 │     shadow-medium
  └─────────────────────────────────┘     16px above safe area bottom
```

**Key design decisions:**

- Current trip is a HERO card — big, prominent, photo-forward. This is the most important thing on the screen.

- Upcoming trips are a HORIZONTAL SCROLL of smaller cards — feels like browsing a travel magazine, not a database list. Each card has a destination photo.

- Past trips are COLLAPSED — they're memories, not actionable. Expand to see.

- FAB is terracotta colored, not the default blue. Feels warm, inviting.

- Section labels are small uppercase with letter-spacing — a design detail that feels premium.

- Search bar uses warm cream background, not cold gray.

**Trip Card (Upcoming — 160x200px):**

```
  ┌────────────────┐
  │                │
  │  🖼️ Destination │  ← Unsplash photo, rounded-lg
  │  photo         │     covers top 60%
  │                │
  ├────────────────┤
  │ Tokyo 🇯🇵       │  ← 17px SemiBold
  │ Apr 2-9        │  ← 13px TextSecondary
  │ In 12 days     │  ← 13px Terracotta
  │ 8 places       │  ← 11px TextTertiary
  └────────────────┘
  Background: white, shadow-subtle
  Corner radius: 16px
  Padding: 12px (text area)
```

**When no destination photo**: Show a warm gradient generated from the destination name hash. Not a gray placeholder — a BEAUTIFUL gradient.

> **UX Review correction:** Reduced from 8 to 4 pairs for V1 scope. 4 is visually distinct enough; most users upload cover photos within days. Add more in V2 if needed.

```
  Gradient pairs (based on name hash % 4):
  1. #C26F4B → #E8A87C  (terracotta sunset)
  2. #4A90D9 → #93C5FD  (ocean blue)
  3. #059669 → #6EE7B7  (forest green)
  4. #D97706 → #FCD34D  (golden hour)
```

---

### Screen 3: Create Trip (Bottom Sheet)

**Emotion: "Starting a new adventure is effortless."**

NOT a full-screen modal. A bottom sheet that slides up — feels lightweight, not committal.

```
  ┌─────────────────────────────────┐
  │                                 │  ← Dimmed background
  │         (Trips List behind)     │     (scrim, 40% black)
  │                                 │
  │                                 │
  │                                 │
  ├─────────────────────────────────┤  ← Bottom sheet starts here
  │  ─── ───                        │  ← Drag handle (centered, 36px wide)
  │                                 │
  │  Plan a New Trip                │  ← 24px SemiBold
  │                                 │
  │  Where are you going?           │  ← 13px TextSecondary (label)
  │  ┌───────────────────────────┐  │
  │  │  🔍  Search destination    │  │  ← 48px, rounded-medium
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │  ← Autocomplete results
  │  │  📍 Paris, France          │  │     appear below as clean rows
  │  │  📍 Paris, Texas, USA      │  │     16px padding each
  │  │  📍 Paris, Ontario, Canada │  │     Dividers between
  │  └───────────────────────────┘  │
  │                                 │
  │  When?                          │  ← 13px TextSecondary
  │  ┌────────────┐ ┌────────────┐  │
  │  │ 📅 Start    │ │ 📅 End      │  │  ← Two date pickers
  │  │ Mar 12     │ │ Mar 18     │  │     side by side
  │  └────────────┘ └────────────┘  │     each 48px, rounded-medium
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │     Start Planning  →     │  │  ← Terracotta, white text
  │  └───────────────────────────┘  │     52px, rounded-lg, full-width
  │                                 │     Disabled until destination
  │                                 │     + dates filled
  └─────────────────────────────────┘
```

Only 2 inputs. Title auto-generates ("Trip to Paris"). Cover photo auto-fetches from Unsplash. Everything else can be added later from the trip detail.

---

### Screen 4: Trip Detail — The Timeline

**THE most important screen. This is where travelers live.**

**Emotion: "My whole trip, beautifully organized."**

```
  ┌─────────────────────────────────┐
  │ [←]            Trip to Paris    │  ← Nav bar (when header collapsed)
  ├─────────────────────────────────┤
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ 🖼️🖼️🖼️🖼️🖼️🖼️🖼️🖼️🖼️🖼️   │  │  ← Cover photo, 160px (was 220px)
  │  │                           │  │     Unsplash destination image
  │  │  Trip to Paris 🇫🇷         │  │     bottom gradient overlay
  │  │  Mar 12-18                │  │     (transparent → black 60%)
  │  │  ┌──────────────────┐     │  │  ← 24px Bold, white
  │  │  │ ✈️ Day 3 of 7     │     │  │  ← 13px white/80%
  │  │  └──────────────────┘     │  │  ← Status pill, white bg/90%
  │  └───────────────────────────┘  │
  Cover photo scroll behavior:
  - Fully collapses to 0px on scroll (not just behind nav bar)
  - Nav bar shows: [←] Trip to Paris 🇫🇷 [Day 3 of 7]
  - Parallax at 0.3x scroll speed during collapse
  - Saves 160px+ of content space when user is working
  │                                 │
  │  ┌──────┐ ┌──────┐ ┌──────┐    │  ← Quick-access pills
  │  │🗺️ Map│ │✈️ 4  │ │📎 2  │    │     Horizontal scroll
  │  └──────┘ │Trips │ │Files │    │     White bg, shadow-subtle
  │           └──────┘ └──────┘    │     rounded-full, 36px height
  │                                 │
  │  ┌─────────────────────────────┐│
  │  │ ▼  Day 1 — Sat, Mar 12     ││  ← STICKY HEADER
  │  │    3 items                  ││     when scrolled, gets
  │  └─────────────────────────────┘│     cream bg + subtle border-b
  │                                 │     Day-color left bar (4px)
  │  │                              │
  │  │  6:30 AM                     │  ← Caption, TextTertiary
  │  ●─┐                            │  ← Blue dot on rail (flight)
  │  │ ┌────────────────────────┐   │
  │  │ │ ✈️                      │   │  ← Booking card
  │  │ │ AA 1234                 │   │     Blue left border (4px)
  │  │ │ JFK → CDG               │   │     Card title: 17px SemiBold
  │  │ │ 6:30 AM → 8:45 PM      │   │     Details: 13px TextSecondary
  │  │ │ Conf: XKRF4Q            │   │     Conf: 11px, terracotta bg
  │  │ └────────────────────────┘   │       rounded pill badge
  │  │                              │
  │  │  🚶 ~20 min                  │  ← TimelineGap, 13px
  │  │                              │     TextTertiary, centered on rail
  │  │  9:30 PM                     │
  │  ●─┐                            │  ← Violet dot (hotel)
  │  │ ┌────────────────────────┐   │
  │  │ │ 🏨                      │   │  ← Hotel booking card
  │  │ │ Le Marais Hotel         │   │     Violet left border
  │  │ │ Check-in 9:30 PM       │   │
  │  │ │ 5 nights                │   │
  │  │ │ Conf: HBK-992841       │   │
  │  │ └────────────────────────┘   │
  │  │                              │
  │  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐   │
  │  │  ╎  + Add to Day 1       ╎   │  ← InlineAddButton
  │  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘   │     Dashed border, 13px
  │  │                              │     TextTertiary, 40px height
  │  ┌─────────────────────────────┐│     rounded-medium
  │  │ ▼  Day 2 — Sun, Mar 13     ││
  │  │    4 items                  ││  ← Next day header
  │  └─────────────────────────────┘│
  │                                 │
  │  │  🏨 Staying at Le Marais     │  ← OngoingBookingBanner
  │  │     Hotel                    │     13px, TextSecondary
  │  │                              │     Primary Light bg (#F4E8E0)
  │  │  9:00 AM                     │     rounded-sm (8px), 36px
  │  ●─┐                            │
  │  │ ┌────────────────────────┐   │
  │  │ │ ⭐ Eiffel Tower         │   │  ← Place card (not a booking)
  │  │ │   Champ de Mars, Paris  │   │     No colored left border
  │  │ │   9:00 AM - 11:30 AM   │   │     Category icon dot
  │  │ └────────────────────────┘   │     on the timeline rail
  │  │                              │
  │  │  🚶 15 min · 🚗 4 min       │  ← Gap with mode estimates
  │  │                              │
  │  │  12:15 PM                    │
  │  ●─┐                            │
  │  │ ┌────────────────────────┐   │
  │  │ │ 🍴 Le Petit Cler        │   │
  │  │ │   25 Rue Cler, Paris    │   │
  │  │ │   12:15 PM - 1:30 PM   │   │
  │  │ └────────────────────────┘   │
  │  │                              │
  │  ...                            │
  │                                 │
  │  ┌─────────────────────────────┐│
  │  │ 💡 Ideas                    ││  ← Ideas/Wishlist section
  │  │    2 saved places           ││     at the bottom
  │  └─────────────────────────────┘│
  │  │                              │
  │  │ ┌────────────────────────┐   │
  │  │ │ 📍 Sainte-Chapelle      │   │  ← No time, TextTertiary
  │  │ │   1st Arrondissement    │   │     "Assign to Day" on
  │  │ └────────────────────────┘   │     long-press
  │  │                              │
  │                                 │
  │                     ┌──────┐    │
  │                     │  +   │    │  ← Speed Dial FAB
  │                     └──────┘    │     56px, terracotta
  │                                 │     shadow-medium
  └─────────────────────────────────┘
```

**Card Design — TimelinePlaceCard:**

```
  ┌────────────────────────────┐
  │ ⭐ Eiffel Tower             │  ← Icon + 17px SemiBold
  │   Champ de Mars, Paris      │  ← 13px TextSecondary
  │   9:00 AM - 11:30 AM        │  ← 13px TextTertiary
  └────────────────────────────┘
  Background: white (Surface)
  Shadow: subtle
  Corner radius: 12px
  Padding: 12px vertical, 16px horizontal
  Left margin: 40px (space for timeline rail)
```

**Card Design — TimelineBookingCard:**

```
  ┌────────────────────────────┐
  │▌ ✈️  AA 1234                │  ← 4px colored left border
  │▌ JFK → CDG                 │     Booking type icon + title
  │▌ 6:30 AM → 8:45 PM         │     17px SemiBold
  │▌ Conf: XKRF4Q              │  ← 11px, terracotta pill badge
  └────────────────────────────┘
  Left border: 4px, booking-type color
  Background: white
  Shadow: subtle
  Corner radius: 12px
  The colored border is the ONLY visual difference
  from place cards — keeps it clean
```

**Timeline Rail:**

```
  Vertical line: 2px wide, #E5E7EB (light gray)
  Position: 20px from left edge
  Place dots: ● 10px circle, filled with day-color
  Booking dots: ◆ 10px diamond, filled with booking-type color
  Connector to card: 12px horizontal line
  from dot center to card left edge
```

> **UX Review correction:** Booking dots now use **diamond shape** (◆) instead of circles. This provides shape-based differentiation from place dots (●), which is critical when booking-type colors and day-colors could appear similar — particularly for color-blind users. Shape differentiation works when color differentiation fails.

**DaySectionHeader (sticky):**

```
  EXPANDED:
  ┌─────────────────────────────────┐
  │ ▼  Day 1 — Saturday, Mar 12    │
  │    3 items                      │
  └─────────────────────────────────┘
  Height: 52px
  Background: warm cream (#FDF8F0)
  Left: 4px day-color bar (full height)
  Chevron: 16px, rotates 0° → -90° on collapse
  "Day 1 — Saturday, Mar 12": 15px SemiBold
  "3 items": 13px TextTertiary
  Border-bottom: 1px divider color when sticky
  COLLAPSED (two-line format):
  ┌─────────────────────────────────┐
  │ ▶  Day 1 — Sat, Mar 12         │  ← Line 1: day info (15px SemiBold)
  │    3 items · AA 1234, Eiffel... │  ← Line 2: content preview (13px TextSecondary)
  └─────────────────────────────────┘
  Height: 44px
```

> **UX Review correction:** The original single-line collapsed format ("Day 1 — Sat, Mar 12 · 3 items · AA 1234, Eiffel...") truncated almost immediately on smaller screens (iPhone SE: ~32 characters before truncation), making the content preview useless. Two-line format gives the preview its own full-width line. "AA 1234, Eiffel Tower, Le Petit Cler" at 13px fits comfortably.

**NowIndicator:**

```
  ── NOW ──────────────────────────
  Horizontal line spanning the timeline
  "NOW" text: 11px SemiBold, white text
  on terracotta rounded pill (24px wide)
  Line: 1px dashed, terracotta/50%
```

**Speed Dial FAB:**

```
  FAB positioning:
  16px from right edge
  16px above safe area bottom inset
  On devices with home indicator (34px): FAB bottom edge = 50px from screen edge
  On devices without home indicator: FAB bottom edge = 16px from screen edge
  FAB must never overlap the home indicator gesture area
```

> **UX Review correction:** Original spec did not account for safe area insets. On iPhone 14+ (34px home indicator) and Android gesture navigation (16-48px), the FAB would overlap system UI without explicit safe area positioning.

```
  Speed Dial FAB (expanded):
                     📍 Add Place    ← White mini-FAB (44px)
                                      + text label on left
                     ✈️ Add Booking    13px SemiBold, white text
                     ┌──────┐
                     │  ✕   │       ← FAB changes + to ✕
                     └──────┘         Scrim: black/30% (was 40%)
                                      Spring animation:
                                      stagger 50ms per item
                                      scale 0 → 1 + translate
```

> Scrim reduced from 40% to 30% opacity. Apple typically uses lighter scrims; 40% is heavy and makes the background feel disconnected.

---

### Screen 5: Add Place (Bottom Sheet)

**Emotion: "Finding the perfect spot is fun."**

```
  ┌─────────────────────────────────┐
  │  ─── ───                        │
  │                                 │
  │  Add to Day 2 — Mar 13    ✕    │  ← Day picker (tappable to change)
  │                                 │     13px TextSecondary
  │  ┌───────────────────────────┐  │
  │  │  🔍  Search places...      │  │  ← Big search bar, 48px
  │  └───────────────────────────┘  │
  │                                 │
  │  YOUR IDEAS                     │  ← If wishlist has items
  │                                 │     11px uppercase TextTertiary
  │  ┌───────────────────────────┐  │
  │  │ 📍 Sainte-Chapelle     ➕ │  │  ← Wishlist items
  │  │   1st Arrondissement      │  │     Tap ➕ to assign to day
  │  ├───────────────────────────┤  │     ➕ is terracotta circle
  │  │ 📍 Shakespeare & Co    ➕ │  │     28px
  │  │   5th Arrondissement      │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ─────── or search ────────     │  ← Divider with text
  │                                 │     11px TextTertiary
  │                                 │
  │  (Search results appear here    │
  │   when user types)              │
  │                                 │
  └─────────────────────────────────┘
  When searching:
  │  SEARCH RESULTS                 │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ ⭐ Musee d'Orsay        ➕ │  │  ← Results from Google
  │  │   1 Rue de la Legion...   │  │     Category auto-detected
  │  ├───────────────────────────┤  │
  │  │ 🍴 Cafe de Flore        ➕ │  │
  │  │   172 Boulevard Saint...  │  │
  │  └───────────────────────────┘  │
```

Single tap ➕ = instant add (haptic feedback). Long-press row = detail form (category picker, time, notes) before adding.

---

### Screen 6: Add Booking (Full Screen)

**Emotion: "My reservations, beautifully organized."**

**Single screen: Type chips + form** (replaces the original 2-step flow)

> **UX Review correction:** The 2x3 grid of 100px cards consumed 330+ pixels for a 6-option picker, then navigated to a second screen for the form. Two full-screen transitions for one selection. Replaced with horizontal chip selector at the top of the form — one screen, zero navigation steps, 44px instead of 330px for the selector.

```
  ┌─────────────────────────────────┐
  │  [←]     Add Booking            │
  ├─────────────────────────────────┤
  │                                 │
  │  ┌────┐┌────┐┌────┐┌────┐┌────┐│  ← Horizontal scroll chips
  │  │ ✈️  ││ 🏨  ││ 🍴  ││ 🚗  ││ 🎟️ ││     60px wide, 44px tall
  │  │Flt ││Htl ││Din ││Car ││Act ││     Selected: terracotta fill
  │  └────┘└────┘└────┘└────┘└────┘│     Unselected: outline
  │                    (scrolls →) │     🚆 Transport off-screen
  │                                 │
  │  ── Flight form below ────────  │  ← Form appears inline
  │                                 │     Changes when chip changes
  │  [Flight form fields...]        │     (animated cross-fade)
  │                                 │
  └─────────────────────────────────┘
```

Tapping a different chip swaps the form below with a cross-fade animation (150ms). No screen navigation. This is the pattern Apple uses in Reminders (priority picker) and Health (category selector).

**Flight form (example)**

```
  ┌─────────────────────────────────┐
  │  [←]     ✈️ Flight              │
  ├─────────────────────────────────┤
  │                                 │
  │  FLIGHT DETAILS                 │  ← 11px uppercase TextTertiary
  │                                 │
  │  Airline                        │  ← 13px TextSecondary (label)
  │  ┌───────────────────────────┐  │
  │  │  American Airlines        │  │  ← Autocomplete
  │  └───────────────────────────┘  │
  │                                 │
  │  Flight Number                  │
  │  ┌───────────────────────────┐  │
  │  │  AA 1234                  │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌────────────┐ ┌────────────┐  │
  │  │ From       │ │ To         │  │  ← Side by side
  │  │ JFK        │ │ CDG        │  │
  │  └────────────┘ └────────────┘  │
  │                                 │
  │  ┌────────────┐ ┌────────────┐  │
  │  │ Depart     │ │ Arrive     │  │
  │  │ Mar 12     │ │ Mar 12     │  │
  │  │ 6:30 AM    │ │ 8:45 PM    │  │
  │  └────────────┘ └────────────┘  │
  │                                 │
  │  OPTIONAL                       │  ← Collapsible section
  │                                 │
  │  ┌────────────┐ ┌────────────┐  │
  │  │ Terminal   │ │ Gate       │  │
  │  │ 1          │ │ B22        │  │
  │  └────────────┘ └────────────┘  │
  │                                 │
  │  Confirmation Number            │
  │  ┌───────────────────────────┐  │
  │  │  XKRF4Q                  │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │      Add Flight  →        │  │  ← Terracotta CTA
  │  └───────────────────────────┘  │
  │                                 │
  └─────────────────────────────────┘
  All inputs: white bg, 1px divider border
  rounded-medium (12px), 48px height
  Labels above inputs, 13px TextSecondary
  Required fields: no asterisk, just
  disable CTA until filled
```

**Keyboard Handling (applies to all booking forms):**

> **UX Review addition:** Original spec did not address keyboard behavior. On iOS, the keyboard is 291-335px tall, leaving only 509px visible — not enough for a full form + CTA.

```
  When keyboard opens:
  - ScrollView auto-scrolls to show focused input + its label
  - 16px minimum space between focused input bottom and keyboard top
  - CTA button floats above keyboard (sticky to keyboard top)
    with a subtle top border separator (1px divider color)
  - "OPTIONAL" collapsible section auto-collapses when keyboard opens
  - Tap outside any input → dismiss keyboard
  - "Next" keyboard accessory button moves to next input
  - "Done" on last input → dismiss keyboard, scroll CTA into view
```

**Form Validation & Error States:**

> **UX Review addition:** Original spec covered disabled CTA state but not inline validation errors or failure states.

```
  Inline validation error:
  ┌───────────────────────────┐
  │  Flight Number             │  ← 13px TextSecondary (label)
  ┌───────────────────────────┐
  │  AA                        │  ← Input with red border (1px #DC2626)
  └───────────────────────────┘
  Enter a valid flight number    ← 13px Error color (#DC2626)
                                    Appears below input, 4px gap
                                    Input border turns red
                                    Shake animation (subtle, 200ms)
  Network error on save:
  ┌───────────────────────────────────┐
  │  ⚠️ Couldn't save. Check your     │  ← Error toast, amber left border
  │  connection and try again.        │     Auto-dismiss 5 seconds
  │  [Try Again]                      │     "Try Again" = terracotta text
  └───────────────────────────────────┘
  Duplicate booking warning:
  ┌───────────────────────────────────┐
  │  ⚠️ AA 1234 is already on Day 1.  │  ← Warning toast
  │  [Add Anyway]  [Cancel]           │     Not blocking — user decides
  └───────────────────────────────────┘
```

---

### Screen 7: Map View

**Emotion: "I can SEE my whole trip."**

```
  ┌─────────────────────────────────┐
  │  [←]           Map              │
  ├─────────────────────────────────┤
  │  ┌──────────────────────────┐   │
  │  │ All │ Day 1│ Day 2│ ...  │   │  ← Day filter chips
  │  └──────────────────────────┘   │     Horizontal scroll
  │                                 │     floating over map
  │                                 │     blur bg, rounded-full
  │          🗺️                      │     "All" = terracotta fill
  │     Full-screen                 │     Others = white, border
  │     MapView                     │
  │                                 │
  │        ● 1                      │  ← Day-colored circle pin
  │                                 │     with sort number (white text)
  │            ● 2                  │
  │                                 │
  │        ✈️                        │  ← Booking pin (type icon
  │                                 │     in day-colored circle)
  │    ●─────●─────●                │  ← Route polyline (V1)
  │                                 │     day-color, 40% opacity
  │                                 │
  │  ┌───────────────────────────┐  │  ← Bottom sheet on pin tap
  │  │ ⭐ Eiffel Tower            │  │     Slides up, detent 30%
  │  │   Champ de Mars, Paris     │  │     rounded-top-xl
  │  │   9:00 AM - 11:30 AM       │  │     white bg
  │  │                             │  │
  │  │   [Navigate]  [Edit]        │  │  ← Buttons row
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

**Map pin design:**

```
  Place pin:    ● with number    (day-colored filled CIRCLE, 28px
                                  white number text inside, 11px Bold)
  Booking pin:  ◆ with icon      (booking-type-colored filled DIAMOND, 32px
                                  white booking icon inside)
                                  Diamond shape matches timeline rail dots
  When day filter active:
  - Selected day pins: full opacity, slightly larger (32px circles / 36px diamonds)
  - Other day pins: 20% opacity, normal size
```

> **UX Review correction:** Booking pins now use diamond shape to match the timeline rail differentiation. This provides consistent shape language across timeline and map: circles = places, diamonds = bookings.

---

### Screen 8: Bookings Screen

```
  ┌─────────────────────────────────┐
  │  [←]        Bookings            │
  ├─────────────────────────────────┤
  │                                 │
  │  FLIGHTS                        │  ← Type section header
  │                                 │     11px uppercase TextTertiary
  │  ┌───────────────────────────┐  │     Blue left bar
  │  │▌ ✈️ AA 1234                │  │
  │  │▌ JFK → CDG · Mar 12      │  │
  │  │▌ Conf: XKRF4Q            │  │
  │  ├───────────────────────────┤  │
  │  │▌ ✈️ AA 891                 │  │
  │  │▌ CDG → JFK · Mar 18      │  │
  │  │▌ Conf: PXLM2R            │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  HOTELS                         │  ← Violet left bar
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │▌ 🏨 Le Marais Hotel        │  │
  │  │▌ Mar 12-17 · 5 nights    │  │
  │  │▌ Conf: HBK-992841        │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  DINING                         │
  │  ...                            │
  │                                 │
  │  ─────────────────────────────  │
  │                                 │
  │  📧 FORWARD A BOOKING           │  ← Email forwarding section
  │                                 │     Primary Light bg (#F4E8E0)
  │  Forward confirmation emails    │     rounded-lg, 16px padding
  │  to add them automatically:     │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ [usr12@trips.app](mailto:usr12@trips.app)     📋   │  │  ← Monospace font
  │  └───────────────────────────┘  │     copy button right
  │                                 │     White bg, dashed border
  │  2 pending · 1 needs review     │  ← 13px TextSecondary
  │  Review →                       │  ← 13px terracotta, tappable
  │                                 │
  └─────────────────────────────────┘
```

---

### Screen 9: Profile / Settings

**Emotion: "Clean, minimal, just the essentials."**

```
  ┌─────────────────────────────────┐
  │ Profile                         │  ← Large title
  ├─────────────────────────────────┤
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  ┌────┐                   │  │
  │  │  │ AJ │  [amit@email.com](mailto:amit@email.com)   │  │  ← Avatar circle (initials)
  │  │  └────┘  Joined Mar 2026  │  │     terracotta bg, white text
  │  └───────────────────────────┘  │     40px circle
  │                                 │
  │  PREFERENCES                    │
  │  ┌───────────────────────────┐  │
  │  │  Sort trips by       Date ▼│  │  ← Grouped list cells
  │  ├───────────────────────────┤  │     White bg, rounded-lg
  │  │  Dark mode          Auto ▼│  │     Chevron/value on right
  │  └───────────────────────────┘  │
  │                                 │
  │  ABOUT                          │
  │  ┌───────────────────────────┐  │
  │  │  Version              1.0 │  │
  │  ├───────────────────────────┤  │
  │  │  Privacy Policy        →  │  │
  │  ├───────────────────────────┤  │
  │  │  Terms of Service      →  │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │       Sign Out            │  │  ← Red text, white bg
  │  └───────────────────────────┘  │     rounded-lg
  │                                 │
  └─────────────────────────────────┘
```

> **UX Review correction:** Profile is now a pushed screen accessed via the avatar circle in the Trips List nav bar. No tab bar.

```
---
### Screen 10: Place Detail (Bottom Sheet on Tap)
When user taps a place card on the timeline — slides up as bottom sheet.
```

  ┌─────────────────────────────────┐

  │  ─── ───                        │

  │                                 │

  │  ⭐ Eiffel Tower                │  ← 20px SemiBold

  │  Champ de Mars, 75007 Paris     │  ← 15px TextSecondary

  │                                 │

  │  ┌────────┐ ┌────────┐         │

  │  │ 🕐      │ │ ⭐      │         │  ← Info chips, inline

  │  │ Open    │ │ 4.6    │         │     fetched from cache

  │  │ til 11PM│ │ (2,341)│         │     (Pro data, on-tap)

  │  └────────┘ └────────┘         │

  │                                 │

  │  "Iconic iron lattice tower     │  ← editorialSummary

  │   on the Champ de Mars,         │     15px, TextPrimary

  │   named after engineer           │     3-line max, "Read more"

  │   Gustave Eiffel..." Read more  │

  │                                 │

  │  GETTING THERE                  │

  │  🚶 15 min  🚗 4 min  🚲 8 min  │  ← Haversine estimates

  │  🚆 12 min                      │     from previous place

  │                                 │     13px, TextSecondary

  │                                 │

  │  ┌────────────────────────────┐ │

  │  │     🗺️ Navigate             │ │  ← PRIMARY: terracotta bg,

  │  └────────────────────────────┘ │     white text, full-width, 48px

  │                                 │

  │  ┌──────────┐  ┌──────────┐    │

  │  │ ✏️ Edit   │  │ 📅 Move   │    │  ← SECONDARY: outline style

  │  └──────────┘  └──────────┘    │     44px, side by side

  │                                 │

  │  Delete                         │  ← TERTIARY: text-only, Error color

  │                                 │     15px, centered, no button chrome

  │                                 │     Or accessible via "..." overflow

  └─────────────────────────────────┘

```
---
### Empty States for Sub-Screens
> **UX Review addition:** Empty state was defined for Trips List but not for other screens. Every screen that can be empty needs guidance toward the next action.
**Map View — 0 places:**
```

  ┌─────────────────────────────────┐

  │  [←]           Map              │

  ├─────────────────────────────────┤

  │                                 │

  │          🗺️                      │

  │     (blank map, destination     │

  │      centered, no pins)        │

  │                                 │

  │  ┌───────────────────────────┐  │

  │  │                           │  │  ← Floating card, bottom

  │  │  Add places to see them   │  │     White bg, shadow-medium

  │  │  on the map.              │  │     rounded-top-xl

  │  │                           │  │

  │  │  ┌─────────────────────┐  │  │

  │  │  │  + Add a Place       │  │  │  ← Terracotta outline CTA

  │  │  └─────────────────────┘  │  │

  │  └───────────────────────────┘  │

  └─────────────────────────────────┘

```
**Bookings Screen — 0 bookings:**
```

  ┌─────────────────────────────────┐

  │  [←]        Bookings            │

  ├─────────────────────────────────┤

  │                                 │

  │                                 │

  │        ┌───────────────┐        │

  │        │  ✈️ 🏨          │        │  ← Simple illustration

  │        └───────────────┘        │

  │                                 │

  │  No bookings yet                │  ← 20px SemiBold, centered

  │                                 │

  │  Add flights, hotels, and       │  ← 15px TextSecondary

  │  reservations to keep           │     centered, max 260px

  │  everything in one place.       │

  │                                 │

  │  ┌──────────────────────┐       │

  │  │  + Add a Booking      │       │  ← Terracotta outline CTA

  │  └──────────────────────┘       │

  │                                 │

  │  ─────────────────────────────  │

  │                                 │

  │  📧 FORWARD A BOOKING           │  ← Forwarding section still shows

  │  ...                            │     even with 0 bookings

  └─────────────────────────────────┘

```
**Ideas / Wishlist — 0 items:**
```

  At bottom of timeline, Ideas section:

  ┌─────────────────────────────────┐

  │  💡 Ideas                       │

  ├─────────────────────────────────┤

  │                                 │

  │  Save places for later          │  ← 15px TextSecondary

  │  When adding a place,           │     centered

  │  choose "Add to Ideas"          │

  │  to save it without             │

  │  scheduling.                    │

  │                                 │

  └─────────────────────────────────┘

```
---
## Notification System
### Push Notifications (V1)
Triggered by server events when user is OUTSIDE the app. Delivered via APNs (Apple Push Notification service) — free, native iOS.
| Trigger              | Title         | Body                                                         | Deep Link                   |
| -------------------- | ------------- | ------------------------------------------------------------ | --------------------------- |
| Booking parsed       | Trip to Paris | "Your flight AA 1234 JFK→CDG was added"                      | → Review Forwarded Bookings |
| Parse failed         | Trip to Paris | "We couldn't read a forwarded email. Tap to enter manually." | → Add Booking form          |
| Trip starts tomorrow | Trip to Paris | "Starts tomorrow! 12 places and 4 bookings planned."         | → Trip Detail               |
| Trip starts today    | Trip to Paris | "Your trip starts today! Have an amazing trip ✈️"            | → Trip Detail               |
**V2 additions**: Flight delayed, gate changed, flight cancelled, checklist reminder.
**Permission request timing**: NOT on first launch. Ask on first booking email forwarded, using a pre-permission explanation screen:
```

  ┌─────────────────────────────────┐

  │                                 │

  │            📬                   │

  │                                 │

  │  We'll notify you when your     │  ← 20px SemiBold

  │  booking is ready               │

  │                                 │

  │  Get alerts when we parse your  │  ← 15px TextSecondary

  │  forwarded bookings, and when   │

  │  your trip is about to start.   │

  │                                 │

  │  ┌───────────────────────────┐  │

  │  │     Enable Notifications  │  │  ← Terracotta CTA

  │  └───────────────────────────┘  │     triggers system dialog

  │                                 │

  │  Not now                        │  ← TextTertiary, skips

  │                                 │

  └─────────────────────────────────┘

```
### In-App Notifications (V1)
Three types — no dedicated notification center in V1.
**Type 1: Toasts (transient, 3-5 seconds)**
Slide up from bottom. White card, shadow-medium, rounded-lg. Auto-dismiss.
```

  Booking parsed while in app:

  ┌───────────────────────────────────┐

  │  ✈️ AA 1234 added to Day 1        │

  │  View →                            │  ← Taps scrolls to card

  └───────────────────────────────────┘

  Parse failed while in app:

  ┌───────────────────────────────────┐

  │  ⚠️ Couldn't read forwarded email │  ← Amber left border

  │  Enter manually →                  │  ← Opens Add Booking

  └───────────────────────────────────┘

```
**Type 2: Badge Dots (persistent until acted on)**
Small red dots (8px) on navigation elements indicating something needs attention.
```

  Bookings pill (unreviewed parsed bookings):

  ┌──────┐

  │✈️  4 │   ← "4" = total bookings count

  │Book 🔴│   ← Red dot = unreviewed parsed bookings exist

  └──────┘      Dot disappears after visiting Bookings

                screen and reviewing all items

  Avatar button (any trip has unreviewed items):

  ┌────┐

  │[AJ]│ 🔴   ← Red dot on avatar circle in nav bar

  └────┘       (replaces old Home tab badge since tab bar removed)

```
Badge dot states (Bookings pill):
| State                                    | Display                                     |
| ---------------------------------------- | ------------------------------------------- |
| 0 bookings, never forwarded              | Terracotta pulse dot (forwarding discovery) |
| 0 bookings, forwarded but pending parse  | No dot (waiting)                            |
| 4 bookings, 2 new parsed awaiting review | "4" + red dot                               |
| 4 bookings, all reviewed                 | "4", no dot                                 |
**Type 3: Inline Notification Cards (contextual, within content)**
Appear within screen content, look like content not system alerts.
**Unreviewed bookings banner (Trip Detail, below pills):**
```

  ┌───────────────────────────────┐

  │  📬 2 bookings ready           │  ← Light blue bg (info tint)

  │  Review and add to your trip → │     rounded-lg, 12px padding

  └───────────────────────────────┘     Tap → Review screen

                                        Separate from forwarding

                                        discovery banner.

                                        Shows only when parsed

                                        bookings exist unreviewed.

```
**Trip starting banner (Trip Detail header, 24h before):**
```

  ┌──────────────────────────┐

  │ 🎉 Your trip starts       │  ← Terracotta bg pill

  │    tomorrow! Have fun!    │     replaces normal status text

  └──────────────────────────┘     "Starts in 1 day" → this

```
**Trip starting badge (Trips List hero card, 24h before):**
```

  ┌───────────────────────────────┐

  │  🖼️ Destination photo          │

  │  Trip to Paris                 │

  │  ┌──────────────────────┐     │

  │  │ ✈️ Starts tomorrow!   │     │  ← Amber bg pill

  │  └──────────────────────┘     │     replaces "In X days"

  └───────────────────────────────┘

```
### Banner Stacking Order (Trip Detail)
When multiple banners apply simultaneously, they stack in this order below the pills row:
```

  ┌──────┐ ┌──────┐ ┌──────┐        ← Pills

  ┌───────────────────────────────┐  ← 1. Unreviewed bookings (blue)

  │  📬 2 bookings ready → Review │      highest priority

  └───────────────────────────────┘

  ┌───────────────────────────────┐  ← 2. Forwarding discovery (cream)

  │  📧 Got booking emails?       │      second priority

  │  Forward to [[usr12@trips.app](mailto:usr12@trips.app)](mailto:[usr12@trips.app](mailto:usr12@trips.app))   │      only if 0 bookings AND

  └───────────────────────────────┘      not dismissed

  ── Day 1 — Sat, Mar 12 ─────      ← Timeline

```
Maximum 2 banners visible at once. In practice, the forwarding banner disappears once the first booking arrives, so users typically see only 0-1 banners.
### V2: Notification Center
Bell icon added to nav bar on Trips List. Opens a dropdown/pushed screen with chronological notification history:
```

  ┌─────────────────────────────────┐

  │  [←]       Notifications        │

  ├─────────────────────────────────┤

  │                                 │

  │  TODAY                          │

  │  ┌───────────────────────────┐  │

  │  │ ⚠️ Flight AA 1234 delayed  │  │

  │  │   New departure: 7:15 AM   │  │

  │  │   2 hours ago              │  │

  │  └───────────────────────────┘  │

  │  ┌───────────────────────────┐  │

  │  │ ✅ Hotel booking parsed    │  │

  │  │   Le Marais Hotel added    │  │

  │  │   5 hours ago              │  │

  │  └───────────────────────────┘  │

  │                                 │

  │  YESTERDAY                      │

  │  ┌───────────────────────────┐  │

  │  │ ✈️ Flight booking parsed   │  │

  │  │   AA 1234 added to Day 1  │  │

  │  └───────────────────────────┘  │

  └─────────────────────────────────┘

```
Deferred to V2 when flight tracking adds time-sensitive alerts worth revisiting.
---
## Email Forwarding Discovery System
The forwarding email is the app's differentiator. Users must discover it naturally without feeling nagged. Five touchpoints, each progressively subtler, all disappearing once the user adopts the feature.
### Touchpoint 1: Timeline Banner (highest prominence)
Appears below pills row when trip has 0 bookings. Dismissible.
```

  ┌──────┐ ┌──────┐ ┌──────┐        ← Pills row

  │🗺️ Map│ │✈️ 0  │ │📎 0  │

  └──────┘ │Book  │ │Files │

           └──────┘ └──────┘

  ┌───────────────────────────────┐   ← FORWARDING BANNER

  │                           ✕   │      Primary Light bg (#F4E8E0)

  │  📧 Got booking emails?       │      rounded-lg (16px)

  │                               │      16px padding all sides

  │  Forward them to              │      ~120px total height

  │  ┌─────────────────────────┐  │

  │  │ [[usr12@trips.app](mailto:usr12@trips.app)](mailto:[usr12@trips.app](mailto:usr12@trips.app))    📋  │  │   ← White bg, dashed terracotta

  │  └─────────────────────────┘  │      border, monospace font

  │  and they'll appear here      │      📋 = terracotta, 28px

  │  automatically ✨              │

  └───────────────────────────────┘

  ── Day 1 — Sat, Mar 12 ─────      ← Timeline starts below

```
**Show when**: Trip has 0 bookings AND not dismissed for this trip.
**Hide when**: User copies email (change to "Great! We'll notify you 📬" for 3s then auto-dismiss) OR user taps ✕ (hide for this trip) OR trip gets its first booking.
**State**: Per-trip dismiss flag in @Observable UIStateManager (persisted via UserDefaults).
### Touchpoint 2: Speed Dial Footer
When FAB expands, a tip appears at screen bottom (behind the scrim).
```

```
                 📍 Add Place
                 ✈️ Add Booking
                 ┌──────┐
                 │  ✕   │
                 └──────┘
```

  ┌───────────────────────────────┐   ← Bottom of screen

  │  💡 Forward booking emails to  │      Semi-transparent bg

  │  [[usr12@trips.app](mailto:usr12@trips.app)](mailto:[usr12@trips.app](mailto:usr12@trips.app)) for auto-     │      13px, TextSecondary (white)

  │  import  📋                    │      Tap 📋 copies email

  └───────────────────────────────┘      Shows only if <3 bookings

```
**Show when**: User has <3 total bookings across all trips.
**Hide when**: 3+ bookings exist.
### Touchpoint 3: InlineAddButton Hint
Secondary line on the "+ Add to Day X" button.
```

  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐   │

  │  ╎  + Add to Day 1          ╎   │   ← Primary action (tappable)

  │  ╎  or forward bookings 📧  ╎   │   ← 11px TextTertiary

  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘   │      Tap copies email + toast

```
**Show when**: That specific day has 0 bookings.
**Hide when**: Day has at least 1 booking.
### Touchpoint 4: Bookings Pill Pulse Dot
Tiny pulsing dot next to the "0" count on the Bookings pill.
```

  ┌──────┐

  │✈️ 🔴 │   ← 6px terracotta dot, pulse animation

  │Book  │      scale 1.0 → 1.3 → 1.0, 2-second cycle

  └──────┘      Draws eye without being aggressive

```
**Show when**: Trip has 0 bookings.
**Hide when**: Trip has 1+ booking.
### Touchpoint 5: Success Celebration
Toast after first successfully parsed forwarded booking.
```

  ┌───────────────────────────────┐

  │  🎉 Booking added from email!  │   ← Success green bg, white text

  │  Forward more to keep your     │      Slides up from bottom

  │  trip up to date.              │      Auto-dismiss 4 seconds

  └───────────────────────────────┘      Paired with success haptic

```
**Show when**: First parsed booking confirmed for this user (ever).
**Hide after**: 4 seconds auto-dismiss.
### Touchpoint Summary
| Location             | When Shown                | Prominence        | Disappears When                          |
| -------------------- | ------------------------- | ----------------- | ---------------------------------------- |
| Timeline banner      | 0 bookings on trip        | High (120px card) | Dismissed / first booking / email copied |
| Speed Dial footer    | <3 total bookings         | Medium (text)     | 3+ bookings exist                        |
| InlineAddButton hint | Day has 0 bookings        | Low (11px)        | Day gets a booking                       |
| Bookings pill dot    | 0 bookings on trip        | Low (6px dot)     | 1+ booking                               |
| Success toast        | First-ever forward parsed | Medium (4s toast) | Auto-dismiss                             |
A power user who forwards all bookings sees NONE of these after their first trip. The app stays clean.
---
## Animation System
### Animation Philosophy
**Three rules:**
1. **Every animation must answer a question.** "Did that work?" (feedback). "Where did that go?" (state change). "What should I look at?" (attention). If the animation doesn't answer a question, delete it.
2. **Spring physics, not linear easing.** Springs feel natural — they accelerate, overshoot slightly, and settle. Linear feels robotic. Ease-in-out feels generic. Springs feel alive.
3. **Pair with haptics.** An animation without haptic feedback feels ghostly. A haptic without animation feels broken. Together they feel physical.
### Technology: SwiftUI Native Animations + Core Animation
All animations use SwiftUI's built-in animation system, which runs on the render server at 60-120 FPS (ProMotion). No third-party animation libraries needed. Use:
- `withAnimation(.spring())` for physics-based motion
- `withAnimation(.easeInOut(duration:))` for duration-based (rare, only for progress bars)
- `.transition(.asymmetric(insertion:, removal:))` for view enter/exit
- `.matchedGeometryEffect` for hero transitions
- `.animation(.spring(), value:)` for value-driven animations
- `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` synced to animation keyframes
- `UIAccessibility.isReduceMotionEnabled` check — skip all non-essential animations
### Spring Presets
```swift

// Theme/AppAnimations.swift

enum AppSpring {

    // Snappy feedback — buttons, taps, small elements

    static let snappy = Animation.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0)

    // ~200ms, minimal overshoot

    // Smooth transitions — sheets, cards entering

    static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.8, blendDuration: 0)

    // ~350ms, gentle overshoot

    // Bouncy delight — FAB, celebrations

    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0)

    // ~400ms, visible bounce

    // Heavy settle — dragged items landing

    static let heavy = Animation.spring(response: 0.3, dampingFraction: 1.0, blendDuration: 0)

    // ~300ms, no overshoot, feels weighty

}

```
### Complete Animation Inventory
#### Category 1: Feedback Animations (< 200ms)
These confirm "I received your input." Instant, subtle, paired with haptics.
**Button press scale:**
```

  User presses button:

    .scaleEffect: 1.0 → 0.96     AppSpring.snappy

    .opacity: 1.0 → 0.9          duration: <100ms

  User releases:

    .scaleEffect: 0.96 → 1.0     AppSpring.snappy

    .opacity: 0.9 → 1.0

  Haptic: UIImpactFeedbackGenerator(style: .light).impactOccurred()

```
Applied to: all AppButton views, FAB, pill buttons, trip cards, place cards. Implemented via `.buttonStyle` custom `ButtonStyle` with `configuration.isPressed`.
**Copy-to-clipboard flash:**
```

  User taps 📋 copy button:

    Icon: 📋 → ✓             cross-fade, 150ms

    Background: flash white   opacity 0 → 0.3 → 0, 300ms

    After 1.5s: ✓ → 📋       cross-fade back

  Haptic: notificationOccurred(.success)

  Toast: "Copied!" slides up from bottom, 2s auto-dismiss

```
Applied to: forwarding email copy, confirmation number copy.
**Save checkmark:**
```

  User saves place/booking:

    Button text: "Add Flight →" → "✓ Added"

    Button bg: terracotta → success green

    Duration: 300ms ease-out

    After 500ms: dismiss sheet

  Haptic: notificationOccurred(.success)

```
Applied to: Add Place CTA, Add Booking CTA, Edit save.
**Quick-add pulse:**
```

  User taps ➕ on search/wishlist result:

    ➕ icon: scale 1.0 → 1.3 → 0    spring: bouncy

    Row: slide left + fade out        300ms

    Simultaneously: new card appears on timeline behind sheet

  Haptic: impact(.medium)

```
#### Category 2: State Change Animations (200-400ms)
These answer "what just changed?" Smooth, clear, directional.
**Card enters timeline (place/booking added):**
```

  New card appears:

    .transition(.asymmetric(

      insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.95)),

      removal: .opacity

    ))

    withAnimation(AppSpring.smooth)

    Neighbors shift via SwiftUI layout animation

  Duration: ~350ms

  Haptic: UIImpactFeedbackGenerator(style: .light) when card reaches final position

```
**Card deleted (swipe-to-delete):**
```

  User swipes left past threshold (via .swipeActions):

    Card: .transition(.move(edge: .trailing).combined(with: .opacity))

    withAnimation(AppSpring.heavy)

    Neighbors slide up via layout animation

  Haptic: UINotificationFeedbackGenerator().notificationOccurred(.warning) at threshold

  Toast: slides up with "Undo" button

```
**Undo (card returns):**
```

  User taps "Undo" on toast:

    Card reinserted: .transition(.move(edge: .leading).combined(with: .opacity))

    withAnimation(AppSpring.smooth)

    Neighbors shift back down via layout animation

  Haptic: UIImpactFeedbackGenerator(style: .light)

```
**Day section collapse/expand:**
```

  User taps DaySectionHeaderView:

    Chevron: .rotationEffect(collapsed ? .degrees(-90) : .zero)

    withAnimation(AppSpring.snappy)

    Content: if/else with .transition(.opacity) inside withAnimation

  Haptic: UISelectionFeedbackGenerator().selectionChanged()

```
**Drag-and-drop reorder:**
```

  User long-presses a card (drag start via .onMove or custom DragGesture):

    Card: .scaleEffect(1.03)           AppSpring.snappy

    Shadow: .shadow(radius: 12)        cross-fade

    Other cards: .opacity(0.7)

  Haptic: UIImpactFeedbackGenerator(style: .medium)

  During drag:

    Card follows finger                gesture-driven, no spring

    Gap opens at drop target           SwiftUI layout animation

    Other cards shift with spring      withAnimation(AppSpring.smooth)

  On drop:

    Card: .scaleEffect(1.0)           AppSpring.heavy

    Shadow: .shadow(radius: 2)        cross-fade

    All cards: .opacity(1.0)

  Haptic: UIImpactFeedbackGenerator(style: .light)

```
**Booking parsed (realtime update):**
```

  New parsed booking card appears in review list:

    .transition(.move(edge: .top).combined(with: .opacity))

    withAnimation(AppSpring.smooth)

    Status badge: "Processing..." → "Ready ✓"

    Badge: .scaleEffect with AppSpring.bouncy

  Haptic: UINotificationFeedbackGenerator().notificationOccurred(.success)

```
#### Category 3: Navigation Animations (250-400ms)
These answer "where am I going?" Directional, smooth, interruptible.
**Sheet presentation:**
```

  Sheet appears (native SwiftUI .sheet):

    Uses iOS system sheet presentation with .presentationDetents

    Scrim: automatic system scrim

    Drag to dismiss: built-in via .presentationDragIndicator(.visible)

  No custom animation needed — native iOS sheet behavior is polished out of the box.

```
**Speed Dial FAB fan-out:**
```

  User taps FAB (+):

    FAB icon: "+" .rotationEffect(.degrees(45)) to "✕"   AppSpring.snappy

    FAB: .scaleEffect(0.95) → 1.0                        AppSpring.bouncy

    Mini-FAB 1 (Add Place):

      .offset from FAB center → final position

      .scaleEffect: 0 → 1.0                               AppSpring.bouncy

      .opacity: 0 → 1.0

      .animation(AppSpring.bouncy)

    Mini-FAB 2 (Add Booking):

      same animation

      .animation(AppSpring.bouncy.delay(0.06))             ← staggered

    Text labels: .opacity transition, .animation(delay: 0.1) after their FAB

    Scrim: .opacity(0.3)                                   withAnimation(.easeOut(duration: 0.25))

  Haptic: UIImpactFeedbackGenerator(style: .medium) on FAB tap

  Total duration: ~400ms for all items to settle

  Dismiss (tap scrim or ✕):

    Reverse order — items 2 then 1 collapse back to FAB center

    FAB: .rotationEffect(.zero) back to "+"

    Scrim fades out

```
**NavigationStack push transition:**
```

  Navigate to new screen (e.g., Map, Bookings):

    Uses native iOS NavigationStack push/pop transitions

    System-managed slide animation with interactive back swipe

  Back:

    Native interactive edge swipe gesture — built into NavigationStack

  No custom transition needed — iOS navigation transitions are the gold standard.

```
**No tab bar:**
```

  Profile is accessed via avatar button in .toolbar — NavigationLink push.

  No tab switching animation needed.

```
#### Category 4: Attention Animations (continuous, subtle)
These answer "what should I notice?" Subtle, non-distracting, purposeful.
**NOW indicator pulse:**
```

  Continuous subtle pulse on the "NOW" badge:

    opacity: 1.0 → 0.6 → 1.0      withTiming(2000ms, ease-in-out)

    scale: 1.0 → 1.02 → 1.0       withTiming(2000ms)

    Loops infinitely

    Very subtle — should not distract while reading timeline

```
**Bookings pill pulse dot (0 bookings):**
```

  Tiny 6px terracotta dot next to pill count:

    scale: 1.0 → 1.5 → 1.0        withTiming(2000ms, ease-in-out)

    opacity: 0.8 → 1.0 → 0.8      withTiming(2000ms)

    Loops infinitely

    Stops when bookings > 0

```
**Auto-scroll to today:**
```

  On timeline mount (active trip):

    Wait 300ms for layout                 ← let SectionList render

    scrollTo(nowIndicatorPosition)        smooth scroll, 600ms

    NOW indicator: scale 1.0 → 1.1 → 1.0  spring: bouncy (after scroll completes)

  No haptic. Silent attention guide.

```
**New parsed booking badge:**
```

  When Realtime push arrives:

    Badge count on Bookings pill: number change

    Old number: scale up + fade out       withSpring(snappy)

    New number: scale 0 → 1.0            withSpring(bouncy)

  Haptic: none (background event, don't interrupt)

```
#### Category 5: Delight Animations (situational)
These don't answer a question — they make the app feel alive. Used sparingly.
**Parallax cover photo (trip detail header):**
```

  As user scrolls the timeline down:

    Cover photo: translateY at 0.3x scroll speed  ← parallax

    Opacity: 1.0 → 0.8 (at collapse point)

    Scale: 1.0 → 1.05 (subtle zoom as it collapses)

    Title: translateY up, opacity fade (transfers to nav bar title)

  Gesture-driven, no springs needed. Directly mapped to scroll offset.

```
**Trip card press (trips list):**
```

  User presses (not yet releases) a trip card:

    scale: 1.0 → 0.97               spring: snappy

    shadow: subtle → medium          cross-fade

  Release (navigates):

    scale: 0.97 → 1.0               spring: snappy

  This makes cards feel "pressable" — like physical objects.

```
**First booking celebration (one-time):**
```

  After user's first-ever forwarded booking is confirmed:

    Confetti burst from the "Add to Trip" button

    6-8 small circles in day colors

    Radiate outward with random angles

    Fade out over 800ms

    + Success toast slides up

  Haptic: notificationOccurred(.success)

  Only triggers ONCE per user lifetime (flag in Supabase user metadata)

```
**Empty state illustration entrance:**
```

  When empty state screen appears:

    Illustration: scale 0.8 → 1.0     spring: bouncy

    + FadeIn, delay 100ms

    Title: FadeIn, delay 200ms

    Subtitle: FadeIn, delay 300ms

    CTA button: FadeIn + SlideInUp(20), delay 400ms

  Staggered entrance feels polished, not static.

```
### Haptic Pairing Map
Every animation has an explicit haptic decision: pair it or intentionally skip it.
| Animation              | Haptic | UIKit Type                                        | Why                                   |
| ---------------------- | ------ | ------------------------------------------------- | ------------------------------------- |
| Button press           | Yes    | UIImpactFeedbackGenerator(style: .light)          | Confirm touch registered              |
| FAB tap                | Yes    | UIImpactFeedbackGenerator(style: .medium)         | Bigger action = stronger feedback     |
| Copy email             | Yes    | UINotificationFeedbackGenerator(.success)         | Confirm clipboard action              |
| Save place/booking     | Yes    | UINotificationFeedbackGenerator(.success)         | Confirm data saved                    |
| Quick-add (➕)          | Yes    | UIImpactFeedbackGenerator(style: .medium)         | Confirm addition                      |
| Swipe-delete threshold | Yes    | UINotificationFeedbackGenerator(.warning)         | Warn: destructive action              |
| Drag start             | Yes    | UIImpactFeedbackGenerator(style: .medium)         | Confirm drag engaged                  |
| Drag drop              | Yes    | UIImpactFeedbackGenerator(style: .light)          | Confirm placement                     |
| Day collapse/expand    | Yes    | UISelectionFeedbackGenerator().selectionChanged() | Confirm toggle                        |
| Sheet present          | No     | --                                                | System handles this natively          |
| NavigationStack push   | No     | --                                                | System handles this natively          |
| Parallax scroll        | No     | --                                                | Continuous gesture, no discrete event |
| NOW pulse              | No     | --                                                | Background, no user action            |
| Pill dot pulse         | No     | --                                                | Background, no user action            |
| Auto-scroll            | No     | --                                                | System-initiated                      |
| Skeleton shimmer       | No     | --                                                | Loading state, no action              |
| Success confetti       | Yes    | UINotificationFeedbackGenerator(.success)         | Celebration moment                    |
| Empty state entrance   | No     | --                                                | Passive display                       |
### Reduced Motion Support
```swift

// Utilities/MotionManager.swift

import SwiftUI

@Observable

final class MotionManager {

    var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    init() {

        NotificationCenter.default.addObserver(

            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,

            object: nil, queue: .main

        ) { [weak self] _ in

            self?.reduceMotion = UIAccessibility.isReduceMotionEnabled

        }

    }

    func spring(_ preset: Animation) -> Animation {

        reduceMotion ? .linear(duration: 0.01) : preset

    }

    var shouldAnimate: Bool { !reduceMotion }

}

// Usage in SwiftUI views:

// @Environment(MotionManager.self) var motion

// withAnimation(motion.spring(AppSpring.smooth)) { ... }

```
When reduced motion is enabled:
- All springs become effectively instant `.linear(duration: 0.01)`)
- Fade animations still play (opacity changes are accessibility-safe)
- Parallax disabled (cover photo stays static via GeometryReader check)
- Pulse animations disabled (NOW indicator, pill dot)
- Haptics still fire (haptics are separate from motion preference)
- Layout transitions still work (items don't jump — they just move faster)
### Animation Performance Budget
| Rule                         | Limit                                                         |
| ---------------------------- | ------------------------------------------------------------- |
| Simultaneous animated values | Max 8 per screen                                              |
| Animation frame time         | <16ms (60fps) or <8ms (120fps ProMotion)                      |
| Only animate                 | `.scaleEffect`, `.offset`, `.opacity`, `.rotationEffect`      |
| Never animate                | `.frame` dimensions directly (use `.transition` instead)      |
| Layout animations            | Use `withAnimation` + SwiftUI implicit layout (render server) |
| List item animations         | Max 10 visible items animated at once in LazyVStack           |
---
## V1 vs V2 UI Distribution
### V1 Screens (2-week build)
| Screen                                               | Priority  | Review Changes                                                                              |
| ---------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------- |
| Splash screen                                        | Must have | —                                                                                           |
| Sign In / Sign Up                                    | Must have | —                                                                                           |
| Trips List (empty + with trips)                      | Must have | Avatar replaces tab bar, FAB safe area                                                      |
| Create Trip (bottom sheet)                           | Must have | —                                                                                           |
| Trip Detail (timeline with all components)           | Must have | 160px cover (was 220), full collapse, two-line collapsed headers, diamond dots for bookings |
| Speed Dial FAB                                       | Must have | Safe area insets, 30% scrim (was 40%)                                                       |
| Add Place (bottom sheet)                             | Must have | —                                                                                           |
| Add Booking (single screen, chip selector + 6 forms) | Must have | Horizontal chips replace 2x3 grid, keyboard handling, form validation                       |
| Bookings Screen (grouped + email forwarding)         | Must have | Empty state added, offset booking-type colors                                               |
| Review Forwarded Bookings                            | Must have | —                                                                                           |
| Map View (pins + day filter + detail sheet)          | Must have | Diamond booking pins, empty state added                                                     |
| Place Detail (bottom sheet, Essentials data)         | Must have | Action hierarchy: primary/secondary/tertiary                                                |
| Edit Trip (modal)                                    | Must have | —                                                                                           |
| Profile (pushed from avatar, no tab bar)             | Must have | Pushed screen, not a tab                                                                    |
### V2 UI Additions
| Screen                      | What Changes                                                             |
| --------------------------- | ------------------------------------------------------------------------ |
| Place Detail                | Pro data appears (rating, reviews, hours, about) — cache fills over time |
| Trip Stories Share Composer | New screen — pick photo + reaction + format + share                      |
| Day Story Composer          | New screen — multi-card story preview + share                            |
| Checklist Screen            | New screen — pushed from new pill                                        |
| Notes Screen                | New screen — pushed from new pill                                        |
| Budget Screen               | New screen — pushed from new pill                                        |
| Speed Dial                  | Gains 3 new options (To-do, Note, Expense)                               |
| Pills row                   | 3 disabled pills become active                                           |
| Onboarding                  | 3-screen carousel before Trips List                                      |
| Flight tracking badges      | Status pills on flight booking cards                                     |
| Trip sharing                | "Share" action on trip detail header                                     |
### V3+ UI Additions
| Screen                             | What Changes                                  |
| ---------------------------------- | --------------------------------------------- |
| Viator discovery                   | "Explore" section or tab for tours/activities |
| Car rental / flight / hotel search | Search + results screens                      |
| Journal                            | Journal list + editor screens                 |
| Trip Highlight Reel                | Multi-day curated sharing                     |
| Cheap flight alerts                | Alert cards in trip + notification            |
| Offline indicator                  | Status bar when offline + cached badge        |

