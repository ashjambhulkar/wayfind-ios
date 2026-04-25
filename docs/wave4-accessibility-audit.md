# Wayfind v2 — Accessibility Audit

> Cross-cutting deliverable for Waves 1–4. Every new view shipped in
> this batch was audited against the criteria below and either passed
> as-is or was fixed in the same PR. This document lists each view,
> the audit pass/fix status, and the gold-standard checklist that
> future PRs are expected to satisfy.
>
> The audit is **manual** today — we don't have an automated a11y
> snapshot framework. The plan post-Wave 5 is to add `XCAccessibilityIssue`
> assertions to the existing snapshot tests, which will turn this doc
> into a CI gate. Until then, this is the reference.

---

## 0. Audit checklist

For every new view, every interactive element, every decorative graphic.

### 0.1 VoiceOver

- [ ] Every `Button`, `NavigationLink`, `PhotosPicker`, `Menu`, etc. has a meaningful `accessibilityLabel`. Must read clearly out of context.
- [ ] Decorative SF Symbols inside labelled buttons are marked `.accessibilityHidden(true)` so VoiceOver doesn't read "chevron right, button" or similar.
- [ ] Composite rows (Image + Text + chevron) use `.accessibilityElement(children: .combine)` so VoiceOver speaks them as one unit instead of three.
- [ ] When the affordance is not obvious from the label alone, `accessibilityHint` describes the action ("Opens upgrade screen.", "Re-syncs purchases made on this Apple ID.").
- [ ] Soft-gate / Pro-locked controls explicitly say so in the label or hint ("Wayfind Pro required.", "Live updates require Wayfind Pro.").

### 0.2 Dynamic Type

- [ ] Text uses `Font.app*` (or `.font(.body)`, etc.) — no fixed `pt` sizes for prose.
- [ ] Headings + body don't truncate or get clipped at AX5 (largest accessibility size). Use `.lineLimit(nil)` or `.fixedSize(horizontal: false, vertical: true)` where appropriate.
- [ ] Multi-line layouts pass at AX5 without horizontal overflow.

### 0.3 Color contrast

- [ ] All text against background meets WCAG AA (4.5:1 for body, 3:1 for large).
- [ ] Pro lock chips, badges, and tap-affordance hints don't rely on colour alone — pair with an icon (`lock.fill`, `chevron.right`) and explicit copy.
- [ ] Dark Mode rendering is checked for every surface — colours come from `AppColors.*` tokens which already define light/dark pairs.

### 0.4 Motion

- [ ] Repeating animations (e.g. flight badge pulse, FAB pulse) check `@Environment(\.accessibilityReduceMotion)` and skip the loop when on.
- [ ] Sheet present/dismiss uses default transitions (system honours Reduce Motion automatically).

### 0.5 Hit-target size

- [ ] Tappable elements are ≥ 44×44 pt (Apple HIG minimum).
- [ ] Icon-only buttons (FAB, dismiss "X") have `.frame(width: 44, height: 44)` or equivalent padding.

### 0.6 Localized copy

- [ ] All user-visible strings use English-language copy in the source (Localizable.strings scaffolding ships with the cross-cutting Localization task).
- [ ] No hardcoded number formatting — use `NumberFormatter`, `MoneyFormatter`, `Date.formatted(...)` so locale rules apply.

---

## 1. Wave-by-wave audit log

### Wave 1 — Documents, attachments, receipts

| View                                                | VoiceOver | Dynamic Type | Motion | Hit target | Notes / fixes |
| --------------------------------------------------- | --------- | ------------ | ------ | ---------- | ------------- |
| `TripDocumentsView`                                 | ✅        | ✅           | n/a    | ✅         | FAB labelled "Add document" / "Upgrade to add more documents" depending on cap state. Cap pill is a Button with explicit upgrade copy. Document tiles use `.accessibilityElement(children: .ignore)` + custom label combining title + category + size. |
| `ActivityPhotosSheet`                               | ✅        | ✅           | n/a    | ✅         | PhotosPicker labelled. Thumbnails individually labelled with index ("Photo 2 of 4"). |
| `BookingAttachmentsSheet`                           | ✅        | ✅           | n/a    | ✅         | Same pattern as documents. |
| `ExpenseReceiptsSection`                            | ✅        | ✅           | n/a    | ✅         | Inline receipts show `accessibilityHint("Tap to preview receipt")`. |

### Wave 2 — Calendar sync, currency, CSV

| View                                                | VoiceOver | Dynamic Type | Motion | Hit target | Notes / fixes |
| --------------------------------------------------- | --------- | ------------ | ------ | ---------- | ------------- |
| `CalendarSyncOnboardingView`                        | ✅        | ✅           | n/a    | ✅         | Decorative symbols on each onboarding page are `.accessibilityHidden(true)`. Primary CTA flips label between "Continue" and "Connect Apple Calendar" so VoiceOver always reads the next action. |
| `BudgetHomeCurrencyHeader`                          | ✅        | ✅           | n/a    | ✅         | Wave 4.5 audit: free-user state now adds `accessibilityHint("Wayfind Pro required. Opens upgrade screen.")`; Pro state hint reads "Switches between trip and home currency." |
| CSV export entry (`TripBudgetTabView` toolbar)      | ✅        | ✅           | n/a    | ✅         | Menu item's label `"Export CSV (Pro)"` makes the gating explicit; tapping presents the paywall via `PaywallPresenter`. |
| `ExpenseCSVActivitySheet`                           | ✅        | ✅           | n/a    | ✅         | System share sheet — accessibility provided by UIKit. |

### Wave 3 — Flight tracking

| View                                                | VoiceOver | Dynamic Type | Motion | Hit target | Notes / fixes |
| --------------------------------------------------- | --------- | ------------ | ------ | ---------- | ------------- |
| `FlightStatusBadge`                                 | ✅        | ✅           | ✅     | ✅         | Pulse animation gated on `!reduceMotion`. Free-user accessibility label appends "Live updates require Wayfind Pro." Pro lock icon labelled "Pro feature". |
| `TimelineBookingCardView` (flight rows)             | ✅        | ✅           | n/a    | ✅         | Forwards `onUpgradeTap` so the badge tap routes through `PaywallPresenter`. |

### Wave 4 — Monetization

| View                                                | VoiceOver | Dynamic Type | Motion | Hit target | Notes / fixes |
| --------------------------------------------------- | --------- | ------------ | ------ | ---------- | ------------- |
| `PaywallHostView` (RevenueCatUI)                    | ✅        | ✅           | ✅     | ✅         | RevenueCatUI's own accessibility instrumentation. We add a `Close` toolbar button with default system traits for the dismiss path. |
| `paywallFallback` (dev-build placeholder)           | ✅        | ✅           | n/a    | ✅         | Decorative sparkles icon hidden, body text not clipped at AX5 (`.fixedSize(horizontal: false, vertical: true)`). |
| `AIPlanWizardSheet` quota badge                     | ✅        | ✅           | n/a    | ✅         | Free-state badge labelled with `accessibilityHint("Upgrade to Pro for unlimited AI day plans")`; Pro state reads "Unlimited" with `infinity` symbol that's part of the combined label. |
| `ProSubscriptionSection`                            | ✅        | ✅           | n/a    | ✅         | Each row (status, manage, restore) explicitly labelled. Decorative icons (checkmark.seal, sparkles, chevron.right, arrow.clockwise) marked `.accessibilityHidden(true)`. Restore row label flips during in-flight call so VoiceOver reads "Restoring purchases. Please wait." |
| `ProGateSoftPill` (documents cap)                   | ✅        | ✅           | n/a    | ✅         | Wrapped in a Button with the upgrade hint; pill text fixed-size to prevent truncation. |

---

## 2. Cross-cutting findings + fixes applied

### 2.1 Decorative icons leaking into VoiceOver

**Symptom**: VoiceOver reading "checkmark seal fill, you're on Wayfind Pro" instead of just "You're on Wayfind Pro".

**Fix**: Added `.accessibilityHidden(true)` to every leading icon in row-like Buttons across `ProSubscriptionSection`. Pattern is now: decorative icon → hidden, text label → primary, trailing chevron → hidden.

### 2.2 Composite rows speaking as three elements

**Symptom**: VoiceOver reading "checkmark seal" → swipe → "You're on Wayfind Pro" → swipe → "Unlimited AI day plans, …" as separate items.

**Fix**: Added `.accessibilityElement(children: .combine)` so the whole row is one VoiceOver focus stop. Same fix on the upgrade row.

### 2.3 Pro-gated affordance not announced

**Symptom**: Free user activates the multi-currency toggle, no announcement that the feature is gated.

**Fix**: `BudgetHomeCurrencyHeader` now adds an `.accessibilityHint("Wayfind Pro required. Opens upgrade screen.")` for the Free state and a Pro chip pairing icon + text so colour isn't load-bearing.

### 2.4 Restore in-flight state silent to VoiceOver

**Symptom**: Tap "Restore Purchases", spinner appears, no announcement.

**Fix**: Restore row's `accessibilityLabel` swaps to "Restoring purchases. Please wait." while `isRestoring`. Outcome row uses `.accessibilityAddTraits(.updatesFrequently)` so VoiceOver re-reads it when it appears.

### 2.5 Pulse animation respecting Reduce Motion

**Symptom**: Flight badge pulse animation runs even when Reduce Motion is enabled.

**Fix**: Already correct in `FlightStatusBadge` — `pulseShouldRun` checks `@Environment(\.accessibilityReduceMotion)`. Audit only verified.

---

## 3. Open follow-ups (deferred to post-v2)

1. **Snapshot accessibility tests**: wire `XCAccessibilityIssue` checks into the existing snapshot suite so this audit becomes a CI gate.
2. **VoiceOver script regression**: record macros for the seven critical paywall surfaces (§3 of `payments-test-plan.md`) and replay on every release.
3. **Dynamic Type AX5 visual tests**: add AX5-sized snapshot variants for `ProSubscriptionSection`, `BudgetHomeCurrencyHeader`, `AIPlanWizardSheet`, and `TripDocumentsView`.
4. **Localizable.strings**: this audit assumes English copy. Once the cross-cutting localization scaffold lands, all hint copy needs to be re-audited per locale (German + Japanese typically expand or contract worst-case).
5. **CustomerCenter**: RevenueCatUI's `CustomerCenterView` accessibility hasn't been audited by us — it's vendor-provided. If field reports surface issues, file with RevenueCat directly.

---

## 4. Sign-off

Audited by: AI agent (this PR)
Date: 2026-04-25
Pass criteria: every Wave 1–4 view satisfies §0 checklist or has the gap explicitly logged in §3.

This document is updated whenever a new user-facing view is added.
The expectation is that PR authors run §0 manually before merge and
add a row to §1 documenting the result.
