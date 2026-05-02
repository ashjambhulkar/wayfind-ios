# TripWeave V1 — UI Wireframes (Expo React Native)

> **Overview:** Complete wireframe document for all 15 V1 screens with exact dimensions, colors, typography, component breakdowns, animation specifications (react-native-reanimated), haptic pairings (expo-haptics), empty states, and accessibility notes. Adapted from the UI Design Specification for Expo React Native. This is the definitive visual reference for V1 implementation.

## Implementation checklist

_No separate tasks in the source plan — wireframes are the deliverable._

---

## Design System Quick Reference

```
COLORS (Light)                          COLORS (Dark)
Background:    #FDF8F0 (warm cream)     Background:    #0F0F0F
Surface:       #FFFFFF (white cards)    Surface:       #1A1A1A
Primary:       #C26F4B (terracotta)     Primary:       #D4845F
Primary Light: #F4E8E0                  Primary Light: #2A1F1A
Text Primary:  #1A1A1A                  Text Primary:  #F5F5F5
Text Secondary:#57534E (WCAG AA 6.1:1)  Text Secondary:#D6D3D1
Text Tertiary: #78716C (WCAG AA 4.6:1)  Text Tertiary: #A8A29E
Divider:       #F3EDE4                  Divider:       #2A2A2A
Success:       #059669                  Warning:       #D97706
Error:         #DC2626                  Accent:        #E8A87C
DAY COLORS (cycle for Day 8+)
Day 1: #4A90D9  Day 2: #D4845F  Day 3: #059669  Day 4: #D97706
Day 5: #8B5CF6  Day 6: #EC4899  Day 7: #06B6D4
BOOKING KIND COLORS (11 kinds)
flight: #3B82F6   lodging: #A855F7   restaurant: #C26F4B
car: #0891B2      train: #047857     bus: #65A30D
ferry: #0284C7    cruise: #7C3AED    concert: #DB2777
theater: #9333EA  tour: #CA8A04
TYPOGRAPHY (system font per platform)
Screen Title:   34px  Bold       Section Header: 20px  SemiBold
Card Title:     17px  SemiBold   Body:           17px  Regular
Caption:        12px  Regular    Small:          11px  Medium
Button:         17px  SemiBold
SPACING (4px base)
xs: 4   sm: 8   md: 12   lg: 16   xl: 24   2xl: 32   3xl: 48
CORNER RADII
Small: 8   Medium: 12   Large: 16   XLarge: 24   Full: 9999
SHADOWS
Subtle: { shadowOffset: {width:0, height:1}, shadowOpacity:0.06, shadowRadius:3 }
Medium: { shadowOffset: {width:0, height:4}, shadowOpacity:0.08, shadowRadius:12 }
Strong: { shadowOffset: {width:0, height:8}, shadowOpacity:0.12, shadowRadius:24 }
ICONS: Lucide React Native (cross-platform, replaces SF Symbols)
attraction: Star       restaurant: Utensils     lodging: BedDouble
transport: Car         shopping: ShoppingBag    nightlife: Wine
nature: Leaf           custom: MapPin           flight: Plane
train: TrainFront      bus: Bus                 ferry: Ship
cruise: Sailboat       concert: Music           theater: Drama
tour: Ticket
```

---

## Screen 1: Splash Screen

**Duration:** 1-2 seconds. No spinner, no progress bar.

```
┌─────────────────────────────────────┐
│                                     │
│                                     │
│                                     │
│                                     │
│                                     │
│            [App Logo]               │   Terracotta (#C26F4B)
│                                     │   64px square
│           TripWeave                 │   20px, SemiBold
│                                     │   Text Secondary color
│                                     │
│                                     │
│                                     │
│                                     │
└─────────────────────────────────────┘
Background: #FDF8F0 (warm cream)
```

**Implementation:** `expo-splash-screen` config in `app.json`. Background color set to `#FDF8F0`. Logo centered. No custom animation — splash screen hides when app is ready `SplashScreen.hideAsync()`).

---

## Screen 2: Sign In

**Emotion:** "Welcome back, traveler."

```
┌─────────────────────────────────────┐
│                                     │
│            [App Logo]               │   64px, terracotta
│                                     │
│       Welcome back                  │   28px, SemiBold, TextPrimary
│       Sign in to continue           │   15px, TextSecondary
│           planning                  │
│                                     │
│   ┌─────────────────────────────┐   │
│   │  Mail icon   Email          │   │   48px height, 12px radius
│   └─────────────────────────────┘   │   white bg, 1px #F3EDE4 border
│                                 12px│
│   ┌─────────────────────────────┐   │
│   │  Lock icon   Password       │   │   48px height, 12px radius
│   └─────────────────────────────┘   │
│                                     │
│   ┌─────────────────────────────┐   │
│   │         Sign In             │   │   52px height, 16px radius
│   └─────────────────────────────┘   │   Terracotta bg, white text
│                                     │   Full-width, SemiBold 17px
│   ──────────── or ────────────      │   13px TextTertiary
│                                     │
│   ┌─────────────────────────────┐   │
│   │  G icon  Continue with Google│   │   48px, white bg, 1px border
│   └─────────────────────────────┘   │
│   ┌─────────────────────────────┐   │
│   │  A icon  Continue with Apple │   │   48px, black bg, white text
│   └─────────────────────────────┘   │
│                                     │
│   Don't have an account? Sign up    │   15px, "Sign up" in terracotta
│                                     │
└─────────────────────────────────────┘
Background: #FDF8F0
Padding: 32px horizontal
```

**Animation — Empty State Entrance:**

```
On mount (staggered):
  Logo:     opacity 0→1, translateY -20→0    delay: 0ms
  Title:    opacity 0→1                      delay: 100ms
  Inputs:   opacity 0→1, translateY 10→0     delay: 200ms
  CTA:      opacity 0→1, translateY 10→0     delay: 300ms
  Social:   opacity 0→1                      delay: 400ms
Spring: withSpring({ damping: 20, stiffness: 200 })  // smooth preset
```

**Haptic:** None (passive display).

---

## Screen 3: Sign Up

Same layout as Sign In with:

- Title: "Create your account" / "Start planning adventures"

- Name field added above email (same 48px input style)

- Footer: "Already have an account? Sign in"

- Same staggered entrance animation

---

## Screen 4: Trips List — Empty State

**Emotion:** "Your next adventure starts here."

```
┌─────────────────────────────────────┐
│ My Trips                      [AJ] │   Large title 34px Bold
│                                     │   [AJ] = 28px avatar circle
├─────────────────────────────────────┤   terracotta bg, white initials
│                                     │   Tap → pushes to Profile
│                                     │
│                                     │
│         ┌─────────────────┐         │
│         │                 │         │
│         │   Globe + Plane │         │   Simple illustration
│         │   illustration  │         │   (warm-toned line art)
│         │                 │         │
│         └─────────────────┘         │
│                                     │
│       Where to next?                │   24px, SemiBold, centered
│                                     │
│       Plan your first trip and      │   15px, TextSecondary
│       keep everything in            │   centered, max 260px width
│       one place.                    │
│                                     │
│       ┌────────────────────┐        │
│       │  + Plan a Trip      │        │   Terracotta bg, white text
│       └────────────────────┘        │   48px height, 16px radius
│                                     │
└─────────────────────────────────────┘
Background: #FDF8F0
```

**Animation — Empty State Entrance (staggered):**

```
Illustration: scale 0.8→1.0, opacity 0→1     withSpring(bouncy)  delay: 100ms
Title:        opacity 0→1                     withTiming(200ms)   delay: 200ms
Subtitle:     opacity 0→1                     withTiming(200ms)   delay: 300ms
CTA:          opacity 0→1, translateY 20→0    withSpring(smooth)  delay: 400ms
```

---

## Screen 5: Trips List — With Trips

**Emotion:** "Look at all these adventures!"

```
┌─────────────────────────────────────┐
│ My Trips                      [AJ] │   Large title + avatar
│ ┌─────────────────────────────┐     │
│ │ Search icon  Search trips... │     │   Rounded-full, 40px height
│ └─────────────────────────────┘     │   warm cream bg (#FDF8F0)
├─────────────────────────────────────┤
│                                     │
│  YOUR CURRENT TRIP                  │   11px, uppercase, TextTertiary
│                                     │   letter-spacing: 1.5px
│  ┌─────────────────────────────┐    │
│  │                             │    │
│  │  [Destination photo]        │    │   Full-width, 180px height
│  │                             │    │   24px radius (XLarge)
│  │                             │    │
│  │  ┌───────────────────┐      │    │
│  │  │ Day 3 of 7        │      │    │   Pill: white bg, 8px radius
│  │  └───────────────────┘      │    │   positioned bottom-left
│  │                             │    │   over gradient overlay
│  │  Trip to Paris              │    │   24px Bold, white text
│  │  Mar 12-18                  │    │   13px, white at 80% opacity
│  │                             │    │
│  └─────────────────────────────┘    │   Gradient: transparent→black60%
│                                     │
│  UPCOMING                          │   11px uppercase TextTertiary
│                                     │
│  ┌──────────┐ ┌──────────┐ ┌─────  │   Horizontal FlatList
│  │ [Photo]  │ │ [Photo]  │ │       │   160px wide, 200px tall
│  │          │ │          │ │       │   16px radius, shadow-subtle
│  │ Tokyo    │ │ Barcelona│ │       │
│  │ Apr 2-9  │ │ May 15   │ │       │   17px SemiBold (name)
│  │ In 12d   │ │ In 44d   │ │       │   13px TextSecondary (dates)
│  │ 8 places │ │ 3 places │ │       │   13px Terracotta (countdown)
│  └──────────┘ └──────────┘ └─────  │   11px TextTertiary (count)
│                                     │
│  PAST TRIPS                     ▼  │   Collapsed by default
│                                     │   Tap to expand (Accordion)
│                                     │
│                           ┌──────┐  │
│                           │  +   │  │   56px, terracotta bg
│                           └──────┘  │   white "+" icon (Plus)
│                                     │   shadow-medium
└─────────────────────────────────────┘   16px from right, 16px above
                                          safe area bottom
```

**When no destination photo:** Show warm gradient placeholder.

```
Gradient pairs (based on name hash % 4):
1. #C26F4B → #E8A87C  (terracotta sunset)
2. #4A90D9 → #93C5FD  (ocean blue)
3. #059669 → #6EE7B7  (forest green)
4. #D97706 → #FCD34D  (golden hour)
```

**Animation — Trip Card Press:**

```
User presses trip card (Pressable):
  onPressIn:   scale 1.0→0.97   withSpring(snappy)
               shadow subtle→medium
  onPressOut:  scale 0.97→1.0   withSpring(snappy)
               shadow medium→subtle
Haptic: Haptics.impactAsync(ImpactFeedbackStyle.Light)
```

**Animation — FAB:**

```
FAB idle: static, shadow-medium, no animation
FAB tap: see Screen 7 (Trip Detail) for Speed Dial fan-out
```

---

## Screen 6: Create Trip (Bottom Sheet)

**Emotion:** "Starting a new adventure is effortless."

```
  ┌─────────────────────────────────┐
  │                                 │   Dimmed background (scrim 40%)
  │       (Trips List behind)       │
  │                                 │
  ├─────────────────────────────────┤   Bottom sheet starts here
  │  ─── ───                        │   Handle: 36px wide, 5px tall
  │                                 │   #D1D1D6, radius 2.5
  │  Plan a New Trip                │   24px SemiBold
  │                                 │
  │  Where are you going?           │   13px TextSecondary (label)
  │  ┌───────────────────────────┐  │
  │  │  Search icon  Search...   │  │   48px, 12px radius
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │   Autocomplete results
  │  │  MapPin  Paris, France    │  │   appear below as rows
  │  │  MapPin  Paris, Texas     │  │   16px padding each
  │  │  MapPin  Paris, Ontario   │  │   Dividers between
  │  └───────────────────────────┘  │
  │                                 │
  │  When?                          │   13px TextSecondary
  │  ┌────────────┐ ┌────────────┐  │
  │  │ Cal  Start │ │ Cal  End   │  │   Side-by-side date pickers
  │  │ Mar 12     │ │ Mar 18     │  │   48px, 12px radius each
  │  └────────────┘ └────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │   Start Planning  →       │  │   Terracotta bg, white text
  │  └───────────────────────────┘  │   52px, 16px radius, full-width
  │                                 │   Disabled until destination+dates
  └─────────────────────────────────┘
```

**Bottom Sheet Config (@gorhom/bottom-sheet):**

```
snapPoints: ['60%', '90%']
enablePanDownToClose: true
animationConfigs: { damping: 500, stiffness: 1000, mass: 3 }
handleIndicatorStyle: { backgroundColor: '#D1D1D6', width: 36, height: 5 }
backgroundStyle: { borderTopLeftRadius: 12, borderTopRightRadius: 12 }
```

**Haptic:** `Haptics.impactAsync(Light)` on "Start Planning" tap.

---

## Screen 7: Trip Detail — The Timeline

**THE most important screen.**

```
┌─────────────────────────────────────┐
│ [←]              Trip to Paris      │   Nav bar (visible when
├─────────────────────────────────────┤   header collapsed)
│                                     │
│  ┌─────────────────────────────┐    │
│  │ [Destination photo]         │    │   160px height (collapses to 0)
│  │                             │    │   Parallax at 0.3x scroll
│  │  Trip to Paris              │    │   24px Bold, white
│  │  Mar 12-18                  │    │   13px, white 80%
│  │  ┌────────────────┐         │    │
│  │  │ Day 3 of 7     │         │    │   Status pill, white bg 90%
│  │  └────────────────┘         │    │
│  └─────────────────────────────┘    │   Gradient: clear→black60%
│                                     │
│  ┌──────┐ ┌──────┐ ┌──────┐        │   Quick-access pills
│  │Map   │ │Book 4│ │Soon  │ ...    │   36px height, capsule shape
│  │map   │ │plane │ │      │        │   white bg, shadow-subtle
│  └──────┘ └──────┘ └──────┘        │   Horizontal FlatList
│                                     │
│  EMAIL FORWARDING BANNER            │   Shows when 0 bookings
│  ┌─────────────────────────────┐    │   Primary Light bg (#F4E8E0)
│  │                         ✕   │    │   16px radius, 16px padding
│  │  Mail  Got booking emails?  │    │
│  │  Forward them to            │    │
│  │  ┌───────────────────────┐  │    │
│  │  │ trips+abc@domain  Copy│  │    │   White bg, dashed border
│  │  └───────────────────────┘  │    │   monospace font
│  │  and they appear here       │    │
│  └─────────────────────────────┘    │
│                                     │
│  ┌─────────────────────────────┐    │   STICKY DAY HEADER
│  │ ChevronDown  Day 1 — Sat   │    │   52px expanded, 44px collapsed
│  │              Mar 12         │    │   Day-color left bar (4px)
│  │              3 items        │    │   cream bg (#FDF8F0)
│  └─────────────────────────────┘    │   1px divider when sticky
│                                     │
│  │                                  │   TIMELINE RAIL
│  │  6:30 AM                         │   12px Caption, TextTertiary
│  ◆─┐                                │   Diamond dot (flight=blue)
│  │ ┌───────────────────────────┐    │
│  │ │▌ Plane  AA 1234           │    │   BOOKING CARD
│  │ │▌ JFK → CDG               │    │   4px colored left border
│  │ │▌ 6:30 AM → 8:45 PM       │    │   booking kind color
│  │ │▌ ┌──────────┐             │    │
│  │ │▌ │ XKRF4Q   │             │    │   Conf badge: 11px
│  │ │▌ └──────────┘             │    │   terracotta bg, white text
│  │ └───────────────────────────┘    │   pill shape (9999 radius)
│  │                                  │
│  │  Walk ~20 min                    │   TIME GAP
│  │                                  │   13px TextTertiary
│  │  9:30 PM                         │   centered on rail
│  ◆─┐                                │   Diamond (lodging=violet)
│  │ ┌───────────────────────────┐    │
│  │ │▌ BedDouble  Le Marais     │    │   LODGING BOOKING CARD
│  │ │▌ Check-in 9:30 PM        │    │   Violet left border
│  │ │▌ 5 nights                │    │
│  │ │▌ ┌──────────┐             │    │
│  │ │▌ │ HBK-9928 │             │    │
│  │ └───────────────────────────┘    │
│  │                                  │
│  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐    │   INLINE ADD BUTTON
│  │  ╎  + Add to Day 1         ╎    │   Dashed border, 40px height
│  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘    │   13px TextTertiary, 12px radius
│                                     │
│  ┌─────────────────────────────┐    │   DAY 2 HEADER
│  │ ChevronDown  Day 2 — Sun   │    │
│  │              Mar 13         │    │
│  │              4 items        │    │
│  └─────────────────────────────┘    │
│                                     │
│  │  BedDouble Staying at Le Marais  │   ONGOING BOOKING BANNER
│  │                                  │   Primary Light bg (#F4E8E0)
│  │  9:00 AM                         │   8px radius, 36px height
│  ●─┐                                │   13px TextSecondary
│  │ ┌───────────────────────────┐    │
│  │ │ Star  Eiffel Tower        │    │   ACTIVITY CARD
│  │ │   Champ de Mars, Paris    │    │   NO colored left border
│  │ │   9:00 AM - 11:30 AM      │    │   Circle dot on rail (●)
│  │ └───────────────────────────┘    │   day-color filled
│  │                                  │
│  │  Walk 15 min · Car 4 min         │   GAP with mode estimates
│  │                                  │
│  │  12:15 PM                        │
│  ●─┐                                │
│  │ ┌───────────────────────────┐    │
│  │ │ Utensils  Le Petit Cler   │    │
│  │ │   25 Rue Cler, Paris      │    │
│  │ │   12:15 PM - 1:30 PM      │    │
│  │ └───────────────────────────┘    │
│  │                                  │
│  ...                                │
│                                     │
│  ── NOW ────────────────────────    │   NOW INDICATOR
│     ┌─────┐                         │   "NOW" pill: terracotta bg
│     │ NOW │                         │   white text, 11px SemiBold
│     └─────┘                         │   Line: 1px dashed terracotta/50%
│                                     │
│  ...                                │
│                                     │
│  ┌─────────────────────────────┐    │   IDEAS SECTION
│  │ Lightbulb  Ideas            │    │
│  │            2 saved places   │    │
│  └─────────────────────────────┘    │
│  │ ┌───────────────────────────┐    │
│  │ │ MapPin  Sainte-Chapelle   │    │   No time, TextTertiary
│  │ │   1st Arrondissement      │    │   Long-press → "Assign to Day"
│  │ └───────────────────────────┘    │
│                                     │
│                         ┌──────┐    │   SPEED DIAL FAB
│                         │  +   │    │   56px, terracotta
│                         └──────┘    │   shadow-medium
└─────────────────────────────────────┘   16px right, 16px above safe area
```

**Component Dimensions:**

```
TIMELINE RAIL
  Vertical line: 2px wide, #E5E7EB
  Position: 20px from left edge
  Activity dots: ● 10px circle, filled with day-color
  Booking dots:  ◆ 10px diamond, filled with booking-kind color
  Connector: 12px horizontal line from dot to card
ACTIVITY CARD
  Background: white (Surface)
  Shadow: subtle
  Corner radius: 12px
  Padding: 12px vertical, 16px horizontal
  Left margin: 40px (space for rail)
BOOKING CARD
  Same as activity card PLUS:
  Left border: 4px, booking-kind color
  Conf badge: 11px Small, terracotta bg, white text, 9999 radius
DAY SECTION HEADER
  Expanded: 52px height
  Collapsed: 44px (two-line: day info + content preview)
  Left bar: 4px, day-color, full height
  Background: #FDF8F0 (cream)
  Chevron: 16px, rotates 0→-90 on collapse
```

**Animation — Cover Photo Parallax Collapse:**

```
const scrollHandler = useAnimatedScrollHandler({
  onScroll: (event) => {
    scrollY.value = event.contentOffset.y;
  },
});
const headerStyle = useAnimatedStyle(() => {
  const height = interpolate(scrollY.value, [0, 160], [160, 0], Extrapolation.CLAMP);
  const opacity = interpolate(scrollY.value, [0, 120], [1, 0], Extrapolation.CLAMP);
  const translateY = interpolate(scrollY.value, [0, 160], [0, -48], Extrapolation.CLAMP);  // 0.3x parallax
  const scale = interpolate(scrollY.value, [0, 160], [1, 1.05], Extrapolation.CLAMP);
  return { height, opacity, transform: [{ translateY }, { scale }] };
});
```

**Animation — Day Section Collapse/Expand:**

```
User taps header:
  Chevron rotation: withSpring({ damping: 15, stiffness: 200 })  // snappy
    0° (expanded) ↔ -90° (collapsed)
  Content: FadeIn/FadeOut, 200ms
  Height: Layout animation via LayoutAnimation.configureNext()
Haptic: Haptics.selectionAsync()
```

**Animation — Speed Dial FAB Fan-Out:**

```
User taps FAB (+):
  FAB icon: "+" rotates 45° to "✕"       withSpring(snappy)
  FAB scale: 1.0→0.95→1.0                withSpring(bouncy)
  Mini-FAB 1 (MapPin "Add Activity"):
    offset: from FAB center → final (0, -72)
    scale: 0→1.0                          withSpring(bouncy)
    opacity: 0→1
  Mini-FAB 2 (Plane "Add Booking"):
    same animation
    delay: 60ms                           staggered
  Text labels: opacity 0→1               withTiming(150ms, delay: 100ms)
  Scrim: opacity 0→0.3                   withTiming(250ms)
Haptic: Haptics.impactAsync(Medium) on FAB tap
Dismiss (tap scrim or ✕):
  Reverse order — items 2 then 1 collapse back
  FAB rotation back to 0°
  Scrim fades out
Total duration: ~400ms
```

**Animation — NOW Indicator Pulse:**

```
Continuous loop (useAnimatedStyle):
  opacity: interpolate(progress.value, [0, 0.5, 1], [1, 0.6, 1])
  scale:   interpolate(progress.value, [0, 0.5, 1], [1, 1.02, 1])
progress driven by: withRepeat(withTiming(1, { duration: 2000 }), -1, true)
Respect reduced motion: if reduceMotion, set static opacity 1, scale 1
```

---

## Screen 8: Add Activity (Bottom Sheet)

```
  ┌─────────────────────────────────┐
  │  ─── ───                        │
  │                                 │
  │  Add to Day 2 — Mar 13    ✕    │   Day picker (tappable)
  │                                 │   13px TextSecondary
  │  ┌───────────────────────────┐  │
  │  │  Search  Search places... │  │   48px, 12px radius
  │  └───────────────────────────┘  │
  │                                 │
  │  YOUR IDEAS                     │   11px uppercase TextTertiary
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ MapPin Sainte-Chapelle  + │  │   Wishlist items
  │  │   1st Arrondissement      │  │   "+" is terracotta circle 28px
  │  ├───────────────────────────┤  │   Tap + → instant add to day
  │  │ MapPin Shakespeare & Co + │  │   Long-press row → detail form
  │  │   5th Arrondissement      │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ────────── or search ────────  │   11px TextTertiary divider
  │                                 │
  │  (Search results appear here)   │
  │                                 │
  │  SEARCH RESULTS                 │
  │  ┌───────────────────────────┐  │
  │  │ Star   Musee d'Orsay    + │  │   Results from places-cache
  │  │   1 Rue de la Legion...   │  │   Category auto-detected
  │  ├───────────────────────────┤  │
  │  │ Utensils Cafe de Flore  + │  │
  │  │   172 Boulevard Saint...  │  │
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

**Animation — Quick-Add Pulse:**

```
User taps + on a result:
  + icon: scale 1.0→1.3→0          withSpring(bouncy)
  Row: translateX 0→-50, opacity 1→0    withTiming(300ms)
  New card appears on timeline behind sheet
Haptic: Haptics.impactAsync(Medium)
```

**Bottom Sheet:** `snapPoints={['50%', '92%']}`, same spring config as Create Trip.

---

## Screen 9: Add Booking (Full Screen)

```
┌─────────────────────────────────────┐
│  [←]      Add Booking               │
├─────────────────────────────────────┤
│                                     │
│  ┌────┐┌────┐┌────┐┌────┐┌────┐    │   Horizontal scroll chips
│  │Plane││Bed ││Fork││Car ││Train│   │   60px wide, 44px tall
│  │Flt ││Htl ││Din ││Car ││Trn │    │   Selected: terracotta fill
│  └────┘└────┘└────┘└────┘└────┘    │   Unselected: outline 1px
│              (scrolls → Bus,        │   border, white bg
│               Ferry, Cruise,        │   8px radius
│               Concert, Theater,     │   Icon + 11px label
│               Tour)                 │
│                                     │
│  FLIGHT DETAILS                     │   11px uppercase TextTertiary
│                                     │
│  Airline                            │   13px TextSecondary (label)
│  ┌───────────────────────────────┐  │
│  │  American Airlines            │  │   48px, 12px radius
│  └───────────────────────────────┘  │   white bg, 1px #F3EDE4 border
│                                     │
│  Flight Number                      │
│  ┌───────────────────────────────┐  │
│  │  AA 1234                      │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌──────────────┐ ┌──────────────┐  │   Side by side
│  │ From         │ │ To           │  │
│  │ JFK          │ │ CDG          │  │
│  └──────────────┘ └──────────────┘  │
│                                     │
│  ┌──────────────┐ ┌──────────────┐  │
│  │ Depart       │ │ Arrive       │  │
│  │ Mar 12       │ │ Mar 12       │  │
│  │ 6:30 AM      │ │ 8:45 PM      │  │
│  └──────────────┘ └──────────────┘  │
│                                     │
│  OPTIONAL                      ▼    │   Collapsible section
│  ┌──────────────┐ ┌──────────────┐  │
│  │ Terminal     │ │ Gate         │  │
│  │ 1            │ │ B22          │  │
│  └──────────────┘ └──────────────┘  │
│                                     │
│  Confirmation Number                │
│  ┌───────────────────────────────┐  │
│  │  XKRF4Q                      │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌───────────────────────────────┐  │   Sticky to keyboard top
│  │      Add Flight  →            │  │   Terracotta, white text
│  └───────────────────────────────┘  │   52px, 16px radius
└─────────────────────────────────────┘   Disabled until required filled
```

**Animation — Chip Selection Cross-Fade:**

```
User taps different booking kind chip:
  Old form: opacity 1→0          withTiming(100ms)
  New form: opacity 0→1          withTiming(150ms, delay: 50ms)
No screen navigation — inline swap.
```

**Animation — Save Checkmark:**

```
User taps "Add Flight →":
  Button text: "Add Flight →" → "Added ✓"
  Button bg: terracotta → success green (#059669)
  Duration: withTiming(300ms)
  After 500ms: navigate back
Haptic: Haptics.notificationAsync(NotificationFeedbackType.Success)
```

**Validation Error:**

```
┌───────────────────────────────────┐
│  Flight Number                    │   13px TextSecondary (label)
│  ┌─────────────────────────────┐  │
│  │  AA                          │  │   RED border (1px #DC2626)
│  └─────────────────────────────┘  │
│  Enter a valid flight number      │   13px #DC2626
│                                   │   4px below input
│                                   │   Shake animation: translateX
│                                   │   0→-5→5→-3→3→0 (200ms)
└───────────────────────────────────┘
```

---

## Screen 10: Bookings Screen

```
┌─────────────────────────────────────┐
│  [←]         Bookings               │
├─────────────────────────────────────┤
│                                     │
│  FLIGHTS                            │   11px uppercase TextTertiary
│  ┌─────────────────────────────┐    │   Blue left bar (4px #3B82F6)
│  │▌ Plane  AA 1234             │    │
│  │▌ JFK → CDG · Mar 12        │    │
│  │▌ Conf: XKRF4Q              │    │
│  ├─────────────────────────────┤    │
│  │▌ Plane  AA 891              │    │
│  │▌ CDG → JFK · Mar 18        │    │
│  │▌ Conf: PXLM2R              │    │
│  └─────────────────────────────┘    │
│                                     │
│  LODGING                            │   Violet left bar (#A855F7)
│  ┌─────────────────────────────┐    │
│  │▌ BedDouble  Le Marais Hotel │    │
│  │▌ Mar 12-17 · 5 nights      │    │
│  │▌ Conf: HBK-992841          │    │
│  └─────────────────────────────┘    │
│                                     │
│  DINING                             │   (more sections for each kind
│  ...                                │    that has bookings)
│                                     │
│  ─────────────────────────────      │
│                                     │
│  Mail  FORWARD A BOOKING            │   Email forwarding section
│  ┌─────────────────────────────┐    │   Primary Light bg (#F4E8E0)
│  │  Forward confirmation       │    │   16px radius, 16px padding
│  │  emails to add them         │    │
│  │  automatically:             │    │
│  │  ┌─────────────────────┐    │    │
│  │  │ trips+abc@d...  Copy│    │    │   Monospace font, dashed border
│  │  └─────────────────────┘    │    │   white bg, copy button right
│  │  2 pending · 1 needs review │    │   13px TextSecondary
│  │  Review →                   │    │   13px terracotta, tappable
│  └─────────────────────────────┘    │
│                                     │
└─────────────────────────────────────┘
```

**Empty State (0 bookings):**

```
│        ┌───────────────┐            │
│        │ Plane BedDouble│            │   Simple illustration
│        └───────────────┘            │
│                                     │
│     No bookings yet                 │   20px SemiBold, centered
│                                     │
│     Add flights, hotels, and        │   15px TextSecondary
│     reservations to keep            │   centered, max 260px
│     everything in one place.        │
│                                     │
│     ┌──────────────────┐            │
│     │  + Add a Booking  │            │   Terracotta outline CTA
│     └──────────────────┘            │
│                                     │
│  (forwarding section still shows)   │
```

**Animation — Copy Email Flash:**

```
User taps Copy button:
  Icon: Copy → Check          cross-fade withTiming(150ms)
  Background: flash white     opacity 0→0.3→0 withTiming(300ms)
  After 1.5s: Check → Copy    cross-fade back
Haptic: Haptics.notificationAsync(Success)
Toast: "Copied!" slides up from bottom, 2s auto-dismiss
```

---

## Screen 11: Map View

```
┌─────────────────────────────────────┐
│  [←]            Map                 │
├─────────────────────────────────────┤
│  ┌────────────────────────────┐     │   Day filter chips
│  │ All │ Day 1│ Day 2│ Day 3 │     │   Floating over map
│  └────────────────────────────┘     │   blur bg (if platform supports)
│                                     │   capsule shape, horizontal scroll
│                                     │   "All" = terracotta fill
│          FULL-SCREEN MAP            │   Others = white, 1px border
│                                     │
│        ● 1                          │   Day-colored CIRCLE pin
│                                     │   28px, white number (11px Bold)
│            ● 2                      │
│                                     │
│        ◆ ✈                          │   Kind-colored DIAMOND pin
│                                     │   32px, white icon inside
│    ●─────●─────●                    │   Route polyline
│                                     │   day-color, 40% opacity
│                                     │
│  ┌─────────────────────────────┐    │   Pin tap → bottom sheet
│  │ Star  Eiffel Tower          │    │   Slides up, 30% detent
│  │   Champ de Mars, Paris      │    │   16px top radius, white bg
│  │   9:00 AM - 11:30 AM        │    │
│  │                              │    │
│  │   [Navigate]    [Edit]       │    │   Buttons row
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

**Day filter behavior:**

```
Selected day: full opacity, slightly larger (32px circles / 36px diamonds)
Other days: 20% opacity, normal size
Animation: withSpring(smooth) on pin scale change
```

**Empty State (0 places):**

```
│          MAP (destination centered)  │
│                                      │
│  ┌────────────────────────────┐      │   Floating card, bottom
│  │  Add places to see them    │      │   white bg, shadow-medium
│  │  on the map.               │      │   16px top radius
│  │  ┌──────────────────┐      │      │
│  │  │  + Add a Place    │      │      │   Terracotta outline CTA
│  │  └──────────────────┘      │      │
│  └────────────────────────────┘      │
```

---

## Screen 12: Activity Detail (Bottom Sheet)

```
  ┌─────────────────────────────────┐
  │  ─── ───                        │
  │                                 │
  │  Star  Eiffel Tower             │   20px SemiBold
  │  Champ de Mars, 75007 Paris     │   15px TextSecondary
  │                                 │
  │  ┌────────┐ ┌────────┐         │   Info chips (from place_cache)
  │  │ Clock  │ │ Star   │         │   inline, 8px radius
  │  │ Open   │ │ 4.6    │         │   12px, TextSecondary
  │  │ til 11P│ │ (2,341)│         │
  │  └────────┘ └────────┘         │
  │                                 │
  │  "Iconic iron lattice tower     │   editorialSummary
  │   on the Champ de Mars..."      │   15px TextPrimary
  │   Read more                     │   3-line max, "Read more" link
  │                                 │
  │  GETTING THERE                  │   11px uppercase TextTertiary
  │  Walk 15m  Car 4m  Bike 8m     │   Haversine estimates
  │  Train 12m                      │   13px TextSecondary
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │    MapPin  Navigate       │  │   PRIMARY: terracotta bg
  │  └───────────────────────────┘  │   white text, full-width, 48px
  │                                 │
  │  ┌──────────┐  ┌──────────┐    │
  │  │ Pencil   │  │ Calendar │    │   SECONDARY: outline style
  │  │ Edit     │  │ Move     │    │   44px, side by side
  │  └──────────┘  └──────────┘    │   1px border, 8px radius
  │                                 │
  │  Delete                         │   TERTIARY: text-only, #DC2626
  │                                 │   15px, centered, no chrome
  └─────────────────────────────────┘
```

**Bottom Sheet:** `snapPoints={['45%', '80%']}`, same spring config.

---

## Screen 13: Edit Trip (Modal)

```
┌─────────────────────────────────────┐
│  Cancel           Edit Trip    Save │   Nav bar with Cancel + Save
├─────────────────────────────────────┤   Save = terracotta text
│                                     │
│  ┌─────────────────────────────┐    │
│  │                             │    │   Cover photo (tappable)
│  │    [Current cover photo]    │    │   160px height, 16px radius
│  │         Camera icon         │    │   Camera icon overlay
│  │      Change Photo           │    │   Tap → expo-image-picker
│  └─────────────────────────────┘    │
│                                     │
│  Trip Name                          │   13px TextSecondary
│  ┌───────────────────────────────┐  │
│  │  Trip to Paris                │  │   48px, 12px radius
│  └───────────────────────────────┘  │
│                                     │
│  Destination                        │
│  ┌───────────────────────────────┐  │
│  │  Paris, France                │  │   With autocomplete
│  └───────────────────────────────┘  │
│                                     │
│  ┌──────────────┐ ┌──────────────┐  │
│  │ Start Date   │ │ End Date     │  │
│  │ Mar 12       │ │ Mar 18       │  │
│  └──────────────┘ └──────────────┘  │
│                                     │
│  Description (optional)             │
│  ┌───────────────────────────────┐  │
│  │  Our spring trip...           │  │   Multiline, 100px min height
│  └───────────────────────────────┘  │
│                                     │
└─────────────────────────────────────┘
```

---

## Screen 14: Profile

```
┌─────────────────────────────────────┐
│ Profile                             │   Large title 34px
├─────────────────────────────────────┤
│                                     │
│  ┌─────────────────────────────┐    │
│  │  ┌────┐                     │    │
│  │  │ AJ │  [amit@email.com](mailto:amit@email.com)     │    │   Avatar: 40px circle
│  │  └────┘  Joined Mar 2026    │    │   terracotta bg, white initials
│  └─────────────────────────────┘    │   13px TextSecondary
│                                     │
│  STATS                              │   From user_stats table
│  ┌────────┐ ┌────────┐ ┌────────┐   │
│  │   5    │ │   3    │ │ 1,204  │   │   Three stat cards
│  │ Trips  │ │ Countries│ │  km   │   │   20px SemiBold (number)
│  └────────┘ └────────┘ └────────┘   │   11px TextTertiary (label)
│                                     │
│  PREFERENCES                        │   11px uppercase TextTertiary
│  ┌─────────────────────────────┐    │
│  │  Sort trips by       Date ▼ │    │   Grouped list cells
│  ├─────────────────────────────┤    │   white bg, 16px radius
│  │  Dark mode          Auto ▼  │    │   Chevron/value on right
│  └─────────────────────────────┘    │
│                                     │
│  ABOUT                              │
│  ┌─────────────────────────────┐    │
│  │  Version               1.0 │    │
│  ├─────────────────────────────┤    │
│  │  Privacy Policy          → │    │
│  ├─────────────────────────────┤    │
│  │  Terms of Service        → │    │
│  └─────────────────────────────┘    │
│                                     │
│  ┌─────────────────────────────┐    │
│  │       Sign Out              │    │   Red text (#DC2626)
│  └─────────────────────────────┘    │   white bg, 16px radius
│                                     │
└─────────────────────────────────────┘
```

---

## Screen 15: Notification Permission Pre-Prompt

**Shown before system dialog. Triggered on first email forward, NOT on first launch.**

```
┌─────────────────────────────────────┐
│                                     │
│            Mail icon                │   48px, terracotta
│                                     │
│  We'll notify you when your         │   20px SemiBold, centered
│  booking is ready                   │
│                                     │
│  Get alerts when we parse your      │   15px TextSecondary
│  forwarded bookings, and when       │   centered, max 280px
│  your trip is about to start.       │
│                                     │
│  ┌───────────────────────────────┐  │
│  │     Enable Notifications      │  │   Terracotta CTA, 52px
│  └───────────────────────────────┘  │   Triggers system dialog
│                                     │
│  Not now                            │   TextTertiary, 15px
│                                     │   Skips, doesn't ask again
└─────────────────────────────────────┘   until next trigger event
```

---

## Animation Quick Reference (Reanimated Equivalents)

### Spring Presets

```typescript
// theme/animations.ts
export const springs = {
  snappy: { damping: 15, stiffness: 200, mass: 0.5 },    // ~200ms, minimal overshoot
  smooth: { damping: 20, stiffness: 200, mass: 1 },      // ~350ms, gentle overshoot
  bouncy: { damping: 12, stiffness: 150, mass: 1 },      // ~400ms, visible bounce
  heavy:  { damping: 20, stiffness: 300, mass: 1.5 },    // ~300ms, no overshoot
};
```

### Complete Animation Inventory

| Animation              | Trigger              | Values                                        | Spring             | Haptic                       |
| ---------------------- | -------------------- | --------------------------------------------- | ------------------ | ---------------------------- |
| Button press           | onPressIn/Out        | scale 1→0.96, opacity 1→0.9                   | snappy             | `impactAsync(Light)`         |
| FAB tap                | onPress              | rotation 0→45°, scale pulse                   | bouncy             | `impactAsync(Medium)`        |
| FAB fan-out            | FAB opens            | offset + scale + opacity, stagger 60ms        | bouncy             | (on FAB tap)                 |
| Copy flash             | clipboard write      | icon swap + bg flash                          | timing 150ms       | `notificationAsync(Success)` |
| Save checkmark         | save success         | text + bg color change                        | timing 300ms       | `notificationAsync(Success)` |
| Quick-add              | tap + on result      | scale 1→1.3→0, row slide out                  | bouncy             | `impactAsync(Medium)`        |
| Card enter             | item added           | translateX + opacity + scale 0.95→1           | smooth             | `impactAsync(Light)`         |
| Card delete            | swipe past threshold | translateX to edge + opacity→0                | heavy              | `notificationAsync(Warning)` |
| Card undo              | undo tapped          | translateX from edge + opacity→1              | smooth             | `impactAsync(Light)`         |
| Day collapse           | header tap           | chevron rotation + content fade               | snappy             | `selectionAsync()`           |
| Drag start             | long-press           | scale 1→1.03, shadow increase, others dim     | snappy             | `impactAsync(Medium)`        |
| Drag drop              | release              | scale 1.03→1, shadow decrease                 | heavy              | `impactAsync(Light)`         |
| Parallax header        | scroll               | height, opacity, translateY, scale            | gesture-driven     | None                         |
| NOW pulse              | continuous           | opacity + scale oscillation                   | timing 2000ms loop | None                         |
| Pill dot pulse         | continuous           | scale 1→1.5→1 + opacity                       | timing 2000ms loop | None                         |
| Auto-scroll            | timeline mount       | scrollTo with 600ms duration                  | timing             | None                         |
| Badge count            | realtime update      | old: scale up + fade, new: scale 0→1          | snappy/bouncy      | None                         |
| Trip card press        | press/release        | scale 1→0.97→1 + shadow                       | snappy             | `impactAsync(Light)`         |
| Empty state            | mount                | staggered: illustration, title, subtitle, CTA | bouncy/timing      | None                         |
| First booking confetti | one-time event       | 6-8 circles radiate outward, fade 800ms       | timing             | `notificationAsync(Success)` |
| Validation shake       | error                | translateX 0→-5→5→-3→3→0                      | timing 200ms       | `notificationAsync(Error)`   |
| Toast slide            | toast appears        | translateY from bottom + opacity              | smooth             | None                         |

### Reduced Motion

```typescript
import { AccessibilityInfo } from 'react-native';
import { useReducedMotion } from 'react-native-reanimated';
// In any component:
const reduceMotion = useReducedMotion();
// When reduceMotion is true:
// - All springs become instant (duration: 1ms)
// - Fade animations still play (opacity is accessibility-safe)
// - Parallax disabled (static header)
// - Pulse animations disabled (NOW indicator, pill dot)
// - Haptics still fire (separate from motion preference)
// - Layout transitions still work, just faster
```

### Performance Budget

```
Max simultaneous animated values:    8 per screen
Only animate:                        transform (translate, scale, rotate), opacity
Never animate:                       width, height, layout dimensions
Reanimated worklet thread:           keeps animations at 60-120fps
Max visible animated list items:     10 at once
```

---

## Toast System

```
  SUCCESS:
  ┌───────────────────────────────────┐
  │  Check  AA 1234 added to Day 1   │   White bg, shadow-medium
  │  View →                          │   16px radius, 12px padding
  └───────────────────────────────────┘   Slides up from bottom
                                          3-5 second auto-dismiss
  WARNING:
  ┌───────────────────────────────────┐
  │  AlertTriangle  Couldn't read    │   4px amber left border
  │  forwarded email                 │   (#D97706)
  │  Enter manually →               │   5 second auto-dismiss
  └───────────────────────────────────┘
  UNDO:
  ┌───────────────────────────────────┐
  │  Activity deleted                │   "Undo" = terracotta text
  │                         [Undo]   │   5 second auto-dismiss
  └───────────────────────────────────┘   Tap Undo → card reinserts
  ERROR:
  ┌───────────────────────────────────┐
  │  AlertTriangle  Couldn't save.   │   4px red left border
  │  Check your connection.          │   (#DC2626)
  │  [Try Again]                     │   5 second auto-dismiss
  └───────────────────────────────────┘
  Position: 16px from bottom, 16px horizontal padding
  Entrance: translateY from +100, opacity 0→1, withSpring(smooth)
  Exit: translateY to +100, opacity 1→0, withTiming(200ms)
```

---

## Email Forwarding Discovery — 5 Touchpoints

| #   | Location                                     | When Shown                        | Disappears When                          |
| --- | -------------------------------------------- | --------------------------------- | ---------------------------------------- |
| 1   | Timeline banner (below pills)                | 0 bookings on trip, not dismissed | Dismissed / first booking / email copied |
| 2   | Speed Dial footer                            | < 3 total bookings                | 3+ bookings exist                        |
| 3   | InlineAddButton hint ("or forward bookings") | Day has 0 bookings                | Day gets a booking                       |
| 4   | Bookings pill pulse dot                      | 0 bookings on trip                | 1+ booking                               |
| 5   | Success celebration toast                    | First-ever forward parsed         | 4s auto-dismiss                          |

A power user who forwards all bookings sees NONE of these after their first trip.

---

## Badge Dot System

```
  Bookings pill states:
  ┌──────┐
  │Plane 0│  + terracotta pulse dot     → 0 bookings, never forwarded
  └──────┘
  ┌──────┐
  │Plane 4│  (no dot)                   → 4 bookings, all reviewed
  └──────┘
  ┌──────┐
  │Plane 4│  + red dot (8px)            → 2 unreviewed parsed bookings
  └──────┘
  Dot: 8px circle, #DC2626 (red), positioned top-right of pill
  Pulse dot: 6px, terracotta, scale 1→1.3→1 (2s loop)
```

