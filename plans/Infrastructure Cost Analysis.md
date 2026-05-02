# Travel Planner — Infrastructure Cost Analysis (Final)

> **Overview:** Final cost analysis for native iOS app with corrected Google Places pricing (Essentials $5/1K on add, Pro $17/1K on tap only, both cached 30 days), Haversine for distances ($0), no Place Photos, no SendGrid, no Google Play, no Expo EAS. MapKit replaces Google Maps SDK (free, native). APNs replaces Expo Push (free, native). Total: $8/mo at launch, $60/mo at 1K DAU, $389/mo at 10K DAU. Cost per MAU: under 2 cents."

## Implementation checklist

- [ ] **implement-cost-controls** — Before V1 launch: on-device image compression (UIImage JPEG compression), Google autocomplete session tokens, place_details_cache table in Supabase (30-day TTL), Upstash rate limiting (50 searches/user/day), Google Cloud daily budget cap ($15/day), per-user storage quota (500 MB)
- [ ] **setup-missing-services** — Set up: PostHog iOS SDK (free), Mailgun inbound email (Foundation $35/mo), Apple Developer ($99/yr), domain ($12/yr), privacy policy static page
- [ ] **drop-unnecessary** — DROP: SendGrid (Supabase Auth + APNs replace it), Google Place Photos (SF Symbol icons-only timeline), Google Routes API (Haversine on-device), Google Static Maps ('Navigate' button instead), Google Maps SDK (MapKit is free + native), Expo EAS (Xcode + App Store Connect), Google Play Developer (iOS only)
- [ ] **build-cache-table** — Create place_details_cache table in Supabase (google_place_id PK, rating, reviews, priceLevel, openingHours, editorialSummary, cached_at, expires_at 30 days). Implement cache-check-before-fetch logic in PlaceDetailViewModel.
- [ ] **monitor-costs** — Set up: Google Cloud billing alerts ($50, $100, $200), Supabase usage dashboard, weekly cost review for first 2 months

---

## Complete Service Inventory

| #   | Service                        | Purpose                                                                   | Needed?                                          |
| --- | ------------------------------ | ------------------------------------------------------------------------- | ------------------------------------------------ |
| 1   | Google Places API (New)        | Place search (autocomplete), place details (name, address, coords, types) | Yes — Essentials SKU                             |
| 2   | Google Places API (Pro fields) | Rating, reviews, opening hours, price level, about                        | Yes — Pro SKU, on-tap only, cached 30 days       |
| 3   | Google Place Photos            | Place images                                                              | **NO — dropped. SF Symbol icons-only timeline.** |
| 4   | Google Routes API              | Distance/time between places                                              | **NO — dropped. Haversine on-device.**           |
| 5   | Google Static Maps             | Mini map on place detail                                                  | **NO — dropped. "Navigate" button instead.**     |
| 6   | MapKit (Apple)                 | Map display in app                                                        | Yes — **FREE**, native iOS framework             |
| 7   | Supabase Database              | PostgreSQL for all app data                                               | Yes                                              |
| 8   | Supabase Auth                  | Email + Sign in with Apple                                                | Yes — sends auth emails free                     |
| 9   | Supabase Storage               | Cover photos, user files (PDFs, tickets)                                  | Yes                                              |
| 10  | Supabase Edge Functions        | Generate days, date cascade, email processing                             | Yes                                              |
| 11  | Supabase Realtime              | Live parsed booking status updates                                        | Yes                                              |
| 12  | OpenAI GPT-4o-mini             | AI booking email parsing                                                  | Yes                                              |
| 13  | Mailgun                        | **Receiving** forwarded booking emails (inbound)                          | Yes                                              |
| 14  | SendGrid                       | Sending emails                                                            | **NO — dropped. Supabase Auth + APNs.**          |
| 15  | Upstash Redis                  | Place cache, rate limiting, session mgmt                                  | Yes                                              |
| 16  | Sentry                         | Error monitoring                                                          | Yes — Sentry Swift SDK                           |
| 17  | Unsplash API                   | Destination photos for trip covers                                        | Yes — free                                       |
| 18  | PostHog                        | Analytics (user behavior tracking)                                        | Yes — PostHog iOS SDK, free                      |
| 19  | APNs (Apple Push)              | Push notifications                                                        | Yes — **FREE**, native iOS, unlimited            |
| 20  | Apple Developer Program        | App Store submission                                                      | Yes — $99/year                                   |
| 21  | Domain                         | Forwarding email address + privacy policy                                 | Yes — $12/year                                   |

**11 active services. 6 dropped (saving $400-5,000+/month at scale + eliminating Expo EAS and Google Play fees).** Google Maps SDK replaced by MapKit (native, free). Expo Push replaced by APNs (native, free). Expo EAS replaced by Xcode + App Store Connect (free). Google Play Developer no longer needed (iOS only).

---

## User Behavior Model

| Behavior                           | Value               | Notes                                        |
| ---------------------------------- | ------------------- | -------------------------------------------- |
| App opens per DAU per day          | ~2.5 average        | 3-5 during trip, 1-2 planning, 0.3 otherwise |
| Places added per trip              | 35                  | 5/day × 7 days                               |
| Bookings per trip                  | 3-5                 | Flight, hotel, 1-2 restaurants               |
| Trips per user per month           | ~1                  | Active planners                              |
| % of DAU actively planning         | 30%                 | Searching/adding places                      |
| % of DAU viewing only              | 70%                 | Checking timeline                            |
| Place detail taps per session      | 3-5                 | ~15% of places tapped for Pro detail         |
| Booking emails forwarded per month | 2-3 per active user | Flight + hotel confirmations                 |
| Cover photos uploaded              | 50% of users        | 1 per trip, ~300 KB compressed               |
| Files uploaded per trip            | 1-2                 | PDF tickets, ~500 KB each                    |
| DAU to MAU ratio                   | ~1:3                | 1K DAU ≈ 3K MAU                              |

---

## Google Places API — Two-Tier Fetch Strategy

### How It Works

```
  User searches "Le Petit Cler"
       │
  Autocomplete (session token) ──── $0 (bundled in session)
       │
  User selects the place
       │
  Fetch Place Details ESSENTIALS ── $5/1K (name, address, location, types)
       │                              First 10K/month free
  Save to Supabase places table
       │
  Timeline card shows:  🍴 Le Petit Cler
                        25 Rue Cler, Paris
                        12:15 PM - 1:30 PM
  ─────────────────────────────────────────────
  Later: User TAPS the card for details
       │
  Check place_details_cache for google_place_id
       │
       ├── CACHE HIT (within 30 days) ── $0
       │   Show: rating, reviews, hours, price, about
       │
       └── CACHE MISS ── Fetch Place Details PRO ── $17/1K
           Fields: rating, userRatingCount, priceLevel,       First 5K/month free
                   currentOpeningHours, editorialSummary,
                   reviews (top 5)
           Save to place_details_cache (30-day TTL)
```

### Pricing (Confirmed Current Rates)

| SKU                        | Rate per 1K | Free Monthly Cap | When Called                           |
| -------------------------- | ----------- | ---------------- | ------------------------------------- |
| Autocomplete Session Usage | FREE        | Unlimited        | Every keystroke (bundled)             |
| Place Details Essentials   | $5/1K       | 10,000           | Every place added                     |
| Place Details Pro          | $17/1K      | 5,000            | Place detail tapped (cache miss only) |
| Place Details Photos       | $7/1K       | 1,000            | **NEVER called**                      |

### Cost at Each Scale

**100 DAU:**

| SKU                         | Calls/Month | Free Cap | Billable | Cost   |
| --------------------------- | ----------- | -------- | -------- | ------ |
| Essentials                  | 1,050       | 10,000   | 0        | $0     |
| Pro (20% cache hit)         | 126         | 5,000    | 0        | $0     |
| **Total minus $200 credit** |             |          |          | **$0** |

**1,000 DAU:**

| SKU                               | Calls/Month      | Free Cap | Billable | Cost   |
| --------------------------------- | ---------------- | -------- | -------- | ------ |
| Essentials                        | 10,500           | 10,000   | 500      | $2.50  |
| Pro (50% cache hit, 15% tap rate) | 630 cache misses | 5,000    | 0        | $0     |
| **Total**                         |                  |          |          | $2.50  |
| **Minus $200 credit**             |                  |          |          | **$0** |

**10,000 DAU (Month 4-6, 65% cache hit):**

| SKU                               | Calls/Month                                         | Free Cap | Billable | Cost     |
| --------------------------------- | --------------------------------------------------- | -------- | -------- | -------- |
| Essentials                        | 105,000                                             | 10,000   | 95,000   | $475     |
| Pro (65% cache hit, 15% tap rate) | 6,300 total, 2,205 misses + 3,300 refreshes = 5,505 | 5,000    | 505      | $8.59    |
| **Total**                         |                                                     |          |          | $483.59  |
| **Minus $200 credit**             |                                                     |          |          | **$284** |

**10,000 DAU (Month 12, 75% cache hit):**

| SKU                   | Calls/Month       | Free Cap | Billable | Cost     |
| --------------------- | ----------------- | -------- | -------- | -------- |
| Essentials            | 105,000           | 10,000   | 95,000   | $475     |
| Pro (75% cache hit)   | 3,900 total calls | 5,000    | 0        | $0       |
| **Total**             |                   |          |          | $475     |
| **Minus $200 credit** |                   |          |          | **$275** |

---

## Distance Between Places — Haversine (Free)

All 4 transport modes calculated on-device using the Haversine formula:

```swift
func estimateTravelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: TravelMode) -> Int {
    let straightLineKm = haversineDistance(from: from, to: to)
    let factor: (multiplier: Double, speedKmh: Double) = switch mode {
        case .driving:  (1.4, 35)
        case .walking:  (1.3, 5)
        case .cycling:  (1.3, 15)
        case .transit:  (1.5, 25)
    }
    return Int((straightLineKm  *factor.multiplier / factor.speedKmh*  60).rounded())
}
```

Timeline gap shows: `🚶 12 min · 🚗 4 min`

Tap gap → "Navigate" button opens Google Maps / Apple Maps with coordinates. Exact routing handled by their app (free).

**Accuracy: ~80% vs Google Routes. Cost: $0. Saved: $2,000+/month at 10K DAU.**

---

## Supabase — Full Breakdown

### Database

| DAU    | MAU    | DB Size | Reads/Month | Writes/Month | Plan          | Cost |
| ------ | ------ | ------- | ----------- | ------------ | ------------- | ---- |
| 100    | 300    | 24 MB   | 7,500       | 3,000        | Free (500 MB) | $0   |
| 1,000  | 3,000  | 240 MB  | 75,000      | 30,000       | Free (500 MB) | $0   |
| 10,000 | 30,000 | 2.4 GB  | 750,000     | 300,000      | Pro (8 GB)    | $25  |

### Storage

| DAU    | Stored (cumulative 6mo) | New/Month | Thumbnail Egress/Month | Plan                         |
| ------ | ----------------------- | --------- | ---------------------- | ---------------------------- |
| 100    | 1.2 GB                  | 200 MB    | 1.1 GB                 | Free (1 GB) — near limit     |
| 1,000  | 12 GB                   | 2 GB      | 11 GB                  | Pro (100 GB) — included      |
| 10,000 | 120 GB                  | 20 GB     | 112 GB                 | Pro — ~$4 overage on storage |

### Auth

| DAU    | MAU    | Limit         | Cost |
| ------ | ------ | ------------- | ---- |
| 100    | 300    | Free: 50K MAU | $0   |
| 1,000  | 3,000  | Free: 50K MAU | $0   |
| 10,000 | 30,000 | Free: 50K MAU | $0   |

Auth emails (verification, password reset) sent by Supabase built-in email. No SendGrid needed.

### Edge Functions

| DAU    | Invocations/Month | Free Cap | Cost |
| ------ | ----------------- | -------- | ---- |
| 100    | ~100              | 500,000  | $0   |
| 1,000  | ~1,000            | 500,000  | $0   |
| 10,000 | ~10,000           | 500,000  | $0   |

Triggers: generate-days (trip create), date-cascade (trip edit), email-parse (forwarded email).

### Realtime

| DAU    | Peak Concurrent Connections | Limit     | Cost |
| ------ | --------------------------- | --------- | ---- |
| 100    | 1-5                         | Free: 200 | $0   |
| 1,000  | 10-50                       | Pro: 500  | $0   |
| 10,000 | 100-500                     | Pro: 500  | $0   |

Only users on "Review Forwarded Bookings" screen use Realtime (1-5% of DAU).

### Total Egress (All Supabase Services Combined)

| DAU    | DB Egress | Storage Egress | Functions | Total    | Pro Quota (250 GB) | Cost |
| ------ | --------- | -------------- | --------- | -------- | ------------------ | ---- |
| 100    | 165 MB    | 1.1 GB         | 10 MB     | 1.3 GB   | Free: 5 GB         | $0   |
| 1,000  | 1.65 GB   | 11.5 GB        | 100 MB    | 13.3 GB  | Pro: 250 GB        | $0   |
| 10,000 | 16.5 GB   | 115 GB         | 1 GB      | 132.5 GB | Pro: 250 GB        | $0   |

Egress is well within Pro quota at all scales up to 10K DAU.

### Supabase Total

| DAU    | DB        | Storage    | Auth | Functions | Realtime | Egress | **Total** |
| ------ | --------- | ---------- | ---- | --------- | -------- | ------ | --------- |
| 100    | $0        | $0         | $0   | $0        | $0       | $0     | **$0**    |
| 1,000  | $25 (Pro) | incl.      | $0   | $0        | $0       | $0     | **$25**   |
| 10,000 | $25 (Pro) | $4 overage | $0   | $0        | $0       | $0     | **$29**   |

---

## OpenAI GPT-4o-mini — Booking Parsing

| Rate                               | Value                |
| ---------------------------------- | -------------------- |
| Input                              | $0.15 per 1M tokens  |
| Output                             | $0.60 per 1M tokens  |
| Cached input                       | $0.075 per 1M tokens |
| Per parse (~2K input, ~500 output) | $0.0006              |
| DAU    | Parses/Month | Cost      |
| ------ | ------------ | --------- |
| 100    | 60           | **$0.04** |
| 1,000  | 600          | **$0.36** |
| 10,000 | 6,000        | **$3.60** |

---

## Mailgun — Inbound Email

| DAU    | Inbound Emails/Month | Plan                    | Cost    |
| ------ | -------------------- | ----------------------- | ------- |
| 100    | 60                   | Free trial (30 days)    | **$0**  |
| 1,000  | 600                  | Foundation (50K emails) | **$35** |
| 10,000 | 6,000                | Foundation (50K emails) | **$35** |

Flat $35/month regardless of volume (well within 50K cap at all V1-V2 scales).

---

## Upstash Redis

| Use                | Commands/Operation |
| ------------------ | ------------------ |
| Place cache check  | 1 GET              |
| Place cache write  | 1 SET (24h TTL)    |
| Rate limit check   | 2 (GET + INCR)     |
| Session management | 2 (GET + SET)      |
| DAU    | Commands/Month | Free Cap (500K) | Overage          | Cost   |
| ------ | -------------- | --------------- | ---------------- | ------ |
| 100    | 30,000         | Within          | --               | **$0** |
| 1,000  | 300,000        | Within          | --               | **$0** |
| 10,000 | 3,000,000      | Exceeded        | 2.5M × $0.2/100K | **$5** |

---

## Sentry

| DAU    | Errors/Month (0.5% rate) | Free Cap (5K) | Plan | Cost    |
| ------ | ------------------------ | ------------- | ---- | ------- |
| 100    | 200                      | Within        | Free | **$0**  |
| 1,000  | 2,000                    | Within        | Free | **$0**  |
| 10,000 | 10,000                   | Exceeded      | Team | **$26** |

---

## Unsplash — Trip Cover Photos

| DAU | Requests/Month                 | Rate Limit                    | Cost           |
| --- | ------------------------------ | ----------------------------- | -------------- |
| Any | ~~trips created (~~10% of MAU) | 5K/hour (Production approved) | **$0 forever** |

URL cached in trips table. Never re-fetched.

---

## PostHog — Analytics

| DAU    | Events/Month (~10 events/session × 2.5 sessions/day) | Free Cap (1M) | Cost                              |
| ------ | ---------------------------------------------------- | ------------- | --------------------------------- |
| 100    | 75,000                                               | Within        | **$0**                            |
| 1,000  | 750,000                                              | Within        | **$0**                            |
| 10,000 | 7,500,000                                            | Exceeded      | **$0** (self-host or trim events) |

Track only meaningful events: trip_created, place_added, booking_added, place_searched, detail_viewed, email_forwarded. Not every tap.

---

## APNs (Apple Push Notification service)

**Free. Unlimited. Native iOS.** No third-party push service needed. Server-side sending via Supabase Edge Functions using APNs HTTP/2 API or a lightweight library.

| DAU | Cost   |
| --- | ------ |
| Any | **$0** |

---

## Build & Distribution — Xcode + App Store Connect

No Expo EAS needed. Builds are done locally via Xcode or automated via Xcode Cloud (free tier: 25 compute hours/month).

| DAU    | MAU    | Plan                                                  | Cost   |
| ------ | ------ | ----------------------------------------------------- | ------ |
| 100    | 300    | Xcode local builds + App Store Connect (free)         | **$0** |
| 1,000  | 3,000  | Xcode local builds + App Store Connect (free)         | **$0** |
| 10,000 | 30,000 | Xcode Cloud free tier or Fastlane (free, self-hosted) | **$0** |

V1 strategy: Build locally with Xcode, archive and upload to App Store Connect. TestFlight for beta distribution. No OTA update system needed — SwiftUI apps use standard App Store releases.

---

## Fixed Costs

| Item                    | Annual | Monthly   |
| ----------------------- | ------ | --------- |
| Apple Developer Program | $99    | $8.25     |
| Domain                  | $12    | $1.00     |
| **Total**               |        | **$9.25** |

Google Play Developer fee ($25 one-time) no longer applies — iOS only.

---

## FINAL MONTHLY COST TABLE

### 100 DAU (Launch)

| Service           | Cost         |
| ----------------- | ------------ |
| Google Places API | $0           |
| MapKit            | $0 (native)  |
| Supabase          | $0           |
| OpenAI            | $0.04        |
| Mailgun           | $0 (trial)   |
| Upstash           | $0           |
| Sentry            | $0           |
| Unsplash          | $0           |
| PostHog           | $0           |
| APNs              | $0 (native)  |
| Fixed             | $9           |
| **TOTAL**         | **$9/month** |

### 1,000 DAU (~3K MAU)

| Service            | Cost                    |
| ------------------ | ----------------------- |
| Google Places API  | $0 (within $200 credit) |
| MapKit             | $0 (native)             |
| Supabase Pro       | $25                     |
| OpenAI             | $0.36                   |
| Mailgun Foundation | $35                     |
| Upstash            | $0                      |
| Sentry             | $0                      |
| Unsplash           | $0                      |
| PostHog            | $0                      |
| APNs               | $0 (native)             |
| Fixed              | $9                      |
| **TOTAL**          | **$69/month**           |

### 10,000 DAU (~30K MAU, Month 4-6)

| Service                                     | Cost           |
| ------------------------------------------- | -------------- |
| Google Places API (Essentials + Pro cached) | $284           |
| MapKit                                      | $0 (native)    |
| Supabase Pro + Storage overage              | $29            |
| OpenAI                                      | $3.60          |
| Mailgun Foundation                          | $35            |
| Upstash                                     | $5             |
| Sentry Team                                 | $26            |
| Unsplash                                    | $0             |
| PostHog                                     | $0             |
| APNs                                        | $0 (native)    |
| Fixed                                       | $9             |
| **TOTAL**                                   | **$392/month** |

### 10,000 DAU (Month 12, cache matured)

| Service                           | Cost           |
| --------------------------------- | -------------- |
| Google Places API (75% cache hit) | $275           |
| MapKit                            | $0 (native)    |
| Supabase Pro + Storage overage    | $29            |
| OpenAI                            | $3.60          |
| Mailgun Foundation                | $35            |
| Upstash                           | $5             |
| Sentry Team                       | $26            |
| Unsplash                          | $0             |
| PostHog                           | $0             |
| APNs                              | $0 (native)    |
| Fixed                             | $9             |
| **TOTAL**                         | **$383/month** |

### Add V2 Flight Tracking

| Addition at 10K DAU         | Cost           |
| --------------------------- | -------------- |
| AviationStack Professional  | +$150/month    |
| **10K DAU + V2 (month 4)**  | **$542/month** |
| **10K DAU + V2 (month 12)** | **$533/month** |

---

## Cost Per User

| Scale              | Total/Month | Per DAU | Per MAU |
| ------------------ | ----------- | ------- | ------- |
| 100 DAU            | $9          | $0.090  | $0.030  |
| 1,000 DAU          | $69         | $0.069  | $0.023  |
| 10,000 DAU (mo 4)  | $392        | $0.039  | $0.013  |
| 10,000 DAU (mo 12) | $383        | $0.038  | $0.013  |
| 10,000 DAU + V2    | $542        | $0.054  | $0.018  |

**Cost per user decreases as scale increases.** Fixed costs (Supabase Pro, Mailgun, EAS) amortize. Variable costs (Google, OpenAI) are tiny per-user. Cache hit rate improves over time, further reducing Google costs.

---

## What Breaks First (Upgrade Triggers)

| Trigger                       | DAU              | Action                         | Monthly Impact |
| ----------------------------- | ---------------- | ------------------------------ | -------------- |
| Supabase Free storage (1 GB)  | ~300             | Upgrade to Pro                 | +$25           |
| Mailgun trial expires         | Day 31           | Foundation plan                | +$35           |
| Supabase Free egress (5 GB)   | ~400             | Upgrade to Pro (covered above) | +$0            |
| Google $200 credit exceeded   | ~1,500           | Pay-per-use starts             | +$5-30         |
| Upstash 500K commands         | ~2,000           | Pay-per-use starts             | +$2-5          |
| Sentry 5K errors              | ~5,000           | Upgrade to Team                | +$26           |
| Supabase Pro storage (100 GB) | ~8,000 (month 6) | Overage charges                | +$4-10         |

**First paid upgrade: Supabase Pro at ~300 DAU ($25/month).**

---

## Anti-Abuse Protections

| Protection                | Implementation                                                   | Prevents                    |
| ------------------------- | ---------------------------------------------------------------- | --------------------------- |
| Google Cloud daily budget | $15/day cap in GCP Console                                       | Runaway API costs           |
| Place search rate limit   | Upstash: 50/user/day                                             | Search abuse                |
| Booking rate limit        | Upstash: 20/user/day                                             | Spam creation               |
| File upload rate limit    | Upstash: 10/user/day                                             | Storage abuse               |
| Email forward limit       | Server: 20/user/month                                            | Email processing abuse      |
| Sign-up rate limit        | Upstash: 3/IP/hour                                               | Fake accounts               |
| Image compression         | UIImage jpegData(compressionQuality: 0.8), resized to 1200px max | Storage bloat (2MB → 300KB) |
| File size cap             | 20 MB per file                                                   | Large file abuse            |
| Per-user storage quota    | 500 MB total                                                     | Individual abuse            |
| Auth on all tables        | Supabase RLS                                                     | Anonymous access            |

---

## Dropped Services (Savings)

| Dropped             | Monthly Savings at 10K DAU | Replaced By                                   |
| ------------------- | -------------------------- | --------------------------------------------- |
| Google Place Photos | $350-5,000+                | SF Symbol category icons on timeline          |
| Google Routes API   | $2,000+                    | Haversine formula (on-device)                 |
| Google Static Maps  | $30-160                    | "Navigate" button → Apple Maps (MKMapItem)    |
| Google Maps SDK     | $0 (was free)              | MapKit (native, free, better iOS integration) |
| SendGrid            | $20-90                     | Supabase Auth (free) + APNs (free, native)    |
| Expo EAS            | $0-99                      | Xcode + App Store Connect (free)              |
| Google Play Dev     | $2.08/mo (amortized)       | N/A — iOS only                                |
| **Total saved**     | **$2,400-7,350+/month**    |                                               |

---

## Optimizations Baked Into These Numbers

| Optimization                             | Implementation                                      | Savings at 10K DAU              |
| ---------------------------------------- | --------------------------------------------------- | ------------------------------- |
| SF Symbol icons-only timeline            | SF Symbol category icon + day color on cards        | $350-5,000/mo (no Place Photos) |
| Haversine distances                      | On-device formula, 4 modes (CLLocation)             | $2,000+/mo (no Routes API)      |
| Autocomplete session tokens              | `sessionToken` in API calls                         | $500-2,000/mo                   |
| Two-tier fetch (Essentials + Pro on tap) | Field masks per call                                | ~$1,200/mo                      |
| 30-day Pro data cache                    | `place_details_cache` in Supabase                   | ~$300/mo (growing over time)    |
| On-device image compression              | UIImage jpegData(compressionQuality: 0.8) + resize  | 85% storage reduction           |
| Thumbnail serving                        | 50 KB thumbs on lists, full on gallery              | 80% egress reduction            |
| CDN caching on Storage                   | Cache headers on Supabase buckets                   | 80% origin egress reduction     |
| Native MapKit                            | Replaces Google Maps SDK (already free, but native) | Better performance + no SDK dep |
| Native APNs                              | Replaces Expo Push — direct Apple integration       | $0 + simpler architecture       |
| Drop SendGrid                            | Supabase Auth + APNs                                | $20-90/mo                       |
| Server-side flight polling (V2)          | One cron for all users, not per-client              | 40-60% flight API reduction     |

---

## Cache Table Schema

```sql
create table public.place_details_cache (
  google_place_id text primary key,
  name text not null,
  rating numeric,
  user_rating_count integer,
  price_level text,
  editorial_summary text,
  opening_hours jsonb,
  reviews jsonb,
  website_uri text,
  phone_number text,
  cached_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days')
);
create index idx_cache_expires on public.place_details_cache(expires_at);
```

**Cache logic in app (PlaceDetailViewModel):**

1. User taps place card → async query `place_details_cache` WHERE `google_place_id = ?` AND `expires_at > now()`

2. Hit → return cached data ($0)

3. Miss → fetch Place Details Pro from Google via URLSession ($17/1K), upsert into cache via supabase-swift

4. Background job (Supabase cron): delete rows where `expires_at < now() - interval '7 days'` (cleanup)

---

## Monthly Burn Rate Visual

```
  $600 ┤
       │                                         ████ $542 (+ V2 flight)
  $500 ┤
       │
  $400 ┤                                         ████ $392 (V1 only, mo 4)
       │                                         ████ $383 (V1 only, mo 12)
  $300 ┤
       │
  $200 ┤
       │
  $100 ┤                        ████ $69
       │
    $0 ┤  ████ $9
       └──────────────────────────────────────────
          100 DAU       1K DAU              10K DAU
  Savings vs Expo stack: ~$101/mo at 10K DAU (no Expo EAS, no Google Play)
```

**Bottom line: $9/month at launch. $69/month at 1K DAU. Under $400/month at 10K DAU. Cost per MAU under 1.5 cents. Native iOS eliminates Expo EAS ($99/mo) and Google Play ($25) costs entirely. V3 affiliate revenue ($0.02+/MAU) makes this self-sustaining.**