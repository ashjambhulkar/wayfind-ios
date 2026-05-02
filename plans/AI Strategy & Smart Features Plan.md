# Travel Planner — AI Strategy & Smart Features Plan

> **Overview:** Comprehensive AI strategy with engineering + UI/UX review findings applied. V2a/V2b release split. Engineering safeguards: Google Places validation pipeline, prompt injection protection, heuristic confidence scoring, RLS policies, offline handling, Edge Function latency mitigations, corrected costs ($380/mo at 10K DAU). UX refinements: one-suggestion-per-day rule to prevent timeline overload, collapsed suggestion indicators, conflict badges on cards not banners, contextual day header actions (progressive: Plan → Optimize → Export), single-screen preference input with smart defaults, no floating chat button or AI pill (AI woven into existing surfaces), streaming loading states, auto-apply route optimization with undo toast, one-tap export with smart defaults, accessibility specifications for all AI content.

## Implementation checklist

- [ ] **validation-pipeline** — Pre-V2b: Build Google Places validation pipeline for AI-generated places. findPlaceFromText lookup, replace LLM lat/lng/address with Google verified data, drop hallucinated places, log hallucination rate per destination. Non-negotiable for AI output quality.
- [ ] **route-optimization** — V2a: Build Route Optimizer — on-device TSP nearest-neighbor + 2-opt for 10+ places. Respects time-locked bookings. Auto-apply with undo toast (no confirmation sheet). Zero API cost.
- [ ] **export-google-maps** — V2a: Build Export to Google Maps — one-tap 'Navigate' on day header opens default maps app with all stops. Smart defaults (remember last app choice, infer travel mode from destination type). Only show stop picker if >10 waypoints.
- [ ] **smart-conflict-detection** — V2a: Build Smart Conflict Detection — on-device detection of time overlaps, impossible commutes, closed venues. Amber badge on day header with count. Tap badge → sequential resolution sheet (one conflict at a time). Conflict badges on affected cards (amber dot on rail + card tint).
- [ ] **ai-day-planner** — V2b: Build AI Day Planner — minimal input (auto-set start/end from bookings + optional free text, pace/budget remembered from previous use). Streaming response showing places one-by-one. Google Places validation. Preview → accept. No fake pipeline loading steps.
- [ ] **ai-trip-generator** — V2b: Build AI Trip Generator — single-screen preference input with smart defaults (2 decisions minimum: style + optional free text). Budget/mobility/dietary shown as tappable defaults, not required cards. Google validation → review → bulk insert. ~$0.17/generation.
- [ ] **screenshot-booking** — V2b: Build Screenshot-to-Booking — GPT-4o vision (not mini). Heuristic binary confidence (✅ Verified vs ⚠️ Check). Accessible from Bookings screen (not Speed Dial — keeps FAB to 3 items). ~$0.007/scan.
- [ ] **enhanced-booking-parser** — V2a: Enhance booking parser for multi-language support (prompt tweak, minimal effort). V2b: Add PDF attachment parsing.
- [ ] **smart-suggestions** — V3: Build Smart Suggestions engine — one suggestion per day max (priority: conflict > weather > gap fill). Collapsed single-line indicator by default, expand on tap. On-device for gaps/meals/conflicts. Nearby discoveries via Google Places (batched, cached).
- [ ] **ai-travel-assistant** — V3: Build AI Travel Assistant chat — accessible via Speed Dial '💬 Ask AI' option (no floating chat button). Context-aware with token management (truncate to relevant day, cap 1500 system tokens, sliding 6-message history). Context-aware suggested prompts. Rate limit 30/day. ~$0.003/message.
- [ ] **weather-rescheduling** — V3: Build Weather-Aware Rescheduling — OpenWeatherMap with $40/mo contingency at scale. Deduplicate by destination+date. Proactive push notifications.
- [ ] **ai-infrastructure** — Pre-V2b: Set up AI infrastructure — prompt templates table in Supabase, destination template pre-generation, Upstash rate limiting per feature, Edge Function warmup pings, prompt injection sanitization, RLS on all new tables, offline state detection.

---

## The Paradigm Shift: From Organizer to Intelligent Travel Companion

The current plan treats AI as a V5 afterthought — an "AI trip planner" tacked on months 8-12. This is a strategic mistake. **AI should be the app's nervous system, not a bolted-on feature.** Every competitor already has timeline views and booking management. What none of them do well is _think for the traveler_.

**The new positioning**: "The travel app that plans WITH you."

**Three AI principles for this app:**

1. **AI assists, user decides.** Never auto-apply changes. Always preview → accept/edit → apply. Travelers want control.
2. **AI is context-aware.** Every AI feature knows the full trip: dates, bookings, existing places, weather, time zones, user preferences. No generic suggestions.
3. **AI is invisible when not needed.** No chatbot bubbles on every screen. AI surfaces naturally — in gaps, in suggestions, in one-tap optimizations. Power users discover depth; casual users see magic.

---

## Engineering Safeguards

### Place Validation Pipeline (Critical)

**LLMs hallucinate place names, addresses, and coordinates.** GPT-4o-mini will confidently return places that don't exist, real places with wrong coordinates, and permanently closed venues. Every AI-generated place must be validated before being shown to the user.

**Pipeline (runs in Edge Function after AI generation):**

```
  AI generates place names + categories + approximate times
       │
  For each place:
       │
  ┌────▼──────────────────────────────────────────────┐
  │ Google Places findPlaceFromText                    │
  │   input: place name + destination city             │
  │   fields: name, formatted_address, geometry, types │
  │   (Essentials SKU: $5/1K, first 10K/mo free)      │
  └────┬──────────────────────────────────────────────┘
       │
  ┌────▼───────────────┐     ┌──────────────────────┐
  │ Match found?       │ NO  │ Drop this place.      │
  │ (confidence > 0.7) ├────►│ AI hallucinated it.  │
  └────┬───────────────┘     │ Log for monitoring.  │
       │ YES                 └──────────────────────┘
       │
  ┌────▼──────────────────────────────────────────────┐
  │ Replace AI-generated data with Google's verified: │
  │   - lat/lng → Google's geometry.location          │
  │   - address → Google's formatted_address          │
  │   - name → Google's canonical name                │
  │   - Keep AI's: times, description, category       │
  └────┬──────────────────────────────────────────────┘
       │
  Present validated results to user
```

**Cost impact:** ~$0.005 per place lookup (Essentials SKU). A 6-place day plan = $0.03 validation overhead. A 5-day trip generation (30 places) = $0.15. Added to cost tables below.

**Monitoring:** Track hallucination rate (places dropped / places generated) per destination. If a destination consistently produces >20% drops, consider maintaining a curated place list for top-50 destinations.

### Prompt Injection Protection

User free-text input ("special requests") is never interpolated into the system prompt. Instead, it is passed via the `user` role with clear delimiters, and sanitized before use.

```swift
func sanitizeUserInput(_ input: String) -> String {
    let maxLength = 500
    var trimmed = String(input.prefix(maxLength))
    let patterns: [(String, String)] = [
        ("(?i)ignore\\s+(all\\s+)?previous\\s+instructions", "[filtered]"),
        ("(?i)system\\s*prompt", "[filtered]"),
        ("(?i)\\b(DROP|DELETE|INSERT|UPDATE|ALTER)\\b", "[filtered]")
    ]
    for (pattern, replacement) in patterns {
        trimmed = trimmed.replacingOccurrences(
            of: pattern, with: replacement, options: .regularExpression
        )
    }
    return trimmed
}
```

All AI calls use role separation (server-side Edge Function — client sends sanitized input):

```swift
// Client-side: send sanitized preferences to Edge Function
let params: [String: Any] = [
    "specialRequests": sanitizeUserInput(specialRequests),
    "destination": destination,
    "date": date,
    "pace": pace
]
let response = try await supabase.functions.invoke("ai-plan-day", options: .init(body: params))
```

### Offline Handling

AI features require internet connectivity. The app must handle offline state gracefully:

| Feature                  | Offline Behavior                                                                   |
| ------------------------ | ---------------------------------------------------------------------------------- |
| AI Day Planner           | Button disabled, tooltip: "Requires internet"                                      |
| AI Trip Generator        | Button disabled, tooltip: "Requires internet"                                      |
| Route Optimization       | **Works offline** (on-device computation)                                          |
| Export to Google Maps    | **Works offline** (generates URL, opens on reconnect)                              |
| Smart Conflict Detection | **Works offline** (on-device computation)                                          |
| Screenshot Parser        | Button disabled, tooltip: "Requires internet"                                      |
| AI Travel Assistant      | Chat disabled, show last cached messages read-only                                 |
| Weather Rescheduling     | Uses last cached forecast, note: "Forecast may be outdated"                        |
| Smart Suggestions        | Gap/meal/conflict suggestions work offline (on-device). Nearby discovery disabled. |

Implementation: Check network reachability via `NWPathMonitor` before showing AI-powered buttons. On-device features (route optimization, conflict detection, maps export) always remain available.

```swift
// Services/NetworkMonitor.swift
import Network
@Observable
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    var isConnected = true
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
```

### Edge Function Latency Management

Supabase Edge Functions have 200-500ms cold start latency. Combined with OpenAI API latency (1-3s for GPT-4o-mini), total response time is 2-5 seconds for day planning and 8-20 seconds for full trip generation.

**Mitigations:**

| Strategy             | Implementation                                                                     | Impact                                          |
| -------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------- |
| Streaming responses  | Use OpenAI streaming API, send places to client one-by-one as they generate        | User sees progress, perceived latency drops 60% |
| Edge Function warmup | Periodic ping every 5 minutes from a cron job during peak hours (8 AM - 11 PM UTC) | Eliminates cold starts for 95% of requests      |
| Client-side timeouts | Day Planner: 15s, Trip Generator: 45s, Chat: 10s, Screenshot: 20s                  | Prevents hung UI states                         |
| Optimistic UI        | Show shimmer loading state immediately, animate step indicators                    | User perceives activity                         |
| Retry with backoff   | On timeout: retry once with 1.5x timeout, then show "Try again" button             | Handles transient failures                      |

---

## UX Design Principles (from UI/UX Review)

### The One-Suggestion-Per-Day Rule

The timeline is already the densest screen in the app (sticky day headers, place cards, booking cards with colored borders, ongoing booking banners, time gaps, NOW indicator, inline add buttons, Ideas section). Adding AI suggestions, conflict banners, weather alerts, and meal reminders to this same surface creates a "Christmas tree" of competing visual elements.

**Rule: Maximum one active suggestion per day on the timeline.** Priority order:

1. **Conflict** (safety — time overlap, impossible commute) — amber
2. **Weather** (time-sensitive — rain on outdoor day) — blue
3. **Gap fill** (helpful — "4 hours free") — dashed, subtle
4. **Meal reminder** (convenience — "No lunch planned") — lowest priority
5. **Category balance** ("All restaurants, no sightseeing") — lowest priority

If Day 2 has a time conflict AND a weather warning AND a missing lunch, only the conflict shows. The others surface after the conflict is resolved, or on the next timeline visit.

**Suggestions are collapsed by default:**

```
  │  1:30 PM  Le Petit Cler
  │
  │  ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  │  ╎  ✨ 1 suggestion · 4 hrs free  ╎   ← Single line, tap to expand
  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘     NOT the full 3-place card
  │
  │  6:30 PM  Dinner reservation
```

Expansion reveals the full suggestion card only on tap. This respects the user who doesn't want suggestions right now.

### Contextual Day Header Actions (Progressive)

Don't show "Plan This Day" AND "Optimize Route" AND "Export" simultaneously on a day header. Show one contextual action based on the day's state:

```
  Empty/sparse day (< 3 places):
  ┌────────────────────────────────────┐
  │ ▼  Day 2 — Sat, Mar 12    [✨ Plan]│   ← Plan This Day
  └────────────────────────────────────┘
  3+ unoptimized places:
  ┌────────────────────────────────────┐
  │ ▼  Day 2 — Sat, Mar 12    [🔄 Opt]│   ← Optimize Route
  └────────────────────────────────────┘
  Optimized or manually ordered day:
  ┌────────────────────────────────────┐
  │ ▼  Day 2 — Sat, Mar 12    [📤 Nav]│   ← Navigate / Export
  └────────────────────────────────────┘
  Day with conflicts:
  ┌────────────────────────────────────┐
  │ ▼  Day 2 — Sat, Mar 12    [⚠️ 2] │   ← Conflict badge (overrides all)
  └────────────────────────────────────┘
```

One icon. One action. Context determines which. The user always knows what the next best action is for that day.

### Conflicts Live on Cards, Not Between Them

Conflicts are NOT separate banners taking 60px of vertical space between timeline cards. Instead:

- **Amber dot** on the affected card's timeline rail dot (replaces the normal day-color dot)
- **Subtle amber tint** on the card background
- Tap the card → conflict detail appears in the place detail sheet
- **Amber badge with count** on the day header → tap for sequential resolution

```
  │  9:00 AM
  ●─┐                                ← Normal blue dot
  │ ┌────────────────────────┐
  │ │ ⭐ Eiffel Tower         │       ← Normal card
  │ │   9:00 AM - 11:00 AM   │
  │ └────────────────────────┘
  │
  │  10:30 AM
  ⚠─┐                                ← AMBER dot (conflict)
  │ ┌──────────────────────────┐
  │ │ 🏛️ Louvre          ⚠️    │       ← Amber tint + badge
  │ │   10:30 AM - 12:00 PM    │         Tap → detail sheet shows
  │ │   Overlaps Eiffel Tower  │         conflict + resolution options
  │ └──────────────────────────┘
```

### No AI Pill, No Floating Chat Button

AI features are woven into existing surfaces, not quarantined in a separate section:

| AI Feature            | Where It Lives               | Why There                         |
| --------------------- | ---------------------------- | --------------------------------- |
| Plan This Day         | Day header contextual button | Context: that specific day        |
| AI Trip Generator     | Create Trip flow option      | Context: creating a new trip      |
| Optimize Route        | Day header contextual button | Context: that day's places        |
| Export / Navigate     | Day header contextual button | Context: ready to go              |
| Screenshot-to-Booking | Bookings screen CTA          | Context: managing bookings        |
| AI Travel Assistant   | Speed Dial option "Ask AI"   | Accessible but not always visible |
| Smart Suggestions     | Inline collapsed indicators  | Context: timeline gaps            |

The quick-access pills row stays unchanged from V1:

```
  ┌────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐
  │🗺️  │  │✈️  4 │  │✅    │  │📝    │  │💰    │
  │Map │  │Book  │  │Soon  │  │Soon  │  │Soon  │
  └────┘  └──────┘  └──────┘  └──────┘  └──────┘
```

No AI pill added. Every pill pushes to a single screen. Pattern stays consistent.

### Smart Defaults Over Decision Quizzes

Every AI input flow follows the "2-decision minimum, full customization optional" rule:

- **Day Planner**: Start/end time auto-set from bookings + optional free text. Pace and budget remembered from previous use. User generates in 3 seconds or customizes in 15. Their choice.
- **Trip Generator**: One screen with style selector + optional free text. Budget, mobility, dietary shown as tappable defaults at the bottom — visible but not requiring interaction.
- **Export**: One tap opens default maps app with all stops. Maps app choice and travel mode remembered. Stop picker only shown if >10 waypoints.

### Accessibility Requirements for AI Content

| Requirement    | Implementation                                                                                                                                                                                                                                                  |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| VoiceOver      | AI-generated place cards use `.accessibilityLabel`: name, category, time, description. Loading state announces "Planning in progress" via `.accessibilityValue` and "Plan complete, N places" via `UIAccessibility.post(notification: .announcement)` on finish |
| Reduced motion | Check `UIAccessibility.isReduceMotionEnabled`. Suggestion indicators appear instantly. Streaming places appear without animation. Route optimization result appears without card reorder animation                                                              |
| Dynamic Type   | AI-generated descriptions scale automatically via SwiftUI text styles. Views use flexible height (no fixed `.frame`). Truncation only with `.lineLimit` + "Read more" affordance                                                                                |
| Color + icon   | Conflict badges use amber color AND `exclamationmark.triangle.fill` SF Symbol. Verified fields use green AND `checkmark.circle.fill`. "Please check" uses amber AND `questionmark.circle.fill`. Never color-only indicators                                     |

---

## Feature 1: AI Day Planner — "Plan My Day"

**Category: Differentiator | Version: V2 | Complexity: High**

The flagship AI feature. A traveler arrives in Paris, Day 2 is mostly empty except a hotel checkout isn't until 11 AM and dinner at 8 PM. They tap "Plan My Day" and AI fills 11 AM to 8 PM with a beautifully paced day.

### User Flow

**Entry:** Day header contextual button [✨ Plan] (appears when day has < 3 places). Opens as bottom sheet.

**Design principle:** 2 decisions minimum, full customization optional. Most users generate in 3 seconds.

```
  ┌─────────────────────────────────┐
  │  ─── ───                        │
  │                                 │
  │  ✨ Plan Day 2 — Sun, Mar 13   │  ← 20px SemiBold
  │                                 │
  │  11:00 AM → 7:30 PM             │  ← Auto-set from bookings
  │  After hotel checkout,           │     (hotel checkout 11 AM,
  │  before dinner at 8:00 PM       │      dinner reservation 8 PM)
  │  [Change times]                  │  ← Tap to override, but most won't
  │                                 │
  │  Anything specific?             │
  │  ┌───────────────────────────┐  │
  │  │ "Seine river walk, good   │  │  ← Optional free text
  │  │  coffee, impressionist    │  │     Placeholder shows example
  │  │  art"                     │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │    ✨ Generate Plan        │  │  ← Terracotta CTA
  │  └───────────────────────────┘  │
  │                                 │
  │  Balanced · $$ · Moderate walk  │  ← Tappable defaults line
  │                                 │     Remembered from last use
  │                                 │     or inferred from trip data.
  │                                 │     Tap any to change, but NOT
  │                                 │     required to interact.
  └─────────────────────────────────┘
```

**Tappable defaults line** expands on tap to reveal full controls (pace pills, budget pills, interest tags). Collapsed by default because 80% of users will use the defaults after their first generation. First-time users see the expanded version with "Balanced" pre-selected.

### AI Generation (Loading State — Streaming)

No fake pipeline steps. Places stream in one-by-one as the LLM generates them.

```
  ┌─────────────────────────────────┐
  │  ✨ Planning your day...        │
  ├─────────────────────────────────┤
  │                                 │
  │  11:00  ⭐ Sainte-Chapelle      │  ← First place appears at ~1.5s
  │         Gothic stained glass    │     Real content replacing shimmer
  │         ~45 min · Free on Sun   │
  │                                 │
  │  12:15  🍴 Café de Flore        │  ← Second place at ~2.5s
  │         Classic Parisian café   │
  │         ~1 hr · $$              │
  │                                 │
  │  ┌───────────────────────────┐  │  ← Shimmer placeholder for next
  │  │  ░░░░░░░░░░░░░░░░░░░░░░  │  │     place still generating
  │  │  ░░░░░░░░░░░░░░░░░░      │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  Usually 3-5 seconds total      │  ← Honest time estimate
  │                                 │
  └─────────────────────────────────┘
  When complete (all places streamed):
  ┌─────────────────────────────────┐
  │  ✨ Your Day 2 Plan         ↻  │  ← ↻ = Regenerate
  ├─────────────────────────────────┤
  │                                 │
  │  🕐 8.5 hrs · 📍 6 places      │  ← Summary line
  │  🚶 2.8 km · ~$45              │
  │                                 │
  │  [Full place list as before]    │
  │                                 │
  │  ┌────────────┐ ┌────────────┐  │
  │  │  ✏️ Edit    │ │ ✓ Add All  │  │
  │  └────────────┘ └────────────┘  │
  └─────────────────────────────────┘
```

**Why streaming is better:** The first place appearing at 1.5 seconds IS the loading state. Real content replacing placeholder content is the Apple loading pattern — it gives the user something to read while the rest generates. No fake progress steps needed.

### AI Result Preview

```
  ┌─────────────────────────────────┐
  │  ✨ Your Day 2 Plan         ↻  │  ← ↻ = Regenerate
  ├─────────────────────────────────┤
  │                                 │
  │  🕐 Total: 8.5 hours           │
  │  📍 6 places · 🚶 2.8 km walk  │
  │  💰 ~$45 estimated              │
  │                                 │
  │  11:00  ⭐ Sainte-Chapelle      │
  │         Gothic stained glass    │  ← AI-generated blurb
  │         ~45 min · Free on Sun   │
  │                                 │
  │  12:00  🚶 8 min walk           │
  │                                 │
  │  12:15  🍴 Café de Flore        │
  │         Classic Parisian café   │
  │         ~1 hr · $$              │
  │                                 │
  │  13:30  🚶 12 min walk          │
  │                                 │
  │  13:45  🏛️ Musée d'Orsay       │
  │         Impressionist art       │
  │         ~2 hr · €16             │
  │                                 │
  │  16:00  🚶 15 min walk          │
  │                                 │
  │  16:15  🌿 Jardin du Luxembourg │
  │         Gardens & palace        │
  │         ~1 hr · Free            │
  │                                 │
  │  17:30  🚶 5 min walk           │
  │                                 │
  │  17:45  ☕ Coutume Café          │
  │         Specialty coffee        │
  │         ~45 min · $             │
  │                                 │
  │  18:30  🚶 10 min walk          │
  │                                 │
  │  18:45  🌅 Seine River Walk     │  ← Matched user request!
  │         Pont des Arts views     │
  │         ~45 min · Free          │
  │                                 │
  │  19:30  → Dinner at Le Petit    │  ← Shows existing booking
  │           Cler (8:00 PM)        │     as anchor
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  📍 Preview on Map        │  │  ← Shows route on map
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌────────────┐ ┌────────────┐  │
  │  │  ✏️ Edit    │ │ ✓ Add All  │  │  ← Edit = modify before
  │  └────────────┘ └────────────┘  │     adding. Add All = bulk
  │                                 │     insert to timeline.
  └─────────────────────────────────┘
```

### Edit Mode

User can:

- **Remove** places (swipe or tap ✕)
- **Reorder** places (drag)
- **Swap** a place (tap → AI suggests alternatives)
- **Adjust times** (tap time → picker)
- **Add to Ideas** instead of day (long-press → "Save for later")

### Technical Implementation

**Backend: Supabase Edge Function `ai-plan-day`**

The prompt does NOT ask the LLM for lat/lng or addresses. Those are hallucination-prone fields. The LLM generates place names and intent; Google Places validates and provides verified geodata.

```typescript
// System prompt — no user free-text injected here
const systemPrompt = `You are a travel planning assistant. Generate a day
itinerary for ${destination} on ${date}.
CONSTRAINTS:
- Available window: ${startTime} to ${endTime}
- Existing bookings (DO NOT MOVE): ${existingBookings}
- User pace: ${pace} (relaxed=3-4 stops, balanced=5-6, busy=7-8)
- Interests: ${interests}
- Budget: ${budget}
- Day of week: ${dayOfWeek} (affects opening hours)
RULES:
1. Places must be real, well-known locations in ${destination}
2. Do NOT include lat/lng coordinates — these will be verified separately
3. Account for approximate travel time between places (walking in cities)
4. Include a mix of activities and rest (café/park breaks)
5. Respect typical opening hours for the day of week
6. Include estimated cost per place
7. Group geographically close places by neighborhood
8. Include a brief 1-sentence description for each place
9. Prioritize the user's specific requests provided below
Return structured JSON matching the schema.`;
// User input passed via user role with sanitization (see Prompt Injection Protection above)
const userMessage = `My preferences for this day:\n---\n${sanitizeUserInput(specialRequests)}\n---`;
```

**OpenAI Call with Structured Output:**

```typescript
const response = await openai.chat.completions.create({
  model: "gpt-4o-mini",
  messages: [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ],
  response_format: {
    type: "json_schema",
    json_schema: {
      name: "day_plan",
      strict: true,
      schema: {
        type: "object",
        properties: {
          places: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                neighborhood: { type: "string" },
                category: {
                  type: "string",
                  enum: [
                    "attraction",
                    "restaurant",
                    "cafe",
                    "park",
                    "museum",
                    "shopping",
                    "nightlife",
                  ],
                },
                start_time: { type: "string" },
                end_time: { type: "string" },
                duration_minutes: { type: "integer" },
                estimated_cost: { type: "string" },
                description: { type: "string" },
                travel_from_previous_minutes: { type: "integer" },
              },
              required: [
                "name",
                "neighborhood",
                "category",
                "start_time",
                "end_time",
                "duration_minutes",
                "description",
                "travel_from_previous_minutes",
              ],
              additionalProperties: false,
            },
          },
          total_walking_km: { type: "number" },
          total_estimated_cost: { type: "string" },
          summary: { type: "string" },
        },
        required: [
          "places",
          "total_walking_km",
          "total_estimated_cost",
          "summary",
        ],
        additionalProperties: false,
      },
    },
  },
});
// POST-PROCESSING: Validate every place via Google Places API
const validatedPlaces = await validatePlacesViaGoogle(
  response.places,
  destination,
);
// validatedPlaces now have verified lat/lng, address, and google_place_id
// Places that failed validation are dropped and logged
```

**Cost per generation:** ~~$0.002 (LLM) + ~$0.03 (Google validation for 6 places) = \*\*~~$0.032 total\*\*

### Entry Points

The "Plan My Day" action surfaces contextually, not as a persistent button everywhere:

1. **Day Section Header (contextual)** — ✨ Plan button appears when the day has < 3 places. This is the primary entry point. When the day has 3+ places, the button changes to "Optimize Route" or "Navigate" (see UX Design Principles: Contextual Day Header Actions).
2. **Empty Day State** — Large CTA: "✨ Let AI plan this day for you" (only when a day has zero places)
3. **Speed Dial** — "✨ AI Plan Day" option (opens day picker first, useful when user is not looking at a specific day header)

---

## Feature 2: Route Optimization — "Optimize My Route"

**Category: Differentiator | Version: V2 | Complexity: Medium**

Travelers add places in discovery order (Eiffel Tower first because it's famous, then a café they found on Instagram, then a museum someone recommended). The result is a zig-zag route. One tap fixes it.

### How It Works

```
  Day 2 header → [🔄 Optimize Route]
  Before:                          After:
  ┌──────────────────┐             ┌──────────────────┐
  │ 1. Eiffel Tower  │ ← West     │ 1. Sainte-Chapelle│ ← East
  │ 2. Sainte-Chapelle│ ← East    │ 2. Musée d'Orsay  │ ← Central
  │ 3. Sacré-Cœur    │ ← North    │ 3. Eiffel Tower   │ ← West
  │ 4. Musée d'Orsay │ ← Central  │ 4. Sacré-Cœur     │ ← North
  │                  │             │                    │
  │ Total: 14.2 km   │             │ Total: 8.7 km      │
  │ Walk: 2h 50min   │             │ Walk: 1h 44min     │
  └──────────────────┘             └──────────────────┘
                                   Saved: 5.5 km, 66 min
```

### Result: Auto-Apply with Undo Toast

Route optimization auto-applies on tap — same pattern as swipe-to-delete with undo. No confirmation sheet. The user who tapped "Optimize" already understands what they asked for. Showing a before/after comparison with a Cancel button adds friction to a one-tap action.

```
  User taps [🔄 Opt] on Day 2 header
       │
       ▼
  Timeline cards animate to new positions (Reanimated Layout.springify())
       │
       ▼
  Undo toast slides up from bottom (auto-dismiss 5 seconds):
  ┌──────────────────────────────────────┐
  │  ✓ Route optimized                  │
  │  Saved 66 min · 5.5 km shorter      │   ← Green success
  │                            [Undo]   │   ← Reverts to original order
  └──────────────────────────────────────┘
```

**Why no confirmation sheet:**

- The action is instantly reversible (undo toast)
- The result is visible immediately on the timeline (cards reorder)
- A confirmation sheet with a mini map, numbered list, and two buttons makes a 1-second action take 10 seconds
- If the user doesn't like the result, they tap Undo. If they do like it, they do nothing. Zero friction.

**If optimization has no effect** (places are already optimally ordered):

```
  ┌──────────────────────────────────────┐
  │  ✓ Route is already optimized!      │   ← Informational toast
  │  Your order is the shortest route.  │      Auto-dismiss 3 seconds
  └──────────────────────────────────────┘
```

### Algorithm: Nearest Neighbor TSP with Constraints

```swift
func optimizeRoute(places: [Place], dayStart: Date, dayEnd: Date) -> [Place] {
    let flexible = places.filter { !$0.isTimeLocked }
    let locked = places.filter { $0.isTimeLocked }
    let slots = createTimeSlots(locked: locked, dayStart: dayStart, dayEnd: dayEnd)
    var optimized: [Place] = []
    for slot in slots {
        let candidates = flexible.filter { estimatedDuration($0) <= slot.available }
        let ordered = nearestNeighborTSP(candidates, start: slot.startLocation)
        optimized.append(contentsOf: ordered)
    }
    return mergeAndAssignTimes(optimized: optimized, locked: locked)
}
func nearestNeighborTSP(_ places: [Place], start: CLLocationCoordinate2D) -> [Place] {
    var unvisited = places
    var route: [Place] = []
    var current = start
    while !unvisited.isEmpty {
        var nearestIndex = 0
        var minDist = Double.greatestFiniteMagnitude
        for i in unvisited.indices {
            let dist = haversineDistance(from: current, to: unvisited[i].coordinate)
            if dist < minDist {
                minDist = dist
                nearestIndex = i
            }
        }
        let nearest = unvisited.remove(at: nearestIndex)
        route.append(nearest)
        current = nearest.coordinate
    }
    return route
}
```

**Runs entirely on-device.** No API calls. No cost. Instant result.

For trips with 5-8 places per day (typical), nearest-neighbor produces near-optimal results. For power users with 10+ places, consider 2-opt improvement pass.

### Smart Features

- **Time-locked items respected**: Flights, hotel check-in/out, restaurant reservations stay in place
- **Opening hours awareness (tiered)**: Uses cached Google Pro details if available (user previously tapped the place). Falls back to LLM-estimated hours for places without cached data (e.g., "Louvre typically closed Mondays"). Estimated hours shown with "~~" prefix in UI to indicate they aren't verified. V3 upgrade: batch-fetch Pro details for all places in a day when route optimization is triggered (~~$0.10 per optimization).
- **Start from hotel**: Route starts from the hotel/accommodation for that day
- **Round-trip option**: End the day back at the hotel

### Entry Points

1. **Day Section Header (contextual)** — 🔄 Optimize button appears when day has 3+ unoptimized places (replaces the ✨ Plan button for that day — see Contextual Day Header Actions)
2. **Map View** — "Optimize" button when viewing a specific day's pins
3. **AI Day Planner output** — Already optimized by default (no separate optimize needed)

---

## Feature 3: Export to Google Maps

**Category: Parity Plus | Version: V2 | Complexity: Low**

"I've planned my day, now navigate me." One tap generates a Google Maps directions URL with all stops as waypoints.

### User Flow — One-Tap for the 80% Case

**Entry:** Day header contextual button [📤 Nav] (appears when day has an optimized/ordered set of places). Also available in Map view.

**Default behavior (one tap, zero decisions):**

```
  User taps [📤 Nav] on Day 2 header
       │
       ▼
  Maps app opens with all stops as waypoints
  (Default app: Apple Maps on iOS, Google Maps on Android)
  (Default mode: walking in cities, driving elsewhere)
  (All stops included)
```

The user's maps app preference and travel mode are remembered from last use. First use defaults to platform-native app.

**Settings sheet (only when needed):**

The export sheet only appears in two cases:

1. Day has **>10 places** (exceeds Google Maps waypoint limit — user must uncheck some)
2. User **long-presses** the Navigate button (to change app, mode, or stops)

```
  ┌─────────────────────────────────┐
  │  📤 Navigate Day 2              │
  ├─────────────────────────────────┤
  │                                 │
  │  ┌──────────┐                   │
  │  │ 🍎 Apple  │  Switch to       │  ← Current choice shown
  │  │   Maps    │  Google Maps ›   │     "Switch" link, not two buttons
  │  └──────────┘                   │
  │                                 │
  │  🚶 Walking           Change ›  │  ← Current mode + change link
  │                                 │
  │  ⚠️ Day has 12 stops.           │  ← Only if >10
  │  Google Maps supports 10 max.   │
  │  Uncheck 2 to continue:        │
  │                                 │
  │  ☑ 1. Sainte-Chapelle          │
  │  ☑ 2. Café de Flore            │
  │  ...                            │
  │  ☐ 11. Coutume Café             │  ← Unchecked
  │  ☐ 12. Late night bar           │  ← Unchecked
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │   📤 Open in Apple Maps   │  │
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

Most users will never see this sheet. Tap → maps opens. Done.

### Technical Implementation

```swift
import MapKit
func openInAppleMaps(places: [Place], mode: TravelMode) {
    guard places.count >= 2 else { return }
    let mapItems = places.map { place -> MKMapItem in
        let placemark = MKPlacemark(coordinate: place.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = place.name
        return item
    }
    let launchOptions: [String: Any] = [
        MKLaunchOptionsDirectionsModeKey: mode.mkDirectionsMode
    ]
    MKMapItem.openMaps(with: mapItems, launchOptions: launchOptions)
}
func generateGoogleMapsURL(places: [Place], mode: TravelMode) -> URL? {
    guard places.count >= 2 else { return nil }
    let origin = "\(places[0].lat),\(places[0].lng)"
    let destination = "\(places[places.count - 1].lat),\(places[places.count - 1].lng)"
    let waypoints = places[1..<(places.count - 1)]
        .map { "\($0.lat),\($0.lng)" }
        .joined(separator: "|")
    var components = URLComponents(string: "https://www.google.com/maps/dir/")!
    components.queryItems = [
        URLQueryItem(name: "api", value: "1"),
        URLQueryItem(name: "origin", value: origin),
        URLQueryItem(name: "destination", value: destination),
        URLQueryItem(name: "travelmode", value: mode.googleMapsMode)
    ]
    if !waypoints.isEmpty {
        components.queryItems?.append(URLQueryItem(name: "waypoints", value: waypoints))
    }
    return components.url
}
enum TravelMode {
    case driving, walking, cycling, transit
    var mkDirectionsMode: String {
        switch self {
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        case .cycling: return MKLaunchOptionsDirectionsModeWalking // fallback
        }
    }
    var googleMapsMode: String {
        switch self {
        case .driving: return "driving"
        case .walking: return "walking"
        case .cycling: return "bicycling"
        case .transit: return "transit"
        }
    }
}
```

**Apple Maps Integration (primary on iOS):**

- Uses native `MKMapItem.openMaps(with:launchOptions:)` — reliable multi-stop support
- No URL scheme limitations — native API handles any number of stops
- Full integration with turn-by-turn navigation
- Primary option since this is an iOS-native app

**Google Maps (secondary option):**

- Maximum **10 waypoints** between origin and destination (12 stops total)
- For days with >10 places: show warning, let user uncheck stops, or split into segments
- Opens via `UIApplication.shared.open(url)` if Google Maps is installed

### Export Formats (V3 additions)

| Format          | Description              | Use Case                         |
| --------------- | ------------------------ | -------------------------------- |
| Google Maps URL | Deep link with waypoints | Turn-by-turn navigation          |
| Apple Maps URL  | Deep link for iOS        | Native iOS navigation            |
| KML file        | Keyhole Markup Language  | Import to Google Earth / My Maps |
| PDF itinerary   | Printable day plan       | Offline reference                |
| Calendar events | .ics file                | Add to Google/Apple Calendar     |
| Share link      | Web URL of trip          | Share with travel companions     |

---

## Feature 4: AI Trip Generator — "Plan My Entire Trip"

**Category: Differentiator | Version: V2 | Complexity: Very High**

The most ambitious AI feature. User says "Plan 5 days in Tokyo" and gets a complete, thoughtfully structured trip. This is NOT a generic ChatGPT response — it's a structured, editable, immediately usable itinerary.

### User Flow

**Entry Point:** Create Trip flow gets a new option:

```
  ┌─────────────────────────────────┐
  │  Plan a New Trip                │
  ├─────────────────────────────────┤
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  📝 Plan Manually         │  │  ← Existing flow
  │  │  Add places one by one    │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  ✨ AI Trip Planner        │  │  ← NEW
  │  │  Let AI create your       │  │     Terracotta accent border
  │  │  perfect itinerary        │  │
  │  └───────────────────────────┘  │
  │                                 │
  └─────────────────────────────────┘
```

**Step 1: Destination + Dates** (same as manual)

**Step 2: Single-Screen Preferences (Smart Defaults)**

The original 4-card quiz (9-12 decisions before any result) is replaced with a single screen. Research shows every additional step before a payoff moment increases abandonment 15-20%. Two decisions minimum. Full customization available but not required.

```
  ┌─────────────────────────────────┐
  │  ✨ Plan Your Trip               │
  ├─────────────────────────────────┤
  │                                 │
  │  5 days in Tokyo                │  ← Already known from step 1
  │  Apr 2 – 9                      │
  │                                 │
  │  What's your style?             │
  │  ┌──────────┐  ┌──────────┐    │
  │  │ 📸        │  │  🏃       │    │  ← Pick 1-2
  │  │ Cultural  │  │ Active    │    │     "Balanced" pre-selected
  │  └──────────┘  └──────────┘    │     if user doesn't pick
  │  [More styles ▾]               │  ← Reveals Relaxed, Adventure
  │                                 │     only if user wants
  │  Anything specific?             │
  │  ┌───────────────────────────┐  │
  │  │ "Ramen, cherry blossoms,  │  │  ← Optional free text
  │  │  sake brewery"            │  │     Placeholder shows example
  │  └───────────────────────────┘  │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │     ✨ Generate Trip       │  │  ← Terracotta CTA
  │  └───────────────────────────┘  │
  │                                 │
  │  Balanced pace · $$ · Moderate  │  ← Tappable defaults line
  │  walk · No dietary needs        │     Remembered from last trip
  │                                 │     Tap any to change inline
  └─────────────────────────────────┘
```

**Tappable defaults line:** Each item (pace, budget, mobility, dietary) is tappable. Tapping "$$" expands a small inline picker to change it. But the user is NOT forced to interact with it — defaults work for 80% of trips.

**First-time users:** The tappable defaults line is expanded by default showing all options. After the user generates their first trip, preferences are remembered and the line collapses.

**Returning users:** Style pre-filled from last trip. Free text empty. Preferences remembered. User can tap Generate immediately — 1 tap, 0 decisions.

**Step 3: Generation + Review**

AI generates the full multi-day itinerary. User sees a scrollable preview of all days. Each day is collapsible. User can:

- Accept all → bulk insert into trip
- Edit individual places → modify before accepting
- Regenerate a single day → keep others
- Remove places → swipe away
- Add to Ideas → save for later instead of scheduling

### AI Generation Details

**Prompt Strategy:**

The AI prompt includes:

- Destination + dates + day of week for each day
- All user preferences from the quiz
- Special requests
- Known constraints (arrival/departure times if bookings exist)
- Geographic clustering instruction
- Pacing rules (morning activity, midday meal, afternoon explore, evening dining)
- Local knowledge prompts ("Include hidden gems, not just tourist traps")

**Multi-call strategy for quality:**

1. **Call 1: Day-by-day outline** — High-level themes per day (e.g., "Day 1: Shinjuku + Harajuku, Day 2: Asakusa + Akihabara")
2. **Call 2-N: Day detail** — Generate each day's places in parallel (concurrent Edge Function calls)
3. **Validation pass** — Check for duplicates across days, verify geographic clustering, ensure variety

**Cost:** ~$0.01-0.02 per full trip generation (3-5 API calls × $0.002 each)

### User Preference Learning (V3)

After 2-3 trips, the app learns:

- Preferred pace (how many places per day)
- Category preferences (always visits museums, rarely shops)
- Typical wake-up time and dinner time
- Budget tendency
- Walking tolerance

This data feeds into future AI generations without asking the quiz again.

---

## Feature 5: Smart Suggestions Engine

**Category: Differentiator | Version: V3 | Complexity: Medium**

AI proactively surfaces helpful suggestions throughout the timeline — not in a separate "AI" tab, but inline where they're relevant.

### Suggestion Types

All suggestions follow the **one-per-day rule** and are **collapsed by default** (see UX Design Principles above). Only the highest-priority suggestion for each day is shown.

**1. Gap Filling — "Your afternoon is free"**

Collapsed (default):

```
  │  1:30 PM  Le Petit Cler  (lunch ends)
  │
  │  ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  │  ╎  ✨ 1 suggestion · 4 hrs free    ╎   ← Single line, 32px height
  │  └─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘     Dashed border, TextTertiary
  │
  │  6:30 PM  Dinner reservation
```

Expanded (after tap):

```
  │  1:30 PM  Le Petit Cler  (lunch ends)
  │
  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  │  ╎  ✨ 4 hours free until dinner    ╎
  │  ╎                                 ╎
  │  ╎  Nearby:                        ╎
  │  ╎  🏛️ Musée d'Orsay (12 min 🚶)  ╎
  │  ╎  🌿 Jardin du Lux. (8 min 🚶)  ╎
  │  ╎  ☕ Café de Flore (5 min 🚶)    ╎
  │  ╎                                 ╎
  │  ╎  [+ Add]  [✨ Plan afternoon]   ╎
  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
  │
  │  6:30 PM  Dinner reservation
```

**2. Category Balancing / Meal Reminders / Duplicates**

These lower-priority suggestions only appear if no higher-priority suggestion (conflict, weather, gap) exists for that day. They use the same collapsed single-line format:

```
  ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  ╎  🍴 No lunch planned · tap for ideas  ╎   ← Collapsed, single line
  └─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```

```
  ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  ╎  💡 4 restaurants, no sights · ideas  ╎
  └─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```

Duplicates are handled as conflicts (amber badge on day header, sequential resolution sheet).

**3. Nearby Discoveries — "Since you're here..."**

This is the only suggestion type that does NOT appear inline on the timeline. It appears on the **place detail sheet** (below "Getting There") when the user taps a place card. This is a contextual discovery surface, not a timeline interruption.

```
  On place detail sheet, below "Getting There":
  ┌───────────────────────────────────┐
  │ ✨ WHILE YOU'RE NEARBY            │
  │                                   │
  │ 🏛️ Panthéon (4 min walk)     [+] │
  │ ☕ Shakespeare & Co. (6 min) [+]  │
  │ 🌿 Square René Viviani (3m) [+]  │
  └───────────────────────────────────┘
```

### Implementation

Suggestions are generated:

- **On timeline load** — check for gaps, missing meals, category imbalance (local computation, on-device)
- **On place add** — check for duplicates (local trip data)
- **On place detail open** — nearby suggestions (Google Places, batched, cached)
- **Daily background job** — weather-aware suggestions for upcoming trip days (server-side)
- **Priority resolution** — each day evaluated for highest-priority suggestion only

Most suggestions require NO API calls — they use local trip data + cached place details. Only "Nearby Discoveries" calls Google Places (batched, cached, triggered only on explicit user action).

---

## Feature 6: AI Travel Assistant (Chat)

**Category: Differentiator | Version: V3 | Complexity: High**

A context-aware AI chatbot that knows your entire trip. Not a generic ChatGPT wrapper — it has your itinerary, bookings, dates, and destination context.

### Interface

**No floating chat button.** The chat button and the Speed Dial FAB would compete for the bottom of the screen (two floating controls = thumb zone conflict, visual noise, accidental taps). Instead, the assistant is accessible via Speed Dial → "💬 Ask AI" option.

```
  Speed Dial (V3, expanded):
  📍 Add Place
  ✈️ Add Booking
  ✨ AI Plan Day
  💬 Ask AI                         ← NEW in V3
       ┌───┐
       │ ✕ │
       └───┘
  Tap "💬 Ask AI" → chat sheet slides up:
  ┌─────────────────────────────────┐
  │  ✨ Trip Assistant          ✕   │
  ├─────────────────────────────────┤
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ AI: Hi! I know your Paris │  │
  │  │ trip inside out. Ask me   │  │
  │  │ anything!                 │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  Quick questions:               │
  │  ┌────────────────────────┐     │
  │  │ Best way CDG → hotel?  │     │  ← Suggested prompts
  │  └────────────────────────┘     │     (context-aware, generated
  │  ┌────────────────────────┐     │      from trip data)
  │  │ What to pack for Paris │     │
  │  │ in March?              │     │
  │  └────────────────────────┘     │
  │  ┌────────────────────────┐     │
  │  │ Restaurant tips near   │     │
  │  │ Le Marais Hotel?       │     │
  │  └────────────────────────┘     │
  │                                 │
  │  ┌───────────────────────┐ ┌─┐  │
  │  │ Type a question...     │ │→│  │
  │  └───────────────────────┘ └─┘  │
  └─────────────────────────────────┘
```

**Why Speed Dial and not a floating button:** The Speed Dial is the established creation/action hub for the trip detail screen. Adding "Ask AI" as a V3 option keeps the chat accessible (2 taps: FAB → Ask AI) without adding a permanent floating element that competes with the FAB. Users who want the chat frequently will discover it quickly; users who don't won't see a button they never use.

### Context Injection

Every message to the AI includes a system context block:

```
You are a travel assistant for a trip to {destination}.
Trip dates: {start} to {end} ({duration} days).
Current day: {today} (Day {dayNumber} of trip / {daysUntilTrip} days away).
Weather forecast: {forecast}.
Accommodation: {hotelName} in {neighborhood}.
Planned places: {placesSummary}.
Bookings: {bookingsSummary}.
Local timezone: {timezone}.
User language preference: {language}.
```

### What the Assistant Can Do

| Query             | Example                                      | How It Helps                                            |
| ----------------- | -------------------------------------------- | ------------------------------------------------------- |
| Transport advice  | "Best way from CDG to my hotel?"             | Knows hotel location, suggests RER + Metro with stops   |
| Packing tips      | "What should I pack?"                        | Knows dates → checks weather forecast → specific advice |
| Restaurant recs   | "Good sushi near my Day 3 area?"             | Knows Day 3 places → geo-aware suggestions              |
| Local customs     | "Tipping etiquette in Paris?"                | Destination-aware cultural tips                         |
| Emergency info    | "Nearest pharmacy?"                          | Knows current location context                          |
| Trip logistics    | "Can I fit the Catacombs on Day 4?"          | Knows Day 4 schedule, estimates fit                     |
| Alternative plans | "It's raining, what indoor things are near?" | Weather + location aware                                |
| Language help     | "How do I say 'the check please' in French?" | Destination language                                    |

### Technical Details

- **Model:** GPT-4o-mini (cost-efficient for chat)
- **Rate limit:** 30 messages per day per user
- **History:** Last 10 messages kept in context (per trip)
- **Storage:** Chat history in Supabase `trip_chat_messages` table

**Token Management (Critical):**

The system context (trip details, places, bookings, weather) can easily reach 1,500-2,000 tokens for a multi-day trip. Add 10 conversation messages at ~100 tokens each = 1,000 tokens. Total input per exchange: 3,000+ tokens.

Mitigations:

- **Truncate `placesSummary`**: Send one-line-per-day summaries instead of per-place detail. E.g., "Day 2: Eiffel Tower, Café de Flore, Musée d'Orsay, 2 more" (~20 tokens/day vs ~100)
- **Relevant-day retrieval**: If user asks about "Day 3", inject full Day 3 context but summarize other days. Use keyword matching on the user message to detect referenced days.
- **Cap context window**: Hard limit system context to 1,500 tokens. If trip data exceeds this, prioritize: bookings > today's places > upcoming places > past places.
- **Sliding history window**: Keep last 6 messages (not 10) in context. Older messages summarized into a single "conversation so far" line.

**Corrected cost:** ~$0.002-0.003 per message exchange (accounting for actual token volumes)

---

## Feature 7: Weather-Aware Rescheduling

**Category: Differentiator | Version: V3 | Complexity: Medium**

AI monitors weather forecasts and proactively suggests schedule adjustments.

### How It Works

```
  Push notification (2 days before):
  ┌───────────────────────────────────┐
  │  🌧️ Rain expected on Day 3        │
  │  Want to swap outdoor activities  │
  │  to Day 5 (sunny)?               │
  │  [View suggestion]                │
  └───────────────────────────────────┘
  In-app suggestion:
  ┌─────────────────────────────────┐
  │  🌧️ Weather Alert — Day 3       │
  ├─────────────────────────────────┤
  │                                 │
  │  Rain expected (80%, 8mm)       │
  │                                 │
  │  Outdoor activities at risk:    │
  │  ❌ 🌿 Jardin du Luxembourg    │
  │  ❌ 🌅 Seine River Walk        │
  │  ✅ 🏛️ Musée d'Orsay (indoor) │
  │  ✅ 🍴 Café de Flore (indoor)  │
  │                                 │
  │  Suggestions:                   │
  │  ┌───────────────────────────┐  │
  │  │ 🔄 Swap Day 3 ↔ Day 5    │  │  ← Day 5 is sunny
  │  │    (Day 5 has 3 indoor    │  │
  │  │     activities)           │  │
  │  └───────────────────────────┘  │
  │  ┌───────────────────────────┐  │
  │  │ 🔄 Replace outdoor with:  │  │
  │  │    🏛️ Louvre Museum       │  │  ← AI suggests indoor
  │  │    🎭 Opéra Garnier       │  │     alternatives
  │  └───────────────────────────┘  │
  │  ┌───────────────────────────┐  │
  │  │ 👍 Keep as-is             │  │
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

### Weather API

**OpenWeatherMap:**

- Free tier: 1,000 API calls/day
- 5-day forecast sufficient for trip planning
- Cost at 100-1K DAU: $0 (within free tier)
- Cost at 10K DAU: **Budget $40/month contingency for paid tier.** During peak travel season (June-August), active trip percentage can hit 15-20% of DAU, pushing daily calls to 1,500-2,000 — exceeding the free 1,000/day limit. The "One Call 3.0" plan at $40/month covers 100K calls/month.

**Caching strategy:**

- Fetch weather once per trip per day (morning cron job)
- Cache in Supabase (destination + date → forecast)
- Only fetch for trips starting within 7 days
- Deduplicate: if multiple users have trips to the same city on the same dates, reuse the cached forecast (cache key = destination + date, not trip_id + date)

---

## Feature 8: Smart Conflict Detection

**Category: Parity Plus | Version: V2 | Complexity: Low**

Automatic detection of scheduling issues — no AI API calls needed, pure logic.

### Conflict Types

Conflicts are shown as visual indicators ON the affected cards (amber dot + card tint), NOT as separate banners between cards. The day header gets an amber badge with count. Tapping the badge opens a sequential resolution sheet.

**Timeline appearance (conflicts shown on cards, not between them):**

```
  │  9:00 AM
  ●─┐                                ← Normal day-color dot
  │ ┌────────────────────────┐
  │ │ ⭐ Eiffel Tower         │       ← Normal card
  │ │   9:00 AM - 11:00 AM   │
  │ └────────────────────────┘
  │
  │  10:30 AM
  ⚠─┐                                ← AMBER dot (conflict indicator)
  │ ┌──────────────────────────┐
  │ │ 🏛️ Louvre          ⚠️    │       ← Amber tint on card background
  │ │   10:30 AM - 12:00 PM    │         Small ⚠️ badge, top-right
  │ │                           │         Tap card → detail sheet
  │ └──────────────────────────┘         shows conflict + options
```

**Day header with conflict badge:**

```
  ┌────────────────────────────────────┐
  │ ▼  Day 2 — Sat, Mar 12    ⚠️ 2   │   ← Amber badge with count
  └────────────────────────────────────┘     Tap → resolution sheet
```

**Sequential resolution sheet** (tap badge to open):

```
  ┌─────────────────────────────────┐
  │  ⚠️ 2 Issues on Day 2     ✕   │
  ├─────────────────────────────────┤
  │                                 │
  │  Issue 1 of 2                   │  ← One at a time
  │                                 │
  │  ⏱️ TIME OVERLAP                │
  │  Eiffel Tower (9-11 AM) and    │
  │  Louvre (10:30 AM-12 PM)       │
  │  overlap by 30 minutes.        │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  Adjust Louvre to 11:15 AM│  │  ← Recommended action
  │  └───────────────────────────┘  │
  │  Skip                           │  ← Subtle text link
  │                                 │
  └─────────────────────────────────┘
  After resolving (or skipping), slides to Issue 2:
  ┌─────────────────────────────────┐
  │  ⚠️ Issue 2 of 2               │
  │                                 │
  │  🚶 TIGHT COMMUTE              │
  │  30 min between Sacré-Cœur     │
  │  and Montmartre, but it's      │
  │  a 40 min walk.                 │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  Add 10 min buffer        │  │
  │  └───────────────────────────┘  │
  │  Use 🚗 instead (8 min) · Skip │
  │                                 │
  └─────────────────────────────────┘
```

**Why sequential, not all-at-once:** Each conflict gets one recommended action and a skip. The user resolves them like fixing spelling errors — one by one in a focused flow, not a wall of simultaneous decision prompts.

**Implementation:** All on-device using Haversine distances and available data. Zero API cost.

**Opening hours data availability (tiered):**

- **Places added via Google search**: Have `google_place_id` → can check `place_details_cache` for hours (if user previously tapped for detail)
- **AI-generated places**: Have `google_place_id` from validation pipeline → same cache lookup
- **Manually added places**: No opening hours data → skip closed-venue check for these
- **Fallback for uncached places**: Use well-known closure rules only (e.g., "Most museums closed Mondays in France"). These heuristics are on-device, curated per country, and flagged as "typically closed" (not "definitely closed") in the warning badge.

---

## Feature 9: Enhanced AI Booking Parser

**Category: Differentiator | Version: V2 | Complexity: Medium**

Upgrade the existing booking email parser with new AI capabilities.

### New Capabilities

**1. Multi-Language Support**

- Current: English only
- Enhanced: 10+ languages (GPT-4o-mini handles multilingual natively)
- Auto-detect language, parse in original, return structured English output

**2. Screenshot-to-Booking**

- User takes screenshot of booking confirmation
- Shares/pastes into app
- **GPT-4o (not mini)** vision extracts booking details — mini's accuracy on dense text extraction (small fonts, colored backgrounds, multi-field booking confirmations) is measurably worse than GPT-4o. For a trust-critical feature, use the more capable model.
- Same review flow as email parsing
- Cost: ~$0.005-0.01 per image (depends on resolution; 1024x768 booking screenshot ≈ $0.007)

```
  ┌─────────────────────────────────┐
  │  Speed Dial → 📸 Scan Booking   │
  ├─────────────────────────────────┤
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ 📷 Take Photo             │  │
  │  │ 🖼️ Choose from Gallery     │  │
  │  │ 📋 Paste from Clipboard    │  │
  │  └───────────────────────────┘  │
  │                                 │
  │  [Processing screenshot...]     │
  │                                 │
  │  Result:                        │
  │  ┌───────────────────────────┐  │
  │  │ ✈️ Flight detected         │  │
  │  │ AA 1234 · JFK → CDG       │  │  ← ✅ Verified
  │  │ Mar 12, 6:30 AM           │  │  ← ✅ Verified
  │  │ Conf: XKRF4Q       ✅    │  │  ← ✅ Verified
  │  │ Terminal: 2    ⚠️ Check   │  │  ← ⚠️ Please check (single char)
  │  │                           │  │
  │  │ [Edit & Add]  [Add →]     │  │
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

**3. PDF Attachment Parsing**

- Booking confirmation PDFs attached to emails
- Extract text → feed to GPT-4o-mini
- Same structured output as email body parsing

**4. Confidence Scoring (Heuristic Binary)**

GPT-4o-mini doesn't natively produce calibrated per-field confidence scores. Asking the model to self-assess produces overconfident results. Instead, use heuristic rules for a simple binary: **"Verified"** vs **"Please check"**.

Rules for flagging a field as "Please check":

- Confirmation code: length < 4 or > 20 characters, or contains spaces (likely malformed)
- Terminal/gate: single character (e.g., "2" instead of "Terminal 2")
- Time: ambiguous AM/PM (e.g., "6:30" without AM/PM indicator)
- Airport code: not in IATA code database
- Date: more than 365 days in the future
- Hotel name: fewer than 3 characters
- Any field the model returns as empty string when it was expected

```
  ┌───────────────────────────┐
  │ ✈️ Flight detected         │
  │ AA 1234 · JFK → CDG       │  ← All fields verified ✅
  │ Mar 12, 6:30 AM           │
  │ Conf: XKRF4Q       ✅     │
  │ Terminal: 2    ⚠️ Check    │  ← Flagged: single character
  └───────────────────────────┘
```

**Cost:** Screenshot parsing uses GPT-4o vision (~$0.007 per image). Budget: minimal — users scan 2-3 bookings per trip.

---

## Feature 10: AI-Powered Place Recommendations

**Category: Differentiator | Version: V2 | Complexity: Medium**

When a user searches for places, AI enhances results with personalized rankings and descriptions.

### How It Works

```
  Add Place modal → Search "coffee"
  Standard results:                    AI-enhanced results:
  ┌──────────────────────┐            ┌──────────────────────┐
  │ ☕ Starbucks          │            │ ☕ Coutume Café       │  ← AI reranks:
  │   123 Rue de Rivoli  │            │   ⭐ "Best specialty  │     locals-first
  │                      │            │   coffee in Le Marais"│
  │ ☕ Café de Flore      │            │   📍 5 min from hotel │  ← Distance from
  │   172 Blvd Saint...  │            │                      │     your accommodation
  │                      │            │ ☕ Café de Flore       │
  │ ☕ Coutume Café       │            │   ⭐ "Historic Left   │
  │   47 Rue de Baby...  │            │   Bank institution"  │
  └──────────────────────┘            └──────────────────────┘
```

**Ranking factors (computed locally, no API):**

- Proximity to other Day N places (cluster nearby)
- Category variety (don't suggest 3rd museum if 2 already planned)
- Rating (from cached place details)
- "Hidden gem" bonus (lower review count + high rating)

---

## Complete AI Feature Timeline

The original plan packed 7 AI features into V2 alongside Trip Stories in a 4-week window. That's unrealistic. AI generation features (Day Planner, Trip Generator) require 2-3 weeks of prompt engineering, validation pipeline testing, and UX iteration beyond the initial build. Split into V2a and V2b.

### V2a — Ship with Trip Stories (4 weeks after V1)

On-device features + Trip Stories. These require no prompt engineering iteration and have zero ongoing AI cost.

| #   | Feature                              | Complexity | AI Model          | Cost/Use | Why V2a                            |
| --- | ------------------------------------ | ---------- | ----------------- | -------- | ---------------------------------- |
| 1   | Route Optimization                   | Medium     | On-device         | $0       | Most-requested feature, zero risk  |
| 2   | Export to Google Maps                | Low        | None              | $0       | Trivial to build, high user value  |
| 3   | Smart Conflict Detection             | Low        | On-device         | $0       | Pure logic, no external dependency |
| 4   | AI Place Recommendations             | Medium     | On-device + cache | $0       | Local re-ranking, no API calls     |
| 5   | Enhanced Booking Parser (multi-lang) | Low        | GPT-4o-mini       | $0.001   | Prompt tweak on existing parser    |

### V2b — AI Generation Features (3 weeks after V2a)

Features requiring prompt engineering, Google Places validation pipeline, and output quality iteration.

| #   | Feature               | Complexity | AI Model                        | Cost/Use | Why V2b                                     |
| --- | --------------------- | ---------- | ------------------------------- | -------- | ------------------------------------------- |
| 6   | AI Day Planner        | High       | GPT-4o-mini + Google validation | $0.032   | Needs validation pipeline + prompt tuning   |
| 7   | AI Trip Generator     | Very High  | GPT-4o-mini + Google validation | $0.17    | Multi-call, needs 2+ weeks prompt iteration |
| 8   | Screenshot-to-Booking | Medium     | GPT-4o (vision)                 | $0.007   | Needs GPT-4o (not mini) for accuracy        |

### V3 (6 weeks after V2b)

| #   | Feature                    | Complexity | AI Model                | Cost/Use                 |
| --- | -------------------------- | ---------- | ----------------------- | ------------------------ |
| 9   | Smart Suggestions Engine   | Medium     | On-device + GPT-4o-mini | $0.001                   |
| 10  | AI Travel Assistant Chat   | High       | GPT-4o-mini             | $0.003/msg               |
| 11  | Weather-Aware Rescheduling | Medium     | On-device + weather API | $0 (+$40/mo contingency) |
| 12  | Preference Learning        | Medium     | On-device analytics     | $0                       |

### V4+ (Months 4-8)

| #   | Feature                           | Description                                           |
| --- | --------------------------------- | ----------------------------------------------------- |
| 13  | Community-trained recommendations | AI learns from all users' trip patterns               |
| 14  | Predictive trip planning          | "Based on your past 3 trips, you might like..."       |
| 15  | Multi-modal AI                    | Voice trip planning, photo-based place identification |
| 16  | Real-time AI rerouting            | Flight delayed → AI replans rest of day automatically |

---

## Cost Impact Analysis (Corrected)

Costs updated to reflect: Google Places validation for AI-generated places, GPT-4o (not mini) for screenshot vision, corrected chat token volumes, and weather API contingency.

### Additional AI Costs at Each Scale

**100 DAU (Launch):**

| AI Feature         | Usage/Month       | LLM Cost | + Google Validation             | Total     |
| ------------------ | ----------------- | -------- | ------------------------------- | --------- |
| Day Planner        | 30 generations    | $0.06    | $0.90 (30 × 6 places × $0.005)  | **$0.96** |
| Trip Generator     | 10 generations    | $0.15    | $1.50 (10 × 30 places × $0.005) | **$1.65** |
| Screenshot Parser  | 20 scans (GPT-4o) | $0.14    | —                               | **$0.14** |
| Travel Assistant   | 200 messages      | $0.60    | —                               | **$0.60** |
| Route Optimization | All on-device     | —        | —                               | **$0**    |
| Conflict Detection | All on-device     | —        | —                               | **$0**    |
| Export to Maps     | No API cost       | —        | —                               | **$0**    |
| Weather API        | 50 forecasts      | —        | —                               | **$0**    |
| **AI Total**       |                   |          |                                 | **$3.35** |

**1,000 DAU:**

| AI Feature        | Usage/Month        | LLM Cost | + Google Validation | Total      |
| ----------------- | ------------------ | -------- | ------------------- | ---------- |
| Day Planner       | 300 generations    | $0.60    | $9.00               | **$9.60**  |
| Trip Generator    | 100 generations    | $1.50    | $15.00              | **$16.50** |
| Screenshot Parser | 200 scans (GPT-4o) | $1.40    | —                   | **$1.40**  |
| Travel Assistant  | 2,000 messages     | $6.00    | —                   | **$6.00**  |
| Smart Suggestions | 500 lookups        | $0.50    | —                   | **$0.50**  |
| Weather API       | 500 forecasts      | —        | —                   | **$0**     |
| **AI Total**      |                    |          |                     | **$34.00** |

**10,000 DAU:**

| AI Feature        | Usage/Month          | LLM Cost | + Google Validation | Total       |
| ----------------- | -------------------- | -------- | ------------------- | ----------- |
| Day Planner       | 3,000 generations    | $6.00    | $90.00              | **$96.00**  |
| Trip Generator    | 1,000 generations    | $15.00   | $150.00             | **$165.00** |
| Screenshot Parser | 2,000 scans (GPT-4o) | $14.00   | —                   | **$14.00**  |
| Travel Assistant  | 20,000 messages      | $60.00   | —                   | **$60.00**  |
| Smart Suggestions | 5,000 lookups        | $5.00    | —                   | **$5.00**   |
| Weather API       | contingency          | —        | —                   | **$40.00**  |
| **AI Total**      |                      |          |                     | **$380.00** |

Note: Google Places validation calls count toward the same free tier and $200/month credit already budgeted in the infrastructure plan. At 100-1K DAU, most validation calls fall within the free 10K/month Essentials cap. At 10K DAU, validation adds ~48K calls/month to the existing 105K — increasing Google Places cost by ~$240 (covered in the $380 total above, with ~$90 absorbed by free tier/credit).

### Updated Total Monthly Costs

| Scale      | Current Plan | + AI Features | New Total   |
| ---------- | ------------ | ------------- | ----------- |
| 100 DAU    | $11          | +$3.35        | **$14.35**  |
| 1,000 DAU  | $71          | +$34.00       | **$105.00** |
| 10,000 DAU | $493         | +$380         | **$873**    |

**Reality check:** The original estimate of $52/month at 10K DAU was significantly undercosted. The corrected $380/month is still very manageable — it's under $0.04/DAU/month for the full AI suite. The Google Places validation overhead ($240 at 10K DAU) is the main driver and is non-negotiable for output quality.

**Template caching mitigates this**: With destination templates serving 20-30% of requests (skipping both LLM + validation for those), the realistic 10K DAU cost is closer to **$280-320/month**.

---

## Technical Architecture

### AI Service Layer

```
TripWeave/
├── Services/
│   ├── AI/
│   │   ├── DayPlannerService.swift       # AI Day Planner client (calls Edge Function)
│   │   ├── TripGeneratorService.swift    # AI Trip Generator client (calls Edge Function)
│   │   ├── RouteOptimizer.swift          # On-device TSP solver
│   │   ├── ConflictDetector.swift        # On-device conflict detection
│   │   ├── SuggestionsEngine.swift       # Smart suggestions logic
│   │   ├── MapsExportService.swift       # Apple Maps MKMapItem / Google Maps URL builder
│   │   └── WeatherService.swift          # Weather API client via URLSession
supabase/
├── functions/
│   ├── ai-plan-day/              # Edge Function: day planning
│   ├── ai-plan-trip/             # Edge Function: full trip generation
│   ├── ai-parse-screenshot/      # Edge Function: screenshot → booking
│   ├── ai-chat/                  # Edge Function: travel assistant
│   └── ai-suggest/               # Edge Function: smart suggestions
```

### Prompt Management

Store prompts in Supabase table for hot-swapping without app updates:

```sql
create table public.ai_prompts (
  id text primary key,           -- 'day_planner_v2', 'trip_generator_v1'
  system_prompt text not null,
  model text default 'gpt-4o-mini',
  temperature numeric default 0.7,
  max_tokens integer default 2000,
  response_schema jsonb,         -- Structured output schema
  active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
```

This enables A/B testing prompts, updating without app releases, and per-feature model selection.

### Response Caching — Destination Template Strategy

Direct cache hits on `hash(prompt_id + destination + preferences)` will be extremely rare — two users rarely have identical preference combinations + destination + dates + existing bookings. Instead, use a **template + customization** architecture:

**Layer 1: Pre-generated destination templates (free, instant)**

For the top 50-100 destinations, pre-generate canonical day plans during off-peak hours:

- "Balanced day in Paris — museums + food"
- "Cultural day in Tokyo — temples + traditional"
- "Active day in Barcelona — architecture + beach"

Store in a `destination_templates` table. Serve as instant starting points.

**Layer 2: AI customization delta (cheap, fast)**

When a user requests a plan, first check for a matching template. If found, send a shorter prompt: "Customize this template for the user's constraints" (existing bookings, time window, specific requests). This uses ~50% fewer tokens than generating from scratch.

```sql
create table public.destination_templates (
  id uuid primary key default gen_random_uuid(),
  destination text not null,               -- 'Paris, France'
  theme text not null,                     -- 'balanced_cultural', 'food_focused', 'active_outdoor'
  pace text not null,                      -- 'relaxed', 'balanced', 'busy'
  places jsonb not null,                   -- pre-validated places with google_place_ids
  total_walking_km numeric,
  summary text,
  generated_at timestamptz default now(),
  expires_at timestamptz default (now() + interval '30 days')
);
create unique index idx_template_lookup
  on public.destination_templates(destination, theme, pace);
create table public.ai_response_cache (
  cache_key text primary key,              -- hash of full request params (fallback for exact matches)
  response jsonb not null,
  model text not null,
  tokens_used integer,
  created_at timestamptz default now(),
  expires_at timestamptz default (now() + interval '7 days')
);
```

**Expected savings:** Templates serve 20-30% of requests instantly ($0). Delta customization uses 50% fewer tokens. Combined savings: 25-35% of AI generation costs.

### Rate Limiting

| Feature            | Limit          | Period    |
| ------------------ | -------------- | --------- |
| Day Planner        | 10 generations | per day   |
| Trip Generator     | 3 generations  | per day   |
| Screenshot Parser  | 10 scans       | per day   |
| Travel Assistant   | 30 messages    | per day   |
| Route Optimization | Unlimited      | on-device |
| Conflict Detection | Unlimited      | on-device |
| Export to Maps     | Unlimited      | no API    |

Limits enforced via Upstash Redis. Generous enough for real use, prevents abuse.

---

## Competitive Positioning Update

### Before (Original Plan)

```
V1: Organizer with AI email parsing
V2: Trip Stories (social)
V3: Commerce (affiliate)
V4: Platform (web + collaboration)
V5: AI planner (afterthought)
```

### After (AI-First Strategy)

```
V1:  Organizer with AI email parsing              ← Same
V2a: Trip Stories + On-Device Intelligence          ← 4 weeks after V1
     - Route Optimization (on-device, $0)
     - Export to Google Maps ($0)
     - Smart Conflict Detection (on-device, $0)
     - AI Place Recommendations (on-device, $0)
     - Multi-language booking parser
     - Trip Stories (brand-defining)
V2b: AI Generation Engine                           ← 3 weeks after V2a
     - AI Day Planner (GPT-4o-mini + Google validation)
     - AI Trip Generator (multi-call + validation)
     - Screenshot-to-Booking (GPT-4o vision)
V3:  Smart Travel Assistant + Commerce              ← 6 weeks after V2b
     - AI Chat Assistant
     - Smart Suggestions
     - Weather Rescheduling
     - Affiliate commerce
V4:  Predictive Intelligence + Platform
     - Preference learning
     - Community patterns
     - Web app + collaboration
V5:  Autonomous Travel Agent
     - Real-time rerouting
     - Proactive rebooking
     - Multi-modal (voice, photo)
```

**Why V2a/V2b split matters:** V2a features are zero-risk (on-device computation, no LLM dependency, no hallucination risk) and ship alongside Trip Stories. V2b features need 2-3 weeks of prompt engineering iteration, validation pipeline testing, and output quality tuning. Shipping them prematurely produces embarrassing results (wrong places, hallucinated restaurants) that destroy user trust in the AI brand.

### Why This Wins

| Competitor          | Their AI                    | Our Advantage                                        |
| ------------------- | --------------------------- | ---------------------------------------------------- |
| TripIt              | Email parsing only          | We parse + plan + optimize + suggest                 |
| Wanderlog           | Basic AI suggestions        | We generate full optimized itineraries               |
| Google Trips (dead) | Was generic recommendations | We're personalized + context-aware                   |
| Travo               | AI-first but no bookings    | We combine AI planning + booking management          |
| ChatGPT/Gemini      | Generic travel advice       | We're structured, editable, integrated with timeline |

**The key insight:** ChatGPT can plan a trip, but users can't DO anything with the result — they copy-paste into notes. Our AI plans AND directly populates an interactive, editable timeline with bookings, maps, and sharing. That's the 10x improvement.

---

## New UI Components for AI Features

### Components to Build

| Component                 | Screen             | Purpose                                                                            |
| ------------------------- | ------------------ | ---------------------------------------------------------------------------------- |
| `AIDayPlannerSheet`       | Trip Detail        | Minimal input (time window + free text + tappable defaults) + streaming generation |
| `AITripPreferences`       | Create Trip        | Single-screen preference input with smart defaults (replaces 4-card quiz)          |
| `AIPlanPreview`           | Trip Detail        | Review AI-generated itinerary with edit/accept                                     |
| `ConflictBadge`           | Timeline cards     | Amber dot on rail + card tint (NOT a separate banner)                              |
| `ConflictResolutionSheet` | Trip Detail        | Sequential resolution (one conflict at a time, recommended action + skip)          |
| `CollapsedSuggestion`     | Timeline           | Single-line collapsed suggestion indicator (tap to expand)                         |
| `ExpandedSuggestion`      | Timeline           | Full suggestion card with place list + actions (shown on tap)                      |
| `ChatSheet`               | Trip Detail        | AI assistant conversation (opened via Speed Dial, not floating button)             |
| `WeatherSuggestion`       | Timeline           | Collapsed weather indicator (follows one-per-day priority rule)                    |
| `ScreenshotScanner`       | Bookings screen    | Camera/gallery picker for bookings (moved from Speed Dial)                         |
| `ConfidenceBadge`         | Parsed bookings    | Binary: ✅ Verified or ⚠️ Check (with icon, not color-only)                        |
| `DayHeaderAction`         | Day headers        | Progressive contextual button: Plan → Optimize → Navigate (one at a time)          |
| `NearbySuggestions`       | Place detail sheet | "While you're nearby" discovery section (NOT inline on timeline)                   |

**Removed components:**

- ~~`AITripQuiz`~~ → replaced by `AITripPreferences` (single screen, not 4 swipeable cards)
- ~~`RouteOptimizerSheet`~~ → replaced by auto-apply with undo toast (no confirmation sheet)
- ~~`ExportMapsSheet`~~ → replaced by one-tap export with smart defaults (sheet only for >10 stops)
- ~~`ConflictBanner`~~ → replaced by `ConflictBadge` on cards + `ConflictResolutionSheet`
- ~~`SuggestionCard`~~ → replaced by `CollapsedSuggestion` + `ExpandedSuggestion` (collapsed by default)

### Updated Speed Dial FAB

Speed Dial never exceeds 4 items. "Scan Booking" (a sometimes-action, 2-3 times per trip) moves to the Bookings screen where it's contextually relevant.

```
  V1 (2 items):        V2a (3 items):       V3 (4 items — max):
  📍 Add Place         📍 Add Place         📍 Add Place
  ✈️ Add Booking        ✈️ Add Booking        ✈️ Add Booking
                        ✨ AI Plan Day        ✨ AI Plan Day
       ┌───┐                 ┌───┐           💬 Ask AI
       │ + │                 │ + │
       └───┘                 └───┘                 ┌───┐
                                                   │ + │
                                                   └───┘
```

**"Scan Booking" lives on the Bookings screen** as a prominent CTA button, not in the Speed Dial. It's a booking-management action, not a trip-building action. Keeping the FAB to 3 items (V2) ensures the fan-out animation stays clean and mis-tap risk stays low.

### Quick-Access Pills — Unchanged

The pills row does NOT get an "AI" pill. Every pill follows the same pattern: tap → push to one dedicated screen. AI features are woven into existing surfaces (day headers, create trip flow, speed dial), not quarantined in a separate section.

```
  V1 and V2 (same pills row):
  ┌────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐
  │🗺️  │  │✈️  4 │  │✅    │  │📝    │  │💰    │
  │Map │  │Book  │  │Soon  │  │Soon  │  │Soon  │
  └────┘  └──────┘  └──────┘  └──────┘  └──────┘
  No AI pill. Pattern stays consistent.
  AI features live where they're contextually useful:
  - Plan/Optimize/Navigate → day header contextual button
  - AI Trip Generator → Create Trip flow
  - Screenshot-to-Booking → Bookings screen
  - Ask AI → Speed Dial (V3)
```

---

## Updated Data Model

### New Tables

```sql
-- User AI preferences (learned over time)
create table public.user_ai_preferences (
  user_id uuid primary key references auth.users(id),
  preferred_pace text default 'balanced',     -- relaxed/balanced/busy
  interests text[] default '{}',              -- ['museums', 'food', 'nature']
  mobility text default 'moderate',           -- full/moderate/minimal
  dietary text[] default '{}',                -- ['vegetarian', 'gluten-free']
  typical_start_time time default '09:00',
  typical_dinner_time time default '19:00',
  daily_budget text default 'moderate',       -- budget/moderate/luxury
  trips_planned integer default 0,
  updated_at timestamptz default now()
);
-- AI generation history (for caching + analytics)
create table public.ai_generations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id),
  trip_id uuid references trips(id),
  generation_type text not null,              -- 'day_plan', 'full_trip', 'suggestion'
  input_params jsonb not null,
  output jsonb not null,
  model text not null,
  tokens_input integer,
  tokens_output integer,
  cost_usd numeric,
  accepted boolean,                           -- did user accept the result?
  created_at timestamptz default now()
);
-- Trip chat messages
create table public.trip_chat_messages (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references trips(id),
  user_id uuid references auth.users(id),
  role text not null,                         -- 'user' or 'assistant'
  content text not null,
  created_at timestamptz default now()
);
-- Weather cache (shared across users — not user-specific)
create table public.weather_cache (
  destination_key text not null,              -- 'paris_france'
  forecast_date date not null,
  forecast jsonb not null,                    -- { temp_high, temp_low, condition, rain_chance, ... }
  fetched_at timestamptz default now(),
  primary key (destination_key, forecast_date)
);
```

### Row Level Security Policies

All new tables must have RLS enabled. Users should never see another user's preferences, chat history, or AI generation logs.

```sql
-- user_ai_preferences: users can only read/write their own row
alter table public.user_ai_preferences enable row level security;
create policy "Users manage own AI preferences"
  on public.user_ai_preferences for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
-- ai_generations: users can only see their own generation history
alter table public.ai_generations enable row level security;
create policy "Users see own AI generations"
  on public.ai_generations for select
  using (auth.uid() = user_id);
create policy "Service role inserts AI generations"
  on public.ai_generations for insert
  with check (auth.uid() = user_id);
-- trip_chat_messages: users can only see chats for trips they own
alter table public.trip_chat_messages enable row level security;
create policy "Users see own trip chat messages"
  on public.trip_chat_messages for select
  using (auth.uid() = user_id);
create policy "Users insert own trip chat messages"
  on public.trip_chat_messages for insert
  with check (auth.uid() = user_id);
-- weather_cache: public read (not user-specific), service role write
alter table public.weather_cache enable row level security;
create policy "Anyone can read weather cache"
  on public.weather_cache for select
  using (true);
create policy "Service role writes weather cache"
  on public.weather_cache for insert
  with check (true);  -- restricted to service_role key in Edge Function
```

---

## Marketing Angle Update

### New V2 Taglines

**Primary:** "The travel app that thinks with you."

**Supporting:**

- "AI plans your perfect day in seconds."
- "One tap to optimize your route."
- "From screenshot to itinerary — AI handles the rest."
- "Your smartest travel companion."

### Demo Video Script (30 seconds)

```
[Screen: empty Day 2 in Paris trip]
"Day 2 in Paris. Eight hours free."
[Tap: ✨ Plan My Day]
"One tap."
[Quick preference selection: Balanced, Museums + Food]
[AI generates: 6 perfectly routed stops]
"AI plans your perfect day."
[Tap: 🔄 Optimize Route]
"Saves you 66 minutes of walking."
[Tap: 📤 Open in Google Maps]
"Navigate every stop."
[Final: full timeline with all AI-planned places]
"TripWeave. The travel app that thinks with you."
```

This 30-second demo shows THREE AI features in action — Day Planner, Route Optimizer, and Google Maps export. No competitor can demo this combination.

---

## Summary: AI as the Nervous System

| Layer            | What It Does           | AI Role                             |
| ---------------- | ---------------------- | ----------------------------------- |
| **Creation**     | User creates trip      | AI generates full itinerary         |
| **Organization** | User adds places       | AI optimizes route order            |
| **Validation**   | User reviews timeline  | AI detects conflicts                |
| **Navigation**   | User follows itinerary | AI exports to Google Maps           |
| **Adaptation**   | Weather changes        | AI suggests rescheduling            |
| **Discovery**    | User explores          | AI suggests nearby places           |
| **Assistance**   | User has questions     | AI chat answers with trip context   |
| **Import**       | User has bookings      | AI parses emails, screenshots, PDFs |

Every layer of the user experience is AI-enhanced. But in every case, the user stays in control. AI proposes, user disposes. This is not an AI app with a travel skin — it's a travel app with AI superpowers.
