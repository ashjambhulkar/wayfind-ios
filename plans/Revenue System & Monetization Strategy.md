# TripWeave — Revenue System & Monetization Strategy

> **Overview:** Complete revenue system from V2 onward with senior engineering + UX review findings applied. Key corrections: StoreKit 2 architecture fixed (separate subscription groups, non-consumable lifetime, Transaction.updates listener, server-side JWS validation via Edge Function), usage limits enforced server-side not UserDefaults (event-sourced counting replaces mutable counters), Tip Jar redesigned as 'Supporter Badge' to comply with App Store Guideline 3.1.1, 'Priority AI Processing' removed as marketed feature (dark pattern), Trip Stories branding kept for ALL users (subtle credit, not watermark — Pro gets premium templates but branding stays for virality), paywall redesigned (single CTA focus, SF Symbols replacing emoji, positive framing), insurance card moved out of Create Trip flow, win-back changed from push notification to in-app offer, template packs repriced to $0.99 impulse tier, annual renewal reminder removed (increases churn per research), sponsored placements relabeled 'Sponsored' per Apple ad guidelines. Nine revenue streams. Self-sustaining at ~400 DAU. Projected $13K-15K/mo at 10K DAU (V3)."

## Implementation checklist

- [ ] **storekit-setup** — V2 Sprint Week 1: Set up StoreKit 2 configuration file in Xcode, define product IDs (tripweave_pro_monthly, tripweave_pro_annual, tripweave_pro_lifetime), App Store Connect in-app purchase setup, sandbox testing environment
- [ ] **entitlement-system** — V2 Sprint Week 1: Build EntitlementManager (@Observable) — checks subscription status via StoreKit 2 Transaction.currentEntitlements, gates features via FeatureFlag enum, caches entitlement state, handles grace periods and billing retry
- [ ] **paywall-ui** — V2 Sprint Week 1: Build PaywallView — contextual (shows relevant feature), annual toggle with savings badge, feature comparison list, restore purchases, family sharing note. Build UpgradePromptView for soft-wall inline prompts.
- [ ] **feature-gating** — V2 Sprint Week 2: Implement feature gates — .isProFeature checks in AI Day Planner (>2/mo), Trip Stories templates (>2), email forwarding (>5/mo), route optimization (>3/mo), export tools, screenshot parser. Free tier limits tracked in UserDefaults + Supabase.
- [ ] **subscription-analytics** — V2 Sprint Week 2: Set up subscription analytics — PostHog events for paywall_shown, paywall_converted, trial_started, trial_converted, subscription_cancelled, feature_limit_hit. App Store Connect analytics for MRR, churn, trial conversion.
- [ ] **affiliate-integration** — V3: Integrate Viator Partner API (8% commission), Kiwi Tequila (flight affiliate links), [Booking.com](https://www.booking.com) (hotel affiliate), CarTrawler (car rental affiliate). Build AffiliateTrackingService for attribution and commission tracking.
- [ ] **revenue-dashboard** — V3: Build internal revenue dashboard — MRR tracker, affiliate commission tracker, conversion funnel visualization, cohort retention analysis, LTV calculation
- [ ] **b2b-licensing** — V4: Design B2B licensing model for travel agencies and corporate travel — white-label API, bulk subscription pricing, partner portal

---

## Senior Engineering + UX Review Findings

This plan has been reviewed by a senior software engineer and senior UI/UX designer. All corrections are applied inline with `> **Review correction:**` callouts explaining what changed and why.

### Critical Engineering Fixes

| #   | Issue                                                                                                                                                                                                                                                                                                                                                             | Severity     | Fix                                                                                                                                                                                                                                                                           |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1  | `SubscriptionProduct` enum mixes subscriptions, non-consumables, and consumables in one type. StoreKit 2 treats these fundamentally differently — subscriptions live in subscription groups, lifetime is a non-consumable, tips are consumables                                                                                                                   | **Critical** | Split into 3 separate types: `ProSubscription`, `OneTimePurchase`, `ConsumablePurchase`. Monthly + Annual in one subscription group. Lifetime as non-consumable. Tips as consumables. Flight Alerts as separate subscription group                                            |
| E2  | `EntitlementManager.checkEntitlements()` uses `for await in Transaction.currentEntitlements` as a one-shot check, but `currentEntitlements` is an `AsyncSequence` that completes after yielding all current items. Missing: `Transaction.updates` listener for real-time entitlement changes (renewals, revocations, family sharing changes) while app is running | **Critical** | Add `Task` that listens to `Transaction.updates` on app launch. Call `Transaction.finish()` on verified transactions. Separate initial entitlement load from ongoing monitoring                                                                                               |
| E3  | Zero server-side receipt/transaction validation. All entitlement checking is on-device only. Jailbroken devices bypass all gates. Refund fraud undetected. Supabase Edge Functions can't verify Pro status before executing expensive AI calls ($0.03-0.17 each)                                                                                                  | **Critical** | Send JWS (JSON Web Signature) from `Transaction.jwsRepresentation` to a Supabase Edge Function that validates with Apple's App Store Server API. Store subscription status in `user_subscriptions` table. Edge Functions check this table before executing AI calls           |
| E4  | Usage tracking via UserDefaults is trivially manipulable (delete app data, reset device date). Free tier limits have no server-side enforcement                                                                                                                                                                                                                   | **High**     | Event-sourced usage tracking: log each usage event to `usage_events` table. Count dynamically with `WHERE created_at >= date_trunc('month', now())`. Eliminates need for mutable counter table and fragile monthly reset cron. Edge Functions enforce limits before executing |
| E5  | `AffiliateTrackingService.generateAffiliateURL` force-unwraps `components.url!` — production crash if URL construction fails with unexpected characters in destination names (e.g., Japanese, Arabic, special chars)                                                                                                                                              | **Medium**   | Return `URL?` and handle nil gracefully. URL-encode destination parameter                                                                                                                                                                                                     |
| E6  | `affiliate_clicks` table has no indices on `user_id`, `trip_id`, or `clicked_at`. Query performance degrades at scale                                                                                                                                                                                                                                             | **Medium**   | Add composite index on `(user_id, clicked_at)` and index on `trip_id`                                                                                                                                                                                                         |
| E7  | Monthly usage reset via `pg_cron` is a single point of failure. If Supabase has downtime on the 1st of the month, users don't get their reset. Race condition: user makes request at 23:59:59, cron runs at 00:00:00, response arrives at 00:00:01 — counted in wrong period                                                                                      | **Medium**   | Eliminated by E4 (event-sourced counting). No mutable state to reset                                                                                                                                                                                                          |
| E8  | Custom "3-day grace period" after Pro expiration conflicts with StoreKit 2's native billing grace period `Product.SubscriptionInfo.RenewalInfo.gracePeriod`). Users could get double grace periods                                                                                                                                                               | **Low**      | Remove custom grace period. Rely on Apple's built-in billing retry and grace period. Show "Subscription expired" state only after Apple confirms non-renewal                                                                                                                  |
| E9  | Family Sharing not addressed. If enabled, one Pro subscription covers 6 family members — impacts revenue projections by up to 6x per-subscriber. If disabled without justification, may face App Store pushback                                                                                                                                                   | **Medium**   | Explicitly disable Family Sharing for Pro subscription (justified: AI usage scales per-user with real cost). Document rationale for App Store review                                                                                                                          |

### Critical UX Fixes

| #   | Issue                                                                                                                                                                                                                                                                                              | Severity     | Fix                                                                                                                                                                                                                                                                                                                                                             |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| U1  | Paywall shows trial CTA + 3 pricing tiers simultaneously (4 choices). Violates Hick's Law — decision time increases logarithmically with choices. Apple's own subscription UIs use single primary CTA                                                                                              | **High**     | Redesign: single primary CTA ("Start Free Trial"), pricing selector is secondary (segmented control, not 3 stacked cards). Lifetime moves to a "More options" link                                                                                                                                                                                              |
| U2  | Feature list uses emoji icons (✨🎨📧🔄📄📸📊🚀🎁) instead of SF Symbols. Inconsistent with the app's SF Pro Rounded + SF Symbols design system. Emojis render differently across iOS versions and feel informal                                                                                    | **High**     | Replace all emoji in paywall with SF Symbols: `sparkles`, `paintbrush.fill`, `envelope.fill`, `arrow.triangle.2.circlepath`, `doc.fill`, `camera.viewfinder`, `chart.bar.fill`, `bolt.fill`, `gift.fill`                                                                                                                                                        |
| U3  | "Priority AI Processing" marketed as a Pro feature is a dark pattern. If free users are artificially slowed, that's punitive. If they aren't, the feature is fake. Either way, Apple HIG advises against features that exist only to create friction in the free tier                              | **High**     | Remove "Priority AI Processing" from Pro feature list. If Pro users naturally get faster responses (fewer rate limits), that's a side effect — not a selling point. Replace with "AI Travel Assistant Chat" (genuinely Pro-exclusive, V3 early access)                                                                                                          |
| U4  | "Not now" text below CTA creates a visual anchor on the negative action. Apple's design language uses the system dismiss affordance (drag-down gesture or [✕] button), not a text link that competes with the CTA                                                                                  | **Medium**   | Remove "Not now" text. Sheet dismisses via standard drag-down or [✕]. This is a `.sheet` — the dismiss mechanism is built into the presentation                                                                                                                                                                                                                 |
| U5  | Limit messaging is transactional: "You've used 2 of 2 free AI plans." Feels like a meter running out — creates anxiety, not aspiration. Apple's approach: lead with accomplishment, then offer more                                                                                                | **High**     | Reframe: "You've planned 2 amazing days this month! Unlock unlimited AI planning with Pro." Lead with value delivered, not quota consumed                                                                                                                                                                                                                       |
| U6  | Trip Stories branding strategy is inverted. Free users get watermark (marketing), Pro users remove it (lose marketing from most engaged users). The Feature Roadmap says "Every shared card is a billboard" — removing branding from paying users eliminates the billboard effect from power users | **High**     | All users get a subtle "Made with TripWeave" credit line (not a watermark — a tasteful attribution like "Shot on iPhone"). Pro users get premium templates, custom colors, high-res export — but the credit stays by default. Pro users CAN disable it in Settings, but default is on. This preserves virality across ALL users while still offering the option |
| U7  | Template packs at $1.99 create unfavorable comparison with Pro at $4.99/mo. A user considering a $1.99 pack sees that $4.99 gets them EVERYTHING. The pack becomes irrational, but its existence adds decision fatigue                                                                             | **Medium**   | Reprice packs to $0.99 (impulse buy territory). At $0.99, users buy without comparing to Pro. This is the "sticker pack" pricing model — low enough to be a no-brainer. Bundle stays at $2.99. Pro still includes all packs                                                                                                                                     |
| U8  | Tip Jar as pure "Support the Developer" violates App Store Guideline 3.1.1 — Apple rejects consumable IAPs that provide no content/functionality. Tips MUST deliver something                                                                                                                      | **Critical** | Redesign as "Supporter Badge" system. Each tip unlocks a permanent badge on the user's profile (☕ Coffee Supporter, 🍕 Meal Supporter, ✈️ Flight Supporter) and a one-time "thank you" animation. This provides tangible value (social recognition) while capturing the same goodwill revenue                                                                   |
| U9  | Insurance card in Create Trip flow violates the stated Rule #4 ("Never interrupt trip planning") and the UI spec's "Only 2 inputs" principle for trip creation. Commercial element at a moment of excitement adds friction                                                                         | **High**     | Move insurance suggestion to Trip Detail screen — inline card below pills row (same pattern as email forwarding discovery). Appears 24-48 hours after trip creation, not during creation. Dismissible with "Don't show again" per-trip. Never shows during active trip                                                                                          |
| U10 | Win-back push notification ("We miss you! Come back to Pro at 50% off") feels promotional and needy. Apple's push notification guidelines discourage purely promotional pushes. Users who cancelled consciously may find this pushy and uninstall                                                  | **Medium**   | Replace with in-app offer only. When a lapsed subscriber opens the app, show a gentle inline card (not modal) on the Trips List: "Welcome back! Pro is available at 50% off this month." Use StoreKit's `Product.SubscriptionOffer` for promotional pricing. No push notification                                                                               |
| U11 | Annual renewal reminder 30 days before charge. Research (Recurly 2023, Baremetrics data) shows proactive renewal reminders INCREASE cancellation rates by 15-25%. Users who weren't thinking about cancelling are prompted to reconsider                                                           | **High**     | Remove the 30-day in-app renewal reminder. Apple already sends system-level renewal emails. Show value summary ONLY if user opens Settings → Subscription (where they're already considering their subscription). Don't proactively surface billing reminders                                                                                                   |
| U12 | Sponsored placements labeled "FEATURED" — Apple may require "Sponsored" or "Ad" per advertising transparency guidelines. "Featured" implies editorial curation, which is misleading for paid placement                                                                                             | **Medium**   | Relabel to "Sponsored" with SF Symbol `megaphone.fill` at 11px. Clear, honest, compliant. User can still hide in Settings                                                                                                                                                                                                                                       |
| U13 | Inline upgrade banners on day headers and bookings screen risk the "Christmas tree" problem flagged in the UI Design Specification. The timeline is already the densest screen — adding upgrade prompts compounds visual noise                                                                     | **Medium**   | Upgrade prompts on the timeline appear ONLY in the collapsed suggestion indicator slot (same visual pattern as AI suggestions: dashed border, single line, 32px). Never as a separate banner competing with content. Maximum one upgrade-related element visible per screen                                                                                     |

---

## Revenue Philosophy

### The Golden Rule: Love First, Money Second

A user who never pays should still tell their friends about TripWeave. The free tier must be genuinely excellent — a complete trip organizer that people love. Premium is "more of what you already love," not "pay to unlock what we're hiding."

**The Canva Principle:** Canva gives away a powerful free product. Millions of free users become the marketing engine. 5-7% convert to Pro because they use it so much that the premium features feel like a natural upgrade, not a ransom. TripWeave follows this exact playbook.

### Five Monetization Rules

**1. Never gate the core organizational value.** Unlimited trips, full timeline, all bookings, map view — always free. A user planning one trip should never hit a wall on basic functionality.

**2. Gate the MAGIC, not the BASICS.** AI planning, beautiful sharing templates, unlimited email parsing, advanced exports — these are premium because they deliver premium value AND cost us money to run.

**3. Free users taste premium features.** Every premium feature has a free "taste" — 2 AI plans/month, 2 Trip Story templates, 5 email forwards/month. Users experience the magic before they're asked to pay. This is not a trial. It's permanent generosity with clear limits.

**4. Upgrade prompts are contextual, never nagging.** Show upgrade only when the user naturally hits a limit. Never interrupt trip planning with random popups. Never show a modal on app launch. The upgrade prompt appears at the moment the user wants more — that's when conversion happens.

**5. Every revenue stream must add user value.** Affiliate links help users find tours and flights. Sponsored placements surface relevant local businesses. B2B partnerships improve the product. Revenue that degrades user experience is rejected.

### Why Revenue Must Start at V2 (Not V3)

Waiting until V3 (months 2-4) for first revenue means 3+ months of pure cost with zero income. At the infrastructure costs documented in the cost analysis ($9-69/month), this is survivable but strategically wrong:

- **Signal to the market:** A product people pay for is a product with validated demand. Investor conversations change.

- **Feedback loop:** Paying users give better feedback than free users. They tell you what's worth money.

- **Sustainable AI costs:** V2b introduces AI features costing $34-380/month. Subscription revenue should offset this from day one.

- **Behavioral anchoring:** Users who adopt Pro early have higher LTV than users who are trained to expect everything free and then asked to pay later.

---

## Revenue Stream Overview — Nine Streams Across Five Versions

```
  V1 (Week 1-2):     $0 revenue. Build habit. Build love.
  │
  V2 (Week 6):        Stream 1: TripWeave Pro Subscription ←── STARTS HERE
  │                   Stream 2: Trip Stories Premium Packs
  │                   Stream 3: Tip Jar / Support the Dev
  │
  V3 (Month 3-4):    Stream 4: Affiliate Commissions (Viator, flights, hotels, cars)
  │                   Stream 5: Cheap Flight Alert Premium
  │
  V4 (Month 5-8):    Stream 6: In-App Booking Commissions
  │                   Stream 7: B2B / White-Label Licensing
  │
  V5 (Month 9-12):   Stream 8: Sponsored Placements
  │                   Stream 9: Travel Insurance Commissions
```

| Stream                | Version | Type           | Revenue Model         | Risk Level                 |
| --------------------- | ------- | -------------- | --------------------- | -------------------------- |
| TripWeave Pro         | V2      | Subscription   | $4.99/mo or $34.99/yr | Low — proven model         |
| Trip Stories Packs    | V2      | One-time IAP   | $1.99-3.99 per pack   | Low — no recurring cost    |
| Tip Jar               | V2      | One-time IAP   | $2.99-9.99            | Very Low — bonus revenue   |
| Affiliate Commissions | V3      | Commission     | 4-8% per booking      | Medium — partner dependent |
| Flight Alert Premium  | V3      | Feature upsell | Included in Pro       | Low — retention driver     |
| In-App Booking        | V4      | Commission     | 8-15% per booking     | High — complex integration |
| B2B Licensing         | V4      | License fee    | $99-499/mo per agency | Medium — sales-driven      |
| Sponsored Placements  | V5      | Advertising    | CPM / CPC             | Medium — needs scale       |
| Travel Insurance      | V5      | Commission     | 15-25% per policy     | Low — simple integration   |

---

## Stream 1: TripWeave Pro Subscription (V2)

### The Most Important Revenue Decision: Where to Draw the Line

The free/premium split determines everything — conversion rate, user satisfaction, virality, and long-term revenue. Get it wrong and either nobody pays (too generous free) or users leave (too restrictive free).

**The principle: Free = complete organizer. Pro = AI superpowers + premium sharing + unlimited automation.**

### Free Tier — Forever Free, Genuinely Excellent

The free tier is NOT a crippled demo. It's a fully functional trip planning app that competes with TripIt's free tier and beats most free travel apps.

| Category               | Free Tier                            | Limit Rationale                             |
| ---------------------- | ------------------------------------ | ------------------------------------------- |
| **Trips**              | Unlimited active + past trips        | Never limit core value                      |
| **Timeline**           | Full timeline with all features      | Never limit core value                      |
| **Manual Bookings**    | Unlimited manual entry               | Core organizational value                   |
| **Email Forwarding**   | 5 parsed bookings per month          | Enough for 1 trip. Costs us ~$0.003/parse   |
| **Map View**           | Full map with all features           | Core organizational value                   |
| **Places**             | Unlimited places on timeline         | Core organizational value                   |
| **Drag & Reorder**     | Full drag-and-drop                   | Core organizational value                   |
| **Ideas/Wishlist**     | Full wishlist                        | Core organizational value                   |
| **Trip Stories**       | 2 basic templates, with app branding | Preserves virality — shared cards market us |
| **AI Day Planner**     | 2 generations per month              | Taste the magic, want more                  |
| **Route Optimization** | 3 optimizations per month            | Taste the magic, want more                  |
| **Conflict Detection** | Always on (full)                     | Safety feature — never gated                |
| **Push Notifications** | All notifications                    | Retention feature — never gated             |
| **Dark Mode**          | Full dark mode                       | Basic feature — never gated                 |
| **Export**             | Plain text itinerary (copy/paste)    | Basic export, premium for polished formats  |
| **Profile / Settings** | Full settings                        | Never gated                                 |

**Why this is generous:** A solo traveler planning 1-2 trips per year gets real value from the free tier. They can organize their entire trip, forward 5 booking emails, generate 2 AI day plans, optimize 3 routes, and share 2 Trip Stories. They will love the app. And some of them will want more.

### TripWeave Pro — The Irresistible Upgrade

Pro unlocks three categories: **unlimited AI**, **premium sharing**, and **power tools**. These are features that (a) cost us money to run, (b) deliver clear incremental value, and (c) users have already tasted in the free tier.

| Category            | Pro Feature                                 | Why It's Worth Paying For                      |
| ------------------- | ------------------------------------------- | ---------------------------------------------- |
| **Unlimited AI**    | Unlimited AI Day Planner generations        | Free limit = 2/month. Pro = unlimited          |
|                     | AI Trip Generator (full trip in one tap)    | Pro-exclusive. Highest-value AI feature        |
|                     | Unlimited Route Optimization                | Free limit = 3/month. Pro = unlimited          |
|                     | Screenshot-to-Booking (GPT-4o vision)       | Pro-exclusive. Costs $0.007/scan to run        |
|                     | AI Travel Assistant Chat (V3 early access)  | Pro-exclusive. Context-aware travel chat       |
| **Premium Sharing** | 12+ premium Trip Story templates            | Free = 2 basic. Pro = full library             |
|                     | Option to hide "Made with TripWeave" credit | Default ON for all (virality). Pro can disable |
|                     | Custom accent colors on Trip Stories        | Personalization = premium                      |
|                     | Video Trip Story export (V2 late)           | Pro-exclusive animated stories                 |
|                     | High-resolution export (print quality)      | Pro-exclusive, useful for gifts/albums         |
| **Power Tools**     | Unlimited email forwarding + parsing        | Free = 5/month. Pro = unlimited                |
|                     | PDF itinerary export                        | Polished, printable PDF                        |
|                     | Calendar sync (.ics export)                 | Add to Apple/Google Calendar                   |
|                     | Trip analytics & spending insights          | Pro-exclusive analytics dashboard              |
|                     | Multi-language booking parsing              | Parse emails in 10+ languages                  |
|                     | Early access to new features                | Pro users get V3 features first                |

> **Review correction (U3):** "Priority AI Processing" removed from Pro features. If free users aren't artificially throttled, the feature is fake. If they are, it's a dark pattern — Apple HIG advises against features that create friction to upsell. Replaced with "AI Travel Assistant Chat" — genuinely exclusive value (context-aware trip chat, real API cost to justify gating).

> **Review correction (U6):** "Remove app branding" changed to "Option to hide credit." The Feature Roadmap states "Every shared card is a billboard." Removing branding from paying users — the most active sharers — eliminates the viral effect from power users. Instead: ALL users get a tasteful "Made with TripWeave" credit line (like "Shot on iPhone"). Pro users CAN disable it in Settings, but the default keeps it on, preserving virality across ALL user segments.

### Pricing Strategy

**Three tiers:**

| Plan     | Price           | Per Month | Savings                      | Target                                  |
| -------- | --------------- | --------- | ---------------------------- | --------------------------------------- |
| Monthly  | $4.99/month     | $4.99     | —                            | Try-before-committing users             |
| Annual   | $34.99/year     | $2.92     | Save 42%                     | Power users, frequent travelers         |
| Lifetime | $79.99 one-time | —         | Pays for itself in 16 months | Anti-subscription users, early adopters |

**Pricing rationale:**

- **$4.99/mo** is the "coffee price" — psychologically easy to justify. "Less than one coffee per month for unlimited AI trip planning."

- **$34.99/yr** is the anchor. The 42% savings badge drives annual conversion. Industry data shows 60-70% of subscribers choose annual when the savings are >35%.

- **$79.99 lifetime** captures the 10-15% of users who hate subscriptions on principle. At $79.99, it pays back in 16 months of monthly or 27 months of annual — good for power users, good for us (upfront cash).

**Competitive positioning:**

| Competitor    | Price       | Our Advantage                                                  |
| ------------- | ----------- | -------------------------------------------------------------- |
| TripIt Pro    | $49/year    | We're 29% cheaper with AI features TripIt doesn't have         |
| Wanderlog Pro | $40/year    | We're 13% cheaper with native iOS experience                   |
| Sygic Travel  | $14.99/year | We're premium-priced but deliver AI + sharing that Sygic lacks |

**Free trial:** 7-day Pro trial for new users who create their first trip. Activated automatically, no credit card required. StoreKit 2 handles trial management natively. Trial converts to annual by default (user chooses plan before trial ends).

### Paywall UX — Soft Walls, Not Hard Walls

**The Soft Wall Pattern:**

Users are never blocked from doing something. They hit a limit, see a friendly prompt, and decide whether to upgrade. The app never says "you can't do this." It says "you've used your free allowance — here's how to get more."

**Contextual Paywall Trigger Points:**

```
  User taps "✨ Plan My Day" for the 3rd time this month:
  ┌─────────────────────────────────┐
  │  ─── ───                    ✕   │  ← Standard sheet dismiss
  │                                 │     (drag down or ✕)
  │  You've planned 2 amazing       │  ← Lead with accomplishment
  │  days this month!               │     not quota consumed
  │                                 │
  │  Unlock unlimited AI planning,  │
  │  premium Trip Stories, and      │
  │  more with Pro.                 │
  │                                 │
  │  ┌─────────────────┐            │
  │  │ ○ Annual $34.99/yr           │  ← Segmented control
  │  │   $2.92/mo · Save 42%       │     Annual pre-selected
  │  │───────────────────           │
  │  │ ○ Monthly $4.99/mo           │
  │  └─────────────────┘            │
  │  More options ›                 │  ← Lifetime ($79.99)
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  Start 7-Day Free Trial   │  │  ← SINGLE primary CTA
  │  └───────────────────────────┘  │     Terracotta, full-width
  │  Then $34.99/year.              │
  │  Cancel anytime.               │
  │                                 │
  └─────────────────────────────────┘
  This prompt ONLY appears when the user hits the limit.
  It NEVER appears randomly, on app launch, or as a popup
  interrupting trip planning.
```

> **Review correction (U1):** Original showed trial CTA + 3 pricing tiers simultaneously (4 choices). Hick's Law: decision time increases logarithmically with options. Redesigned with single primary CTA ("Start Free Trial") and pricing as a segmented control (2 visible options). Lifetime moved to "More options" link to reduce cognitive load. **(U4):** "Not now" text removed — standard sheet dismiss (drag-down or ✕) is the iOS-native way to decline. A text link creates visual anchor on the negative action. **(U5):** Copy changed from "You've used 2 of 2 free AI plans" (transactional, anxiety-inducing) to "You've planned 2 amazing days this month!" (accomplishment-first, aspirational). **(U2):** All emoji in paywall replaced with SF Symbols for consistency with app design system (applied in full paywall screen below).

**Where upgrade prompts appear (and where they DON'T):**

| Trigger                            | Prompt Type                             | When                             |
| ---------------------------------- | --------------------------------------- | -------------------------------- |
| AI plan limit hit                  | Bottom sheet with feature comparison    | 3rd AI plan attempt in a month   |
| Email forward limit hit            | Inline banner on Bookings screen        | 6th email forward in a month     |
| Route optimization limit hit       | Inline banner on day header             | 4th optimization in a month      |
| Premium Trip Story template tapped | Bottom sheet with template preview      | Tap on locked template           |
| Export PDF/calendar tapped         | Bottom sheet with export preview        | Tap on locked export option      |
| Profile screen                     | Subtle "Upgrade to Pro" row in settings | Always visible, never aggressive |
| Trip completion celebration        | "Loved planning? Try Pro" card          | After marking trip complete      |

**Where upgrade prompts NEVER appear:**

- App launch / splash screen

- During active trip planning (adding places, editing bookings)

- As interstitial modals between screens

- As persistent banners covering content

- More than once per session for the same feature

> **Review correction (U13):** Upgrade prompts on the Trip Detail timeline use the same visual pattern as AI suggestion indicators (dashed border, single line, 32px height) — never as separate banners competing with timeline content. The UI Design Specification warns about the "Christmas tree" problem on the timeline. Maximum one upgrade-related element visible per screen at any time.

**Paywall Screen (Full — accessed from Settings or "See all Pro features"):**

```
  ┌─────────────────────────────────┐
  │  [✕]     TripWeave Pro          │
  ├─────────────────────────────────┤
  │                                 │
  │  Plan smarter. Share            │  ← 24px SemiBold, SF Pro Rounded
  │  beautifully.                   │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ ✦ Unlimited AI Planning   │  │  ← SF Symbol: sparkles
  │  │ ✦ 12+ Premium Templates  │  │     SF Symbol: paintbrush.fill
  │  │ ✦ Unlimited Email Parsing│  │     SF Symbol: envelope.fill
  │  │ ✦ Unlimited Route Opt.   │  │     SF Symbol: arrow.triangle.2.circlepath
  │  │ ✦ PDF & Calendar Export  │  │     SF Symbol: doc.fill
  │  │ ✦ Screenshot-to-Booking  │  │     SF Symbol: camera.viewfinder
  │  │ ✦ Trip Analytics         │  │     SF Symbol: `chart.bar.fill`
  │  │ ✦ AI Travel Chat         │  │     SF Symbol: bubble.left.fill
  │  │ ✦ Early Access Features  │  │     SF Symbol: gift.fill
  │  └───────────────────────────┘  │     All icons: terracotta, 15px
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │ ◉ Annual       BEST VALUE│  │  ← Segmented control
  │  │   $34.99/year             │  │     Annual pre-selected
  │  │   $2.92/mo · Save 42%    │  │
  │  │───────────────────────────│  │
  │  │ ○ Monthly                 │  │
  │  │   $4.99/month             │  │
  │  └───────────────────────────┘  │
  │  More options ›                 │  ← Tap → reveals Lifetime
  │                                 │     $79.99 one-time
  │  ┌───────────────────────────┐  │
  │  │  Start 7-Day Free Trial  │  │  ← SINGLE terracotta CTA
  │  └───────────────────────────┘  │
  │  Then $34.99/year.              │  ← Clear post-trial pricing
  │  Cancel anytime.               │
  │                                 │
  │  Restore Purchases              │  ← Required by App Store
  │  Terms · Privacy                │
  └─────────────────────────────────┘
```

> **Review correction (U2):** All emoji icons replaced with SF Symbols for consistency with the app's SF Pro Rounded + SF Symbols design system. Emoji render differently across iOS versions and feel informal in a premium paywall context. **(U1):** Lifetime plan moved behind "More options" to reduce choices from 4 to 2 + a clear CTA. Research shows reducing options improves conversion 20-30%. **(U4):** No "Not now" text — standard sheet dismiss handles declination.

---

## Stream 2: Trip Stories Premium Packs (V2)

One-time in-app purchases for themed Trip Story template collections. These are non-subscription purchases for users who want specific aesthetics but don't want a full Pro subscription.

**Available Packs:**

| Pack Name             | Templates    | Price | Theme                                   |
| --------------------- | ------------ | ----- | --------------------------------------- |
| Wanderlust Collection | 4 templates  | $0.99 | Bohemian, warm tones, handwritten feel  |
| Minimalist Collection | 4 templates  | $0.99 | Clean, Swiss design, black & white      |
| Tropical Vibes        | 4 templates  | $0.99 | Bold colors, palm motifs, summer energy |
| Winter Wonderland     | 4 templates  | $0.99 | Cool blues, snow textures, cozy feel    |
| All Packs Bundle      | 16 templates | $2.99 | Save 25% vs individual                  |

> **Review correction (U7):** Packs repriced from $1.99 to $0.99. At $1.99, users rationally compare to Pro ($4.99/mo for EVERYTHING) and the pack becomes a bad deal. At $0.99, it's impulse-buy territory — the "sticker pack" model. Users buy without overthinking the Pro comparison. Higher volume compensates for lower unit price.

**Pro subscribers get ALL packs included.** This makes Pro feel even more valuable. Template packs are for users who want one specific aesthetic without committing to a subscription.

**Revenue potential:** Small but meaningful — typically 3-8% of users buy $0.99 impulse packs (higher rate than $1.99). At 10K DAU (30K MAU): ~900-2,400 purchases × $0.99-2.99 = $900-7,200 one-time over the lifetime of those users.

---

## Stream 3: Supporter Badges (V2)

> **Review correction (U8):** Original "Tip Jar" with pure donation IAPs violates App Store Review Guideline 3.1.1 — Apple rejects purchases that provide no content or functionality. "Buy me a coffee" with zero deliverable has been consistently rejected. Redesigned as "Supporter Badge" system where each purchase unlocks a permanent profile badge + animation. This provides tangible value (social recognition) while capturing the same goodwill revenue.

A "Support TripWeave" section in Profile/Settings. Each purchase unlocks a permanent badge on the user's profile and a celebration animation.

| Tier             | Price | What User Gets                                          |
| ---------------- | ----- | ------------------------------------------------------- |
| Coffee Supporter | $2.99 | ☕ Bronze badge on profile + thank-you confetti          |
| Meal Supporter   | $5.99 | 🍕 Silver badge + confetti + name in Supporters section |
| Flight Supporter | $9.99 | ✈️ Gold badge + confetti + name + exclusive app icon    |

**App Store compliance:** Each tier delivers a non-consumable digital good (permanent badge + optional exclusive app icon). Satisfies Guideline 3.1.1.

**Why this works:** Solo/indie dev narrative is powerful. "Built by a traveler frustrated with 10 apps for one trip." The badge makes support visible — social signaling drives more purchases than anonymous tips.

**Revenue potential:** 1-3% of engaged free users buy badges. Small but purely additive. Typical: $50-200/month at 1K DAU.

---

## Stream 4: Affiliate Commissions (V3)

### Integration Architecture

Each affiliate partner provides commission for bookings made through TripWeave. The UX integrates naturally into the trip planning workflow — not as ads, but as helpful discovery tools.

| Partner      | Category           | Commission Rate  | Integration Type                | Lead Time |
| ------------ | ------------------ | ---------------- | ------------------------------- | --------- |
| Viator       | Tours & activities | 8%               | Affiliate link → In-app webview | 2-4 weeks |
| Kiwi Tequila | Flights            | 2-4% + fixed fee | Affiliate link                  | 1-2 weeks |
| [Booking.com](https://www.booking.com)  | Hotels             | 4-6%             | Affiliate link                  | 2-3 weeks |
| CarTrawler   | Car rentals        | 5-8%             | Affiliate link                  | 2-4 weeks |
| GetYourGuide | Tours (backup)     | 8%               | Affiliate link                  | 1-2 weeks |

### How Affiliate Links Surface (Never as Ads)

Affiliate links appear at **contextual moments** when the user is naturally looking for bookings:

**1. "Explore" Section on Timeline (V3)**

When a user is browsing a day with places but no tours booked:

```
  │  2:00 PM  Eiffel Tower
  │
  │  ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  │  ╎  🎟️ Popular near Eiffel Tower  ╎   ← Contextual, not random
  │  ╎                                ╎
  │  ╎  Seine River Cruise  $29  [→]  ╎   ← Viator affiliate link
  │  ╎  Skip-the-Line       $42  [→]  ╎
  │  ╎                                ╎
  │  ╎  Powered by Viator             ╎   ← Transparent attribution
  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```

**2. "Book" Button on Place Detail Sheet**

When user taps a place card, the detail sheet can show a booking option:

```
  ┌─────────────────────────────────┐
  │  ⭐ Eiffel Tower                │
  │  ...                            │
  │                                 │
  │  🎟️ BOOK TOURS & TICKETS       │  ← Section, not an ad
  │  ┌───────────────────────────┐  │
  │  │ Skip the Line · $42      │  │  ← Viator link
  │  │ ⭐ 4.8 · 12,000 reviews  │  │
  │  │               [Book →]   │  │
  │  └───────────────────────────┘  │
  │                                 │
  └─────────────────────────────────┘
```

**3. Flight & Hotel Search on Bookings Screen**

```
  ┌─────────────────────────────────┐
  │  NEED A BOOKING?                │
  │                                 │
  │  ✈️ Search Flights  [→]         │  ← Kiwi affiliate
  │  🏨 Search Hotels   [→]         │  ← [Booking.com](https://www.booking.com) affiliate
  │  🚗 Search Car Rentals [→]      │  ← CarTrawler affiliate
  │                                 │
  └─────────────────────────────────┘
```

**4. Cheap Flight Alerts (V3 — Pro Feature)**

Cheap flight alerts are a Pro-only feature that drives both retention AND affiliate revenue:

- User sets a route to watch (Paris → Tokyo)

- Backend polls Kiwi Tequila API daily

- Push notification on price drop: "Paris → Tokyo dropped to $342!"

- "Book Now" CTA is an affiliate link

This is a double win: users love the alerts (retention), and every booking earns commission (revenue).

### Affiliate Revenue Projections

| DAU    | MAU     | % Who Browse Affiliates | Bookings/Month   | Avg Commission | Monthly Revenue |
| ------ | ------- | ----------------------- | ---------------- | -------------- | --------------- |
| 1,000  | 3,000   | 15% (450 users)         | 90 (20% convert) | $8             | **$720**        |
| 5,000  | 15,000  | 15% (2,250)             | 450              | $8             | **$3,600**      |
| 10,000 | 30,000  | 15% (4,500)             | 900              | $8             | **$7,200**      |
| 50,000 | 150,000 | 15% (22,500)            | 4,500            | $8             | **$36,000**     |

**Conservative assumptions:** 15% of MAU browse affiliate content, 20% of browsers convert to a booking. Average commission of $8 accounts for mix of tours ($3-5), flights ($10-20), and hotels ($15-30).

---

## Stream 5: Cheap Flight Alert Premium (V3)

Cheap flight alerts are included in TripWeave Pro but also offered as a standalone $1.99/month add-on for free users who only want alerts without the full Pro suite.

| Plan               | Price       | What's Included                            |
| ------------------ | ----------- | ------------------------------------------ |
| Free               | $0          | No flight alerts                           |
| Flight Alerts Only | $1.99/month | 3 route watches, daily price checks        |
| TripWeave Pro      | $4.99/month | Unlimited route watches + all Pro features |

This captures users who aren't ready for full Pro but are willing to pay for flight deal notifications. It also serves as a funnel — flight alert users who later start planning trips upgrade to Pro.

---

## Stream 6: In-App Booking Commissions (V4)

V3 uses affiliate links (user leaves app → books on partner site → we get commission). V4 upgrades to in-app booking where the user completes the entire transaction without leaving TripWeave. This earns higher commission rates because we handle more of the funnel.

| Category             | V3 Affiliate Rate | V4 In-App Rate             | Revenue Increase |
| -------------------- | ----------------- | -------------------------- | ---------------- |
| Tours (Viator)       | 8%                | 10-12% (certified partner) | +50%             |
| Flights (Kiwi)       | 2-4%              | 5-7% (ticketing partner)   | +75%             |
| Hotels ([Booking.com](https://www.booking.com)) | 4-6%              | 8-10% (premier partner)    | +67%             |
| Car Rentals          | 5-8%              | 10-12%                     | +50%             |

**Why the rate increases:** Partners pay more when the app handles the full booking flow because conversion rates are higher (no app-switching friction) and partner customer acquisition costs drop.

**Additional V4 revenue:** Auto-add booked items to timeline — this is a UX feature that also increases booking conversion (users see the value immediately).

---

## Stream 7: B2B / White-Label Licensing (V4)

Travel agencies, corporate travel departments, and boutique hotels can license TripWeave's planning engine for their clients.

| Tier         | Price       | What's Included                                          | Target                         |
| ------------ | ----------- | -------------------------------------------------------- | ------------------------------ |
| Starter      | $99/month   | Branded trip links for up to 50 clients/month            | Small travel agencies          |
| Professional | $299/month  | White-label web view, custom branding, 500 clients/month | Medium agencies                |
| Enterprise   | $499+/month | Full API access, custom integrations, unlimited clients  | Corporate travel, hotel chains |

**Use case:** A boutique travel agency creates itineraries for their clients using TripWeave's engine. The client receives a branded trip link (agency's logo, not TripWeave's) with the full interactive timeline. The agency saves hours of manual itinerary creation.

**Revenue potential:** 5-20 agency clients at $99-499/month = $500-10,000/month additional revenue with near-zero marginal cost (same infrastructure serves B2B and B2C).

---

## Stream 8: Sponsored Placements (V5)

At scale (50K+ DAU), restaurants, hotels, and activity providers pay to be surfaced in relevant contexts. This is NOT banner advertising. It's contextual, relevant placement that adds value.

**Format: "Featured" badge on search results and nearby suggestions**

```
  Search: "coffee near Le Marais"
  ┌───────────────────────────┐
  │ ☕ Café Oberkampf    ⭐ FEATURED │  ← Sponsored (clearly labeled)
  │   "Best specialty coffee"        │     Paid by the café
  │   📍 3 min walk              [+] │
  ├───────────────────────────────────┤
  │ ☕ Boot Café                      │  ← Organic result
  │   📍 5 min walk              [+] │
  └───────────────────────────────────┘
```

**Rules:**

> **Review correction (U12):** "FEATURED" relabeled to "Sponsored." Apple's advertising transparency guidelines require clear identification. "Featured" implies editorial curation, which is misleading for paid placement.

- Maximum 1 sponsored result per search query

- Always labeled **"Sponsored"** with SF Symbol `megaphone.fill` at 11px (clear, honest, compliant)

- Only shown when genuinely relevant (same category, same area)

- Never displaces the top organic result — sponsored appears as position 2 or in a separate section

- User can hide sponsored results in Settings

**Pricing model:** CPC (cost-per-click) at $0.50-2.00 per tap, or CPM at $5-15. Self-serve dashboard for local businesses in top destinations.

**Revenue potential at 50K DAU:** 150K monthly search queries × 10% show sponsored × 2% CTR × $1.00 CPC = **$3,000/month**. Grows linearly with user base and destination coverage.

---

## Stream 9: Travel Insurance Commissions (V5)

Partner with travel insurance providers (World Nomads, Allianz, SafetyWing) to offer insurance.

> **Review correction (U9):** Original placed insurance card inside the Create Trip flow. This violates Rule #4 ("Never interrupt trip planning") and the UI spec's "Only 2 inputs" principle. Commercial element at a moment of excitement adds friction and reduces trip creation completion. Moved to Trip Detail screen — inline card below pills row (same pattern as email forwarding discovery), appearing 24-48 hours after trip creation.

```
  Trip Detail screen (24-48 hours after trip creation):
  ┌──────┐ ┌──────┐ ┌──────┐        ← Pills row
  │🗺️ Map│ │✈️  4 │ │📎  2 │
  └──────┘ └──────┘ └──────┘
  ┌───────────────────────────────┐   ← Insurance suggestion
  │  🛡️ Protect your trip?    ✕   │      Primary Light bg (#F4E8E0)
  │                               │      Same visual pattern as
  │  Travel insurance from $29    │      email forwarding banner
  │  Trip cancellation, medical   │
  │  emergencies, lost luggage    │      Dismissible (per-trip)
  │          [Learn More →]       │      "Don't show again" checkbox
  └───────────────────────────────┘
  ── Day 1 — Sat, Apr 2 ─────        ← Timeline starts below
```

**Timing:** Appears 24-48 hours after trip creation, not during. User has had time to add places and bookings — the trip feels real, making insurance relevant. Never shows during an active trip (departure date past).

**Commission:** 15-25% of policy premium. Average policy: $40-80. Commission per sale: $6-20.

**Revenue potential at 10K DAU:** 5% conversion on trip creation × 30K trips/year × $10 avg commission = **$15,000/year** ($1,250/month).

---

## Complete Revenue Projections

### Revenue by Stream at Each Scale

**1,000 DAU (~3K MAU)**

| Stream                        | Monthly Revenue  | Notes                       |
| ----------------------------- | ---------------- | --------------------------- |
| TripWeave Pro (5% conversion) | $500-700         | 150 subs × avg $4.00/mo     |
| Trip Stories Packs            | $30-50           | One-time, amortized monthly |
| Tip Jar                       | $20-40           | 1% of free users            |
| **V2 Total**                  | **$550-790**     |                             |
| Affiliate Commissions (V3)    | $720             | 90 bookings × $8 avg        |
| Flight Alert Add-on (V3)      | $60-100          | 30-50 standalone subs       |
| **V3 Total**                  | **$1,330-1,610** |                             |

**10,000 DAU (~30K MAU)**

| Stream                        | Monthly Revenue    | Notes                                    |
| ----------------------------- | ------------------ | ---------------------------------------- |
| TripWeave Pro (6% conversion) | $5,200-6,500       | 1,800 subs × avg $3.50/mo (annual-heavy) |
| Trip Stories Packs            | $200-400           | Amortized monthly                        |
| Tip Jar                       | $100-200           |                                          |
| **V2 Total**                  | **$5,500-7,100**   |                                          |
| Affiliate Commissions (V3)    | $7,200             | 900 bookings × $8 avg                    |
| Flight Alert Add-on (V3)      | $400-600           | 200-300 standalone subs                  |
| **V3 Total**                  | **$13,100-14,900** |                                          |
| In-App Booking uplift (V4)    | +$3,600            | 50% higher rates on same volume          |
| B2B Licensing (V4)            | $1,000-5,000       | 5-15 agency clients                      |
| **V4 Total**                  | **$17,700-23,500** |                                          |

**50,000 DAU (~150K MAU)**

| Stream                        | Monthly Revenue     | Notes               |
| ----------------------------- | ------------------- | ------------------- |
| TripWeave Pro (7% conversion) | $30,000-37,000      | 10,500 subs         |
| Trip Stories Packs            | $500-1,000          |                     |
| Tip Jar                       | $300-500            |                     |
| Affiliate Commissions         | $36,000             | 4,500 bookings × $8 |
| Flight Alert Add-on           | $2,000-3,000        |                     |
| In-App Booking uplift         | $18,000             |                     |
| B2B Licensing                 | $5,000-15,000       |                     |
| Sponsored Placements          | $3,000-5,000        |                     |
| Travel Insurance              | $4,000-6,000        |                     |
| **Total**                     | **$98,800-105,500** |                     |

### Revenue vs. Cost Analysis

| Scale        | Monthly Revenue | Monthly Cost (from infra plan)  | Net Profit     | Margin |
| ------------ | --------------- | ------------------------------- | -------------- | ------ |
| 100 DAU (V2) | $50-80          | $14 (infra) + $0 (AI)           | $36-66         | 72-83% |
| 1K DAU (V2)  | $550-790        | $69 (infra) + $34 (AI) = $103   | $447-687       | 81-87% |
| 1K DAU (V3)  | $1,330-1,610    | $103                            | $1,227-1,507   | 92-94% |
| 10K DAU (V3) | $13,100-14,900  | $392 (infra) + $380 (AI) = $772 | $12,328-14,128 | 94-95% |
| 10K DAU (V4) | $17,700-23,500  | $872                            | $16,828-22,628 | 95-96% |

**The business becomes self-sustaining at ~300-400 DAU** (V2 subscription revenue exceeds infrastructure + AI costs). By 1K DAU with V3 affiliate revenue, margins exceed 90%.

---

## Break-Even Analysis

| Milestone                       | When                | DAU Required            | Revenue to Cover Costs |
| ------------------------------- | ------------------- | ----------------------- | ---------------------- |
| Infrastructure break-even       | V2 launch + 2 weeks | ~100 DAU (3-5 Pro subs) | $14/month              |
| AI costs break-even             | V2b launch          | ~300 DAU (15 Pro subs)  | $103/month             |
| Developer salary ($5K/mo)       | V3 launch + 4 weeks | ~3,000 DAU              | $5,100/month           |
| Full-time sustainable ($10K/mo) | V3 + 3 months       | ~6,000 DAU              | $10,000/month          |

---

## Technical Implementation — StoreKit 2

### Product Configuration

> **Review correction (E1):** Original mixed subscriptions, non-consumables, and consumables in one enum. StoreKit 2 treats these fundamentally differently — auto-renewable subscriptions live in subscription groups, non-consumables (lifetime, badges, template packs) are separate product types, and consumables (if any) are yet another type. Split into proper types with correct App Store Connect configuration.

```swift
// Models/StoreProducts.swift
// SUBSCRIPTION GROUP: "TripWeave Pro" (Monthly + Annual in same group)
// StoreKit auto-manages upgrades/downgrades within a group
enum ProSubscription: String, CaseIterable {
    case monthly = "tripweave_pro_monthly"       // Auto-renewable
    case annual = "tripweave_pro_annual"          // Auto-renewable
}
// SEPARATE SUBSCRIPTION GROUP: "Flight Alerts" (independent of Pro)
enum AlertSubscription: String {
    case monthly = "tripweave_flight_alerts_monthly"
}
// NON-CONSUMABLE purchases (permanent, one-time)
enum NonConsumablePurchase: String, CaseIterable {
    case proLifetime = "tripweave_pro_lifetime"   // NOT a subscription
    case packWanderlust = "tripweave_pack_wanderlust"
    case packMinimalist = "tripweave_pack_minimalist"
    case packTropical = "tripweave_pack_tropical"
    case packWinter = "tripweave_pack_winter"
    case packBundle = "tripweave_pack_all"
    case badgeCoffee = "tripweave_badge_coffee"
    case badgeMeal = "tripweave_badge_meal"
    case badgeFlight = "tripweave_badge_flight"
}
```

> **Why this matters:** Monthly + Annual MUST be in one subscription group — StoreKit 2 automatically handles upgrade/downgrade/crossgrade within a group. Lifetime is a non-consumable (not auto-renewable) — it CANNOT be in a subscription group. Flight Alerts is a SEPARATE subscription group because it's independent of Pro (users can have one without the other). Mixing these in one enum causes incorrect App Store Connect configuration and potential App Review rejection.

### Entitlement Manager

> **Review correction (E2, E3, E8, E9):** Original `checkEntitlements()` only read `Transaction.currentEntitlements` once — missing `Transaction.updates` listener for real-time changes (renewals, revocations, family sharing). Added transaction update monitoring, server-side JWS validation, and proper `Transaction.finish()` calls. Removed custom grace period (Apple handles natively). Family Sharing explicitly disabled (justified: per-user AI cost).

```swift
// Services/EntitlementManager.swift
import StoreKit
@Observable
final class EntitlementManager {
    private(set) var isProUser = false
    private(set) var hasFlightAlerts = false
    private(set) var ownedPurchases: Set<String> = []
    private var updateListenerTask: Task<Void, Error>?
    static let freeAIPlansPerMonth = 2
    static let freeRouteOptPerMonth = 3
    static let freeEmailForwardsPerMonth = 5
    static let freeTemplateCount = 2
    // Call on app launch
    func start() async {
        await loadCurrentEntitlements()
        listenForTransactionUpdates()
    }
    // One-shot load of all current entitlements (works offline)
    private func loadCurrentEntitlements() async {
        var proPurchased = false
        var alertsPurchased = false
        var purchases = Set<String>()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            if ProSubscription.allCases.map(\.rawValue).contains(tx.productID)
                || tx.productID == NonConsumablePurchase.proLifetime.rawValue {
                proPurchased = true
            } else if tx.productID == AlertSubscription.monthly.rawValue {
                alertsPurchased = true
            } else if tx.productID.hasPrefix("tripweave_pack_")
                        || tx.productID.hasPrefix("tripweave_badge_") {
                purchases.insert(tx.productID)
            }
        }
        isProUser = proPurchased
        hasFlightAlerts = alertsPurchased
        ownedPurchases = purchases
    }
    // Continuous listener for renewals, revocations, family sharing changes
    private func listenForTransactionUpdates() {
        updateListenerTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let tx) = result else { continue }
                await tx.finish()
                await self?.loadCurrentEntitlements()
                await self?.syncEntitlementToServer(tx)
            }
        }
    }
    // Server-side validation: send JWS to Edge Function
    // Edge Functions check this before executing AI calls
    private func syncEntitlementToServer(_ transaction: Transaction) async {
        guard let jwsRepresentation = transaction.jwsRepresentation else { return }
        try? await SupabaseManager.shared.client.functions.invoke(
            "validate-subscription",
            options: .init(body: ["jws": jwsRepresentation])
        )
    }
    // Usage checks — optimistic on client, enforced on server
    func canUseAIDayPlanner(usedThisMonth: Int) -> Bool {
        isProUser || usedThisMonth < Self.freeAIPlansPerMonth
    }
    func canUseRouteOptimization(usedThisMonth: Int) -> Bool {
        isProUser || usedThisMonth < Self.freeRouteOptPerMonth
    }
    func canForwardEmail(usedThisMonth: Int) -> Bool {
        isProUser || usedThisMonth < Self.freeEmailForwardsPerMonth
    }
    func canUseAITripGenerator() -> Bool { isProUser }
    func canUseScreenshotParser() -> Bool { isProUser }
    func canExportPDF() -> Bool { isProUser }
    func canExportCalendar() -> Bool { isProUser }
    func availableTemplateCount() -> Int {
        let packCount = ownedPurchases.filter { $0.hasPrefix("tripweave_pack_") }.count
        return isProUser ? .max : Self.freeTemplateCount + packCount * 4
    }
    // Credit is shown by default for ALL users. Pro users can disable in Settings.
    func showsAppCredit(userDisabledCredit: Bool) -> Bool {
        if isProUser && userDisabledCredit { return false }
        return true
    }
    deinit { updateListenerTask?.cancel() }
}
```

> **Family Sharing (E9):** Explicitly disabled in App Store Connect for Pro subscription. Justification: AI features incur per-user costs ($0.03-0.17 per generation). Family Sharing would allow 6 users at the cost of 1, making the unit economics unsustainable at scale. Document this rationale in App Review notes.

### Feature Gating Pattern in Views

```swift
// Example: AI Day Planner button
struct DaySectionHeaderView: View {
    @Environment(EntitlementManager.self) var entitlements
    @State private var showPaywall = false
    var body: some View {
        Button {
            if entitlements.canUseAIDayPlanner() {
                openAIDayPlanner()
            } else {
                showPaywall = true
            }
        } label: {
            Label("Plan", systemImage: "sparkles")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(feature: .aiDayPlanner, context: .limitReached(
                used: EntitlementManager.freeAIPlansPerMonth,
                limit: EntitlementManager.freeAIPlansPerMonth
            ))
        }
    }
}
```

### Usage Tracking — Event-Sourced (Server-Side Enforced)

> **Review correction (E4, E7):** Original used a mutable counter table reset by a monthly cron job. Three problems: (1) UserDefaults is trivially manipulable (delete app data, reset device date), (2) cron is a single point of failure — if Supabase has downtime on the 1st, users don't get their reset, (3) race condition at month boundary. Replaced with event-sourced counting: log each usage event as an immutable row, count dynamically. No mutable state, no cron, no race conditions, server-side enforcement.

```sql
-- Immutable event log — append-only, never updated or deleted
create table public.usage_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  feature text not null,         -- 'ai_day_planner', 'route_optimization', 'email_forward'
  created_at timestamptz not null default now()
);
create index idx_usage_user_feature_month
  on public.usage_events(user_id, feature, created_at);
alter table public.usage_events enable row level security;
create policy "Users insert own usage events"
  on public.usage_events for insert
  with check (auth.uid() = user_id);
create policy "Users read own usage events"
  on public.usage_events for select
  using (auth.uid() = user_id);
```

**Server-side enforcement in Edge Functions (critical for AI calls):**

```typescript
// supabase/functions/ai-plan-day/index.ts
// Before executing the AI call, check usage + subscription
const { data: subscription } = await supabase
  .from('user_subscriptions')
  .select('is_pro')
  .eq('user_id', userId)
  .single();
if (!subscription?.is_pro) {
  const { count } = await supabase
    .from('usage_events')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('feature', 'ai_day_planner')
    .gte('created_at', startOfMonth());
  if (count >= 2) {
    return new Response(
      JSON.stringify({ error: 'free_limit_reached', limit: 2, used: count }),
      { status: 429 }
    );
  }
}
// Log usage event BEFORE executing (prevents double-spend on retry)
await supabase.from('usage_events').insert({
  user_id: userId,
  feature: 'ai_day_planner'
});
// Now execute the AI call...
```

**Client-side optimistic check (for UI gating — not the source of truth):**

```swift
// ViewModels/UsageViewModel.swift
@Observable
final class UsageViewModel {
    private(set) var aiPlansUsedThisMonth = 0
    private(set) var routeOptsUsedThisMonth = 0
    private(set) var emailForwardsUsedThisMonth = 0
    func loadUsage() async {
        let startOfMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())
        )!
        for feature in ["ai_day_planner", "route_optimization", "email_forward"] {
            let count = try? await SupabaseManager.shared.client
                .from("usage_events")
                .select("*", head: true, count: .exact)
                .eq("user_id", userId)
                .eq("feature", feature)
                .gte("created_at", startOfMonth.ISO8601Format())
                .execute()
                .count
            switch feature {
            case "ai_day_planner": aiPlansUsedThisMonth = count ?? 0
            case "route_optimization": routeOptsUsedThisMonth = count ?? 0
            case "email_forward": emailForwardsUsedThisMonth = count ?? 0
            default: break
            }
        }
    }
}
```

> **Why event-sourced is better:** No cron jobs, no mutable state, no race conditions. "How many AI plans did user X use this month?" is always a simple COUNT query with a date filter. Monthly "reset" happens automatically — events from previous months simply don't match the current month's date range. The event log also provides free analytics: usage patterns, peak times, feature adoption — all from the same table.

### Affiliate Tracking Service (V3)

```swift
// Services/AffiliateTrackingService.swift
import Foundation
@Observable
final class AffiliateTrackingService {
    // Review correction (E5): Returns optional URL instead of force-unwrapping.
    // Destination is URL-encoded to handle Japanese, Arabic, special chars.
    func generateAffiliateURL(partner: AffiliatePartner, destination: String, context: AffiliateContext) -> URL? {
        guard var components = URLComponents(string: partner.baseURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: partner.affiliateIDParam, value: partner.affiliateID),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "utm_source", value: "tripweave"),
            URLQueryItem(name: "utm_medium", value: context.rawValue),
            URLQueryItem(name: "utm_campaign", value: "in_app_\(context.rawValue)")
        ]
        return components.url
    }
    func trackAffiliateClick(partner: AffiliatePartner, context: AffiliateContext, tripID: UUID) async {
        // Log to Supabase for attribution tracking
        try? await supabase.from("affiliate_clicks")
            .insert([
                "partner": partner.rawValue,
                "context": context.rawValue,
                "trip_id": tripID.uuidString,
                "clicked_at": ISO8601DateFormatter().string(from: Date())
            ])
            .execute()
        // PostHog event
        PostHog.shared.capture("affiliate_click", properties: [
            "partner": partner.rawValue,
            "context": context.rawValue
        ])
    }
}
enum AffiliatePartner: String {
    case viator, kiwiFlights = "kiwi", bookingHotels = "booking", carTrawler
    var baseURL: String { /* partner URLs */ }
    var affiliateIDParam: String { /* partner-specific param name */ }
    var affiliateID: String { /* our affiliate ID */ }
}
enum AffiliateContext: String {
    case timelineSuggestion = "timeline"
    case placeDetail = "place_detail"
    case bookingsScreen = "bookings"
    case flightAlert = "flight_alert"
    case searchResult = "search"
}
```

### Server-Side Subscription Validation Table

> **Review correction (E3):** All entitlement checking was on-device only. Jailbroken devices bypass all gates. Edge Functions couldn't verify Pro status before executing expensive AI calls. Added server-side subscription table populated by JWS validation Edge Function.

```sql
-- Populated by validate-subscription Edge Function
-- Edge Functions check this table before executing AI calls
create table public.user_subscriptions (
  user_id uuid primary key references auth.users(id),
  is_pro boolean not null default false,
  product_id text,
  original_transaction_id text,
  expires_at timestamptz,
  is_in_billing_retry boolean default false,
  validated_at timestamptz default now()
);
alter table public.user_subscriptions enable row level security;
create policy "Users read own subscription"
  on public.user_subscriptions for select
  using (auth.uid() = user_id);
-- Only service_role (Edge Functions) can write
```

### Affiliate Tracking Tables

```sql
create table public.affiliate_clicks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id),
  partner text not null,
  context text not null,
  trip_id uuid references trips(id),
  clicked_at timestamptz default now(),
  converted boolean default false,
  commission_usd numeric
);
-- Review correction (E6): Indices for query performance at scale
create index idx_affiliate_clicks_user on public.affiliate_clicks(user_id, clicked_at);
create index idx_affiliate_clicks_trip on public.affiliate_clicks(trip_id);
create index idx_affiliate_clicks_partner on public.affiliate_clicks(partner, clicked_at);
create table public.affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  partner text not null,
  click_id uuid references affiliate_clicks(id),
  booking_reference text,
  booking_amount_usd numeric,
  commission_usd numeric not null,
  status text default 'pending',
  reported_at timestamptz default now()
);
create index idx_affiliate_commissions_status on public.affiliate_commissions(status);
```

---

## Anti-Churn Strategy

### Why Users Cancel (and How to Prevent It)

| Cancellation Reason                       | Prevention Strategy                                                                                         |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| "I'm between trips, don't need it"        | Annual plan default. Trip completion celebration shows value summary.                                       |
| "It's too expensive"                      | Annual pricing = $2.92/mo. Lifetime option = $79.99. Flight alert standalone = $1.99/mo.                    |
| "I don't use the premium features enough" | Monthly Pro usage summary email: "You used AI planning 8 times, shared 5 Trip Stories, parsed 12 bookings." |
| "I found a free alternative"              | Free tier is already competitive. Differentiators (AI + Trip Stories) have no free equivalent.              |
| "The app isn't updated enough"            | Pro users get early access to new features. Changelog in-app.                                               |

### Churn Prevention Touchpoints

**1. Win-Back Offer (in-app only, NOT push notification):**

> **Review correction (U10):** Original used push notification "We miss you!" — this feels promotional and needy. Apple's push guidelines discourage purely promotional pushes. Users who cancelled consciously may uninstall. Changed to in-app offer only.

When a lapsed subscriber opens the app, show a gentle inline card on the Trips List (not a modal): "Welcome back! Pro is available at 50% off this month." Uses StoreKit 2's `Product.SubscriptionOffer` for promotional pricing. The card appears once, dismisses on tap or after 3 app opens.

**2. Downgrade Grace Period:**

> **Review correction (E8):** Original added a custom 3-day grace period. StoreKit 2 already handles billing grace period natively via `Product.SubscriptionInfo.RenewalInfo`. Adding a custom grace creates double grace periods and incorrect entitlement states. Removed custom grace — rely on Apple's built-in billing retry.

When Pro expires (after Apple confirms non-renewal), transition gracefully: Pro features become view-only (existing Trip Stories visible but can't create new premium ones), AI plan count resets to free tier limits. No jarring "everything is gone" moment — user keeps their data, just can't create new premium content.

**3. Value Summary in Settings (NOT proactive renewal reminder):**

> **Review correction (U11):** Original showed a 30-day renewal reminder in-app. Research (Recurly 2023, Baremetrics data) shows proactive renewal reminders INCREASE cancellation rates 15-25% — users who weren't considering cancelling are prompted to reconsider. Removed proactive reminder. Apple already sends system renewal emails.

Value summary shows ONLY when user navigates to Settings → Subscription (they're already thinking about it). "This year with Pro: 47 AI plans, 23 Trip Stories, 89 parsed bookings. Your subscription renews [date]." Reinforces value at the moment of decision, not before.

**4. Cancellation Survey:**

When user cancels via App Store, the next app open shows a quick 1-question survey: "What would make you stay?" with 4 options. Feed responses into product decisions. Presented as a non-blocking inline card, not a modal.

### Subscription Metrics & KPIs

| Metric                         | Target (V2 Month 1) | Target (V2 Month 6) | Target (V3 Month 12) |
| ------------------------------ | ------------------- | ------------------- | -------------------- |
| Trial → Paid conversion        | 25-30%              | 35-40%              | 40-50%               |
| Free → Pro conversion (of MAU) | 3-4%                | 5-6%                | 6-8%                 |
| Monthly churn rate             | <10%                | <7%                 | <5%                  |
| Annual plan adoption           | 50%                 | 60%                 | 65%                  |
| ARPU (all users)               | $0.15               | $0.30               | $0.50+               |
| LTV (Pro subscriber)           | $25                 | $40                 | $60+                 |
| Paywall → Trial conversion     | 15%                 | 20%                 | 25%                  |
| Feature limit hit → Upgrade    | 8%                  | 12%                 | 15%                  |

### Analytics Events to Track

| Event                     | Properties                          | Purpose                     |
| ------------------------- | ----------------------------------- | --------------------------- |
| `paywall_shown`           | feature, context, trigger_type      | Where do users see paywalls |
| `paywall_dismissed`       | feature, context, time_on_screen    | Where do they bounce        |
| `trial_started`           | plan_type, trigger_feature          | What drives trial starts    |
| `trial_converted`         | plan_type, days_in_trial            | Trial effectiveness         |
| `subscription_started`    | plan_type, price, trial_used        | Revenue tracking            |
| `subscription_cancelled`  | plan_type, tenure_months, reason    | Churn analysis              |
| `subscription_renewed`    | plan_type, renewal_count            | Retention tracking          |
| `feature_limit_hit`       | feature, usage_count, limit         | Upgrade pressure points     |
| `affiliate_click`         | partner, context, trip_id           | Affiliate funnel            |
| `affiliate_conversion`    | partner, booking_amount, commission | Revenue attribution         |
| `template_pack_purchased` | pack_name, price                    | IAP revenue                 |
| `tip_given`               | tier, amount                        | Tip jar revenue             |

---

## Revenue Timeline & Implementation Schedule

### V2 Sprint: Subscription System (2 days of V2 build)

**Day 1 (V2 Week 3):**

- StoreKit 2 configuration file with all product IDs

- App Store Connect: create subscription group + all IAP products

- `EntitlementManager` implementation

- `PaywallView` and `UpgradePromptView`

- Sandbox testing

**Day 2 (V2 Week 3):**

- Feature gating in all relevant views (AI, sharing, export, email forwarding)

- Usage tracking (UserDefaults + Supabase sync)

- Monthly reset cron job

- "Restore Purchases" functionality

- Pro badge in Profile screen

- Analytics events

### V3 Sprint: Affiliate Integration (3 days)

- Viator Partner API integration

- Kiwi Tequila flight affiliate

- [Booking.com](https://www.booking.com) hotel affiliate

- `AffiliateTrackingService` + tracking tables

- Contextual affiliate surfaces (timeline suggestions, place detail, bookings screen)

- Flight alerts backend (cron job + push notification)

### V4: In-App Booking + B2B (ongoing)

- Viator certification for in-app booking

- B2B white-label API design

- Agency partner portal

---

## The Revenue Pyramid

```
                    ┌─────────┐
                    │ Insur.  │  V5: Travel Insurance
                    │ Sponsor │  V5: Sponsored Placements
                ┌───┴─────────┴───┐
                │ B2B Licensing   │  V4: Agency white-label
                │ In-App Booking  │  V4: Higher commission rates
            ┌───┴─────────────────┴───┐
            │ Affiliate Commissions   │  V3: Viator, flights, hotels
            │ Flight Alert Premium    │  V3: $1.99/mo standalone
        ┌───┴─────────────────────────┴───┐
        │ TripWeave Pro Subscription      │  V2: $4.99/mo or $34.99/yr
        │ Trip Stories Packs + Tip Jar    │  V2: One-time IAP
    ┌───┴─────────────────────────────────┴───┐
    │ FREE TIER — The Foundation               │  V1: Build love, build habit
    │ Unlimited trips, timeline, map, bookings │  Every free user is a
    │ 2 AI plans, 5 email forwards, 2 templates│  potential paying customer
    └──────────────────────────────────────────┘  AND a marketing channel
```

Each layer builds on the one below. Free users fuel growth (Trip Stories sharing = free marketing). Pro subscribers fund AI and infrastructure. Affiliate revenue scales with engagement. B2B and sponsorships add high-margin income at scale.

**The critical insight:** By V3, revenue is diversified across subscriptions, affiliate commissions, and add-ons. No single stream accounts for more than 50% of revenue. This protects against any one partner changing terms, any one revenue model underperforming, or any one market condition shifting.

---

## App Store Optimization for Revenue

### Subscription Page Copy

**Title:** TripWeave Pro — AI Travel Planning

**Subtitle:** Plan smarter. Share beautifully.

**Promotional Text (changeable without app update):**

"Try Pro free for 7 days. AI plans your perfect day in seconds. Premium Trip Stories make your friends jealous. Unlimited email parsing handles bookings automatically."

**Description bullet points:**

- Unlimited AI Day Planning — one tap, perfect itinerary

- 12+ Premium Trip Story templates — share your adventures beautifully

- Unlimited email forwarding — forward booking confirmations, AI organizes them

- Route optimization — save hours of walking with optimized routes

- PDF & calendar export — polished itineraries for offline and sharing

- Screenshot-to-booking — snap a confirmation, AI reads it

- AI Travel Assistant — context-aware chat that knows your trip

- Early access to new features

### App Store Screenshots (Revenue-Focused)

Screenshot 3 (of 6): Show the AI Day Planner generating a day in Paris with the "Pro" badge visible. Tagline: "AI plans your perfect day."

Screenshot 5 (of 6): Show a beautiful Trip Story card being shared to Instagram with the premium template visible. Tagline: "Share your adventures beautifully."

These screenshots sell the premium experience to potential users before they even download.

---

## Summary: The Revenue System

| Principle                      | Implementation                                      |
| ------------------------------ | --------------------------------------------------- |
| Love first, money second       | Free tier is genuinely excellent                    |
| Revenue from V2                | StoreKit 2 subscription from day one of V2          |
| Multiple streams               | 9 streams across 5 versions                         |
| AI pays for itself             | Pro subscription revenue > AI infrastructure cost   |
| Affiliate adds scale           | V3 commissions grow linearly with users             |
| Never nag                      | Soft paywalls, contextual prompts, always escapable |
| Viral features stay accessible | Free Trip Stories (with branding) drive growth      |
| Anti-churn built in            | Annual defaults, usage summaries, win-back offers   |
| Self-sustaining by 400 DAU     | Subscription covers all costs                       |
| $10K+/month by 6K DAU          | Subscription + affiliate combined                   |

