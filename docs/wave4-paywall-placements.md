# Wave 4.3 — Paywall placements & anti-pattern reference

This doc is the canonical reference for **where Wayfind shows a paywall,
why each surface exists, and what we deliberately do not do**. It pairs
with `wayfind/Services/PaywallPresenter.swift`, which contains the same
anti-pattern list inline so it travels with the code.

## Surfaces

Each surface maps to a `PaywallPlacement` enum case. Surface ids are
mirrored in the RevenueCat dashboard (Project → Placements) so we can
A/B different offerings per entry point without an app release.

| Placement                    | Trigger                                                       | Soft / Hard | Wave  |
|------------------------------|---------------------------------------------------------------|-------------|-------|
| `ai_badge_soft_gate`         | "X of 3 free remaining" badge tap in AI Plan wizard           | Soft → Hard | 4.2 / 4.5 |
| `ai_quota_exhausted`         | AI Plan wizard server returned `free_limit_reached` (429)     | Hard        | 4.2   |
| `csv_export`                 | Budget tab → toolbar → "Export CSV (Pro)"                     | Soft → Hard | 2.3 / 4.5 |
| `currency_multi`             | Budget header trip → home currency conversion tap             | Soft → Hard | 2.2b / 4.5 |
| `flight_tracking`            | Flight status badge tap on a timeline booking card            | Soft → Hard | 3.3 / 4.5 |
| `documents`                  | Trip documents tab — soft 5/25 ceiling tap                    | Soft → Hard | 1.4 / 4.5 |
| `settings_manual`            | Settings → Wayfind Pro tile (manual upgrade entry)            | Manual      | 4.6   |

### Soft vs hard

* **Soft gate** — the feature still works for the free user; the paywall
  is a discovery surface that fires `pro_gate_attempted` and gives the
  user a value prop. Used in Waves 1–3 to size demand pre-paywall.
* **Hard gate** — the feature requires Pro. Wave 4.5 flips every soft
  gate above to hard in a single PR so no surface ships with mixed
  semantics.

### Manual

* **Manual** — user explicitly tapped a "Wayfind Pro" tile from
  Settings. No upstream feature blocked them; we still log
  `pro_gate_attempted` with `surface = settings_manual` so funnel
  analytics can distinguish active intent from feature-blocked intent.

## Anti-patterns

These are intentional non-features. Do not "fix" them in a future
refactor without first updating this doc + the associated comments in
`PaywallPresenter.swift`.

### 1. Never present a paywall as a `.fullScreenCover` blocking app launch

App Store Review Guideline 4.5.4 prohibits hard-paywalling the entire
app on launch. We always present the paywall as a sheet (`.large`
detent on phone, `NavigationStack` wrapped on iPad) on top of working
content the user can return to.

### 2. Never stack a paywall sheet directly inside another modal flow

Sheets-on-sheets are technically supported in iOS 16+ but visually
nest the new sheet inside the previous one's presentation context,
making the back stack feel deep and the dismissal target unclear.

The single exception is the AI Plan wizard, where the paywall lands
above the wizard sheet because the wizard *is* the context the user
is unlocking — we want them to come back to it after purchase. In that
case the `.paywallSurface()` modifier on the scene root presents
directly, so the sheet animates from the root and the wizard remains
visible underneath as the user's recovery target.

### 3. Never re-present the paywall on every app launch when a deferred / Ask-to-Buy purchase is pending

`EntitlementService.purchasePending` exposes the deferred state. Views
should render an inline "waiting for guardian approval…" hint instead of
re-launching the paywall — relaunching it both wastes the user's tap and
risks them attempting a duplicate purchase that StoreKit will reject.

### 4. Never localise the paywall ourselves

RevenueCat's paywall editor handles localisation server-side, so a price
or copy change ships without an app release. The fallback view in
`PaywallHostView.paywallFallback` only ships when the SDK isn't linked
into the dev build — it's not a production code path.

### 5. The paywall must close the sale, not deliver a feature explainer

Users land on the paywall having already seen the soft-gate badge or
the value prop in the upsell sheet. By the time they're at the paywall,
copy must focus on *price comparison* and *purchase action*, not
re-explaining what Pro unlocks.

### 6. Never gate Restore Purchases behind Pro state

Restore must be available from Settings even for users we *think* are
Free. RevenueCat's `Purchases.shared.restorePurchases()` reconciles
receipts from a different device / account and is the App Review
acceptance gate.

## A/B testing

RevenueCat resolves a different offering per `placement` id. To run
an A/B:

1. Create a new offering in RevenueCat dashboard (e.g. duplicate
   `default`, change the trial length to 14 days).
2. Bind it to the placement under test (e.g. `ai_quota_exhausted`).
3. RevenueCat's experiment dashboard reports conversion lift per
   variant. No app release needed.

Because the call site (`PaywallPresenter.shared.present(.aiQuotaExhausted, …)`)
doesn't know which offering it'll resolve to, A/Bs ship as pure
configuration changes.

## CustomerCenter (Wave 4.6)

The Settings → Manage Subscription tile drives `RevenueCatUI.CustomerCenterView`,
configured with anti-churn customisations:

* "Pause subscription" — RevenueCat's Pause action surfaced as the
  primary cancellation alternative.
* "Switch to monthly" — for users on annual considering cancellation,
  surface a downgrade-to-monthly path before the cancel button.

The actual implementation lives in Wave 4.6; documenting here so the
flow stays connected to the rest of the placement story.
