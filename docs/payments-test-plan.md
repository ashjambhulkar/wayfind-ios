# Wayfind Pro — Payments Test Plan

> Wave 4.7 deliverable. This document is the single source of truth
> for QA, the founder, and the on-call engineer when validating any
> change that touches RevenueCat, App Store Connect IAPs, or the
> entitlement state machine.
>
> **When to use it**
>
> 1. Before *every* App Store submission that touches monetization.
> 2. Before flipping the RevenueCat dashboard to a new offering or
>    paywall variant.
> 3. After rotating webhook secrets (`docs/wave4-revenuecat-runbook.md`).
> 4. As the smoke test on first install of any TestFlight build.
>
> Any scenario that fails marks the build NOT releasable. There is
> no "ship and patch later" path for billing — the cost of getting
> it wrong is real money plus App Store guideline 3.1.x violations.

---

## 0. Test prerequisites

### 0.1 Sandbox accounts

You need at least three Apple Sandbox testers in App Store Connect → Users
and Access → Sandbox. Naming convention:

| Tester             | Region | Purpose                                           |
| ------------------ | ------ | ------------------------------------------------- |
| `qa-us@wayfind.io` | US     | Standard purchase / restore flows                 |
| `qa-fr@wayfind.io` | FR     | Localized currency + EU intro-offer eligibility   |
| `qa-jp@wayfind.io` | JP     | RTL-adjacent layout + non-USD pricing             |
| `qa-ask@wayfind.io`| US     | Ask-to-Buy / family-sharing deferred state        |

> ⚠️ Sandbox testers must be created *fresh* (never used to sign in to
> the real App Store). Reuse causes silent purchase failures with no
> error surface.

### 0.2 Sandbox time acceleration

Apple sandbox accelerates subscription cycles. As of 2026-04, the rates are:

| Real plan      | Sandbox renewal cadence |
| -------------- | ----------------------- |
| Monthly $4.99  | Every 5 minutes         |
| Annual $39.99  | Every 1 hour            |
| Founder Annual | Every 1 hour            |

Plan test sessions accordingly — a single "real-world week" of
renewals takes ~35 minutes in sandbox.

### 0.3 Build configuration

- TestFlight build: real RevenueCat, real App Store Connect, sandbox
  tester signed into device's App Store account.
- Local DEBUG build: real RevenueCat (`AppConfig.revenueCatPublicAPIKey`
  populated) BUT sandbox tester. Verify `EntitlementService` logs
  `isPro` flips in console.
- StoreKit-only path: `AppConfig.isRevenueCatConfigured == false`.
  Used to validate the graceful-degradation path. Restore button must
  read "Subscriptions aren't available in this build."

---

## 1. First-purchase flow (P0)

| # | Step                                                                                                | Expected                                                                                                 |
| - | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 1 | Fresh install, sign in as `qa-us`.                                                                  | Profile shows "Upgrade to Wayfind Pro" tile.                                                             |
| 2 | Open AI Plan wizard. Generate 3 plans.                                                              | Badge counts down: "2 of 3 free remaining" → "1 of 3 free remaining" → "0 of 3 free remaining".          |
| 3 | Generate a 4th.                                                                                     | Wizard transitions to `quotaExhausted` state. Tapping CTA presents paywall sheet.                        |
| 4 | Subscribe to Monthly $4.99 with 7-day trial.                                                        | StoreKit prompt → success → paywall auto-dismisses → `EntitlementService.isPro` flips to `true`.         |
| 5 | Re-enter wizard.                                                                                    | Badge reads "Unlimited" with infinity icon. Generate 5+ plans without hitting any cap.                   |
| 6 | Open Profile.                                                                                       | Pro section reads "You're on Wayfind Pro" + "Manage subscription" + "Restore Purchases" rows visible.    |
| 7 | Confirm RevenueCat dashboard → Customers → `qa-us` shows entitlement `wayfind_pro` active.          | Entry exists with the right product id and trial expiration.                                             |
| 8 | Confirm Supabase `user_subscriptions` row updated (`is_pro=true`, `current_period_end`).            | Row reflects RevenueCat state within 5 seconds (webhook).                                                |
| 9 | Confirm `processed_webhook_events` has matching `INITIAL_PURCHASE` row with `source='webhook'`.     | Row exists, `event_id` is the RevenueCat event UUID (idempotency anchor).                                |

**Pass criteria**: All 9 rows pass. Any failure = block release.

---

## 2. Restore (P0 — App Store guideline 3.1.1)

### 2.1 Same-device restore (post-reinstall)

| # | Step                                                              | Expected                                                                                  |
| - | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 1 | Run §1 to land in Pro state.                                      | Pro entitlement granted.                                                                  |
| 2 | Delete app, reinstall from TestFlight.                            | App opens in fresh state.                                                                 |
| 3 | Sign in as `qa-us` (same Apple ID + same Wayfind account).        | `EntitlementService` boots → reads `user_subscriptions` mirror → `isPro=true` immediately.|
| 4 | If step 3 reads Free, tap Profile → Restore Purchases.            | Restore network call succeeds, banner reads "Wayfind Pro restored on this device."        |
| 5 | Re-open AI Plan wizard.                                           | "Unlimited" badge visible.                                                                |

### 2.2 New-device restore (cross-device)

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Subscribe on Device A as `qa-us`.                                             | Pro on Device A.                                                                  |
| 2 | Sign in to Wayfind on Device B with same email; same Apple ID on App Store.   | `EntitlementService.bind(userId:)` finds the Supabase mirror → Pro immediately.   |
| 3 | If step 2 reads Free, tap Restore.                                            | Restore succeeds; Pro flips on.                                                   |

### 2.3 Restore with no purchase

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Sign in as a tester that has NEVER purchased.                                 | Free tile visible.                                                                |
| 2 | Tap Restore Purchases.                                                        | Banner reads "No purchases found on this Apple ID. If you subscribed on another account, sign in with it on the App Store." NOT silent. |

---

## 3. Hard-gate paywalls (Wave 4.5 surfaces)

For each surface below, the test pattern is identical:

1. Be on a Free account with at least one trip.
2. Trigger the gate (per-surface action).
3. Verify the paywall sheet presents with placement-specific headline.
4. Verify `pro_gate_attempts` row is written with `is_pro=false` and the
   correct `surface` and `placement` fields.
5. Dismiss the paywall.
6. Verify the underlying action did NOT silently succeed.

| Placement                | Trigger                                                     | Expected paywall headline                          |
| ------------------------ | ----------------------------------------------------------- | -------------------------------------------------- |
| `documents`              | Trip Documents → upload 6th doc, OR tap cap pill            | "Keep every doc with your trip"                    |
| `csv_export`             | Budget tab → toolbar → "Export CSV (Pro)"                   | "Export your trip expenses"                        |
| `currency_multi`         | Budget header → tap currency conversion toggle              | "See your trip total in your home currency"        |
| `flight_tracking`        | Timeline → tap a locked flight badge                        | "Live flight status, even at the gate"             |
| `ai_quota_exhausted`     | AI wizard → generate 4th plan in same calendar month        | "Unlimited AI day plans"                           |
| `ai_badge_soft_gate`     | AI wizard configurator → tap "X of 3 free remaining" badge  | "Unlimited AI day plans"                           |
| `settings_manual`        | Profile → "Upgrade to Wayfind Pro" tile                     | "Wayfind Pro"                                      |

**Per-surface analytics check**: in Supabase SQL editor:

```sql
select created_at, gate, surface, metadata
from public.pro_gate_attempts
where user_id = :uid
order by created_at desc
limit 20;
```

Each tap above should produce exactly one row.

---

## 4. Cancellation + downgrade flows (P0)

### 4.1 Cancellation outside the app

Apple guideline: cancellation MUST be possible from Settings → Apple ID
→ Subscriptions. We don't ship a cancel button — we ship a
CustomerCenter that defers to Apple's flow.

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Run §1 to reach Pro.                                                          | Pro.                                                                              |
| 2 | Profile → Manage subscription.                                                | RevenueCat CustomerCenter sheet presents.                                         |
| 3 | Tap Cancel subscription (CustomerCenter routes to Apple's Subscriptions UI).  | Apple subscription screen opens.                                                  |
| 4 | Cancel.                                                                       | Apple confirmation toast.                                                         |
| 5 | Wait one sandbox renewal cycle (5 min for monthly, 1 hr for annual).          | RevenueCat webhook fires `CANCELLATION` then `EXPIRATION`.                        |
| 6 | Verify Supabase: `user_subscriptions.is_pro=false` after expiration.          | Mirror updated within 5 s of webhook.                                             |
| 7 | Verify `processed_webhook_events` has both `CANCELLATION` and `EXPIRATION`.   | Two rows, both `source='webhook'`.                                                |
| 8 | Re-open app.                                                                  | `EntitlementService.isPro=false`. AI badge re-appears with "3 of 3 free remaining"|

### 4.2 Anti-churn — Pause / Switch to monthly

When CustomerCenter offers Pause or Switch-to-monthly (configured in
RevenueCat dashboard):

| # | Step                                                | Expected                                                                  |
| - | --------------------------------------------------- | ------------------------------------------------------------------------- |
| 1 | Pro user opens CustomerCenter.                      | Pause and "Switch to monthly" CTAs visible.                               |
| 2 | Tap Pause.                                          | Confirmation; subscription pauses at next renewal.                        |
| 3 | RevenueCat dashboard → Customer detail.             | Status reads "paused", `expires_at` is the pause-end date.                |
| 4 | App refreshes after current period end.             | `EntitlementService.isPro=true` until pause-end, then flips to false.     |

### 4.3 Refund

Sandbox cannot trigger real refunds — verify the *webhook handler*
processes refunds correctly using the RevenueCat dashboard's "Send
test event" feature.

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | RevenueCat dashboard → Project → Webhooks → Send test event → `REFUND`.       | Webhook fires.                                                                    |
| 2 | Check Supabase: `user_subscriptions.is_pro=false` immediately.                | Row updated.                                                                      |
| 3 | Check `processed_webhook_events` for `REFUND` row.                            | Row exists. Re-sending the same test event a second time inserts NO new row (idempotency). |
| 4 | Open app.                                                                     | Pro entitlement gone immediately on next `EntitlementService.refreshCustomerInfo()`. |

---

## 5. Edge cases (P1)

### 5.1 Ask-to-Buy (family sharing deferred purchase)

Use `qa-ask@wayfind.io` configured as a child in a Family Sharing group
(parent = `qa-us@wayfind.io`).

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Sign in as child, open paywall, tap Subscribe.                                | StoreKit shows "Ask permission" prompt.                                           |
| 2 | Confirm Ask.                                                                  | App returns to paywall. `EntitlementService.purchasePending=true`.                |
| 3 | Verify UI shows "Waiting for approval" copy and the paywall does NOT auto-dismiss. | UI reflects deferred state.                                                  |
| 4 | Switch to parent device, approve via Settings.                                | Within ~10s the child device receives a webhook → `isPro=true` → paywall dismiss. |

### 5.2 Subscriber alias (account merge)

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | RevenueCat dashboard → trigger `SUBSCRIBER_ALIAS` test event from user A → B. | Webhook fires.                                                                    |
| 2 | Verify Supabase: `user_subscriptions.user_id=B` carries A's entitlement.      | Row consolidated to B; A's row inactive.                                          |

### 5.3 Webhook secret rotation

See `docs/wave4-revenuecat-runbook.md` §3 for the rotation procedure.

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Set `REVENUECAT_WEBHOOK_SECRET_NEXT` to new secret; keep old as `_SECRET`.    | Both secrets exist.                                                               |
| 2 | RevenueCat dashboard → swap to new secret.                                    | Webhook traffic now signed with new secret.                                       |
| 3 | Trigger any webhook (e.g. test `INITIAL_PURCHASE`).                           | Edge Function accepts (matches `_NEXT`).                                          |
| 4 | Remove old secret.                                                            | Subsequent test events accepted (matches single secret).                          |
| 5 | Trigger a webhook signed with the OLD secret (or replay).                     | 401 — proves the old secret is genuinely retired.                                 |

### 5.4 Reconcile drift correction

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Manually flip a `user_subscriptions` row to `is_pro=false` for an active Pro. | Supabase row drifts from RevenueCat state.                                        |
| 2 | Manually invoke `reconcile-revenuecat` Edge Function.                         | Function runs; finds the drift; corrects the row.                                 |
| 3 | Check `processed_webhook_events` for `RECONCILE_DRIFT` row with `source='reconcile'`. | Audit row exists.                                                          |

### 5.5 Daily safety cap (Pro abuse defence)

| # | Step                                                                          | Expected                                                                          |
| - | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | Pro user generates 50 AI day plans in a single UTC day (use a script for speed). | First 50 succeed.                                                              |
| 2 | Generate plan #51.                                                            | 429 with body `{"error":"daily_safety_cap_reached"}`. UI shows "You've hit today's safety limit for AI planning…" — NOT the upgrade paywall. |
| 3 | Wait until next UTC day boundary.                                             | Counter resets; generations succeed again.                                        |

---

## 6. Localization spot-checks (P1)

For each locale (`en-US`, `fr-FR`, `ja-JP`):

| Surface                           | Check                                                                |
| --------------------------------- | -------------------------------------------------------------------- |
| Paywall headlines / body          | Render in target locale (when localized; English-only acceptable in v1 — flag for cross-cutting Localizable.strings task). |
| Currency in paywall pricing       | StoreKit returns localized price; "$4.99/month" → "4,99 €/mois" in FR. |
| Restore confirmation banner       | Renders in current locale; layout doesn't break with longer strings. |
| CustomerCenter sheet              | Apple-managed; verify navigation labels are translated.              |

---

## 7. Accessibility spot-checks (P1)

VoiceOver pass on each new surface:

| Element                          | Expected announcement                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| Paywall close button             | "Close, button"                                                                      |
| Paywall purchase row             | Product name + price + "subscription, button"                                        |
| Restore Purchases row            | "Restore Purchases. Re-syncs purchases made on this Apple ID. Button."               |
| Manage subscription row          | "Manage subscription. Opens subscription management. Cancel, pause, or switch plans here. Button." |
| AI quota badge (Free)            | "3 of 3 free remaining. Upgrade to Pro for unlimited AI day plans. Button."          |
| AI quota badge (Pro)             | "Unlimited."                                                                         |
| Multi-currency toggle (Free)     | "Total budget … in trip currency. Wayfind Pro required. Opens upgrade screen."       |
| Flight badge (Free)              | "AA 100. On time. Live updates require Wayfind Pro."                                 |
| Documents cap pill               | "Free plan limit reached (5 per trip). Tap to upgrade for unlimited."                |

Dynamic Type: re-run §1 with text size set to AX5 (largest accessibility size).
Layout must not clip; paywall should scroll if needed.

---

## 8. Build matrix

Every release passes these on at minimum:

| Device                  | iOS    | Status |
| ----------------------- | ------ | ------ |
| iPhone 15 Pro (sim)     | 18.4   |        |
| iPhone SE 3rd gen (real)| 18.4   |        |
| iPad Air M2 (real)      | 18.4   |        |
| iPhone 13 mini (real)   | 17.6   |        |

iPad pass adds: paywall renders inside a `NavigationStack` on regular size class
(not as a popover); Profile section reflows on 50/50 split-view.

---

## 9. Off-checklist red flags (release blockers)

Stop the release if you observe ANY of:

- Paywall sheet presents OVER another sheet (anti-pattern from `wave4-paywall-placements.md` §6).
- Paywall presents on cold start before the user has done anything.
- Restore tap shows no UI feedback for >2 seconds without a spinner.
- Successful purchase leaves the user staring at the paywall (auto-dismiss missing).
- A free user manages to bypass any §3 hard gate via:
  - background-resumed upload (documents),
  - directly navigating to a deep link, or
  - rotating the device mid-paywall.
- `pro_gate_attempts` row missing for any §3 surface.
- `processed_webhook_events` row missing or duplicated for any §1, §4, §5 webhook.

---

## 10. Sign-off

```
Build:        TF / RC ____________________
Tester:       ____________________
Date:         ____________________

§1  First-purchase                 PASS / FAIL
§2  Restore                        PASS / FAIL
§3  Hard-gate paywalls             PASS / FAIL
§4  Cancellation + downgrade       PASS / FAIL
§5  Edge cases                     PASS / FAIL
§6  Localization                   PASS / FAIL  (en-only acceptable in v1)
§7  Accessibility                  PASS / FAIL
§8  Build matrix                   PASS / FAIL

Notes:
```

The signed-off doc lives in the release ticket and is mirrored to
`docs/release-notes/wave4-payments-vN.md` so we have an audit trail.
