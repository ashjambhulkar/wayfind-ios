# Wayfind v2 — Localization Strategy

> Cross-cutting deliverable. Captures how new copy in Waves 1–4 is
> wired into `Localizable.xcstrings` and what's required for any future
> view to ship localization-ready.
>
> Wayfind ships v2 in **English only**. This document is the
> infrastructure scaffolding that lets us add a second locale (likely
> French or German) in v2.1 without touching every view.

---

## 1. Where strings live

| Location                         | Auto-extracted? | Notes                                                                  |
| -------------------------------- | --------------- | ---------------------------------------------------------------------- |
| `Text("...")`                    | ✅ Yes          | Xcode build extracts directly into `Localizable.xcstrings`.            |
| `Button("...")`, `Label("...")`  | ✅ Yes          | Same — uses `LocalizedStringKey` initialiser by default.               |
| `String(localized: "...")`       | ✅ Yes          | Use whenever the string is computed in a view model or service.        |
| `LocalizedStringResource(...)`   | ✅ Yes          | Modern, prefer for resources passed across module boundaries.          |
| `String("...")` (plain literal)  | ❌ No           | **NOT extracted**. Convert to one of the above.                        |
| Server / Edge Function responses | n/a             | Server returns codes (`free_limit_reached`); client maps to localized copy. |

The catalog file: `wayfind/Localizable.xcstrings` (Xcode 15+ string catalog).

---

## 2. Wave 1–4 string audit

The following string sites were converted to `String(localized:)` in
this PR so they appear in the catalog with translator-readable
comments. Sites already using `Text("...")` or `Button("...")` were
left alone — those auto-extract on build.

### 2.1 Paywall placement copy

`PaywallPresenter.swift` — `headline` and `bodyCopy` per `PaywallPlacement`:

| Placement              | Headline key                                              | Body key                                               |
| ---------------------- | --------------------------------------------------------- | ------------------------------------------------------ |
| `aiBadgeSoftGate` / `aiQuotaExhausted` | "Unlimited AI day plans"                  | "Wayfind Pro lifts the 3-plan monthly cap …"           |
| `csvExport`            | "Export your trip expenses"                                | "Get a clean CSV of every expense …"                   |
| `currencyMulti`        | "See your trip total in your home currency"                | "We convert each expense at its capture-day rate …"    |
| `flightTracking`       | "Live flight status, even at the gate"                     | "Get gate, terminal, and delay updates pushed …"       |
| `documents`            | "Keep every doc with your trip"                            | "Store boarding passes, hotel confirmations …"         |
| `settingsManual`       | "Wayfind Pro"                                              | "Unlocks unlimited AI day plans …"                     |

Each `String(localized:)` call carries a `comment:` argument that
explains *why* the copy exists, so translators don't need to read the
SwiftUI source. Example:

```
String(
    localized: "Unlimited AI day plans",
    comment: "Paywall headline shown when a free user hits the AI Day Planner limit or taps the credits-remaining badge."
)
```

### 2.2 Restore Purchases outcomes

`ProSubscriptionSection.swift` — `RestoreOutcome.message`:

| Case                | Localizable key                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| `.restored`         | "Wayfind Pro restored on this device."                                                          |
| `.nothingToRestore` | "No purchases found on this Apple ID. If you subscribed on another account, sign in with it on the App Store." |
| `.failed(detail)`   | "Couldn't restore purchases. \(detail)" — `detail` is the localized error from RevenueCat.      |
| `.unavailable`      | "Subscriptions aren't available in this build. They'll work on TestFlight."                     |

### 2.3 AI quota error messages

`ItineraryAIModels.swift` — `ItineraryAIError.errorDescription`:

| Case                    | Notes                                                                       |
| ----------------------- | --------------------------------------------------------------------------- |
| `.quotaExceeded`        | Free monthly cap message — translation should mention "monthly".            |
| `.dailySafetyCapReached`| Daily anti-abuse cap — applies to both tiers, do **not** mention upgrade.   |

### 2.4 Document quota error messages

`TripDocumentsService.swift` — `TripDocumentError.errorDescription`:

| Case                | Localizable key                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| `.ceilingReached`   | "This trip already has \(N) documents. Delete some to add more."                                |
| `.userQuotaReached` | "You've reached the free plan limit of \(N) documents per trip. Upgrade to Wayfind Pro to add more." |
| `.noClient`         | "Sign in to add documents."                                                                     |

### 2.5 Other surfaces (Wave 1–4)

The remaining new views use `Text("...")`, `Button("...", action:)`,
`Label`, `Image`-with-text, etc. — all extracted automatically. No
manual `String(localized:)` wrapping required.

Specifically:
- `TripDocumentsView`, `BookingAttachmentsSheet`, `ActivityPhotosSheet`, `ExpenseReceiptsSection` — all `Text(...)` based.
- `CalendarSyncOnboardingView` — onboarding pages use `Text(title)` / `Text(description)` over literal strings (extracted).
- `BudgetHomeCurrencyHeader` — all literal strings in `Text("Tap to view in \(homeCurrency)")` etc. are extracted.
- `FlightStatusBadge` — labels use literal `Text(...)` for "On time", "In flight", etc.
- `AIPlanWizardSheet` — accessibility hints use literal strings already wrapped properly.
- `ProSubscriptionSection` — Text-based UI strings are auto-extracted; only the `RestoreOutcome` enum's computed `String` properties needed manual wrapping (covered in §2.2).

---

## 3. Build verification

After every PR that adds new copy:

```sh
xcodebuild -workspace wayfind.xcworkspace \
  -scheme wayfind \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  build
```

The build process re-runs string extraction. Open
`wayfind/Localizable.xcstrings` in Xcode and verify the new strings
appear with `state: "new"` in the `en` localization. Translators see
the comment field next to each entry.

> ⚠️ Strings only extract from files in the build target. If you add a
> new file and don't see its strings appear after a build, check the
> file is included in the `wayfind` target membership.

---

## 4. Plurals + interpolations

Use Xcode's plural variants in the string catalog GUI for any string
that depends on a count. Example:

```swift
String(
    localized: "\(count) document(s) added",
    comment: "Confirmation toast after adding documents to a trip."
)
```

Open the entry in Xcode → switch to "Variants" → add `one` / `other`
plural rules. For Slavic languages we'll need `few` and `many` too —
these don't ship in v2 but the infrastructure handles them when added.

For interpolations, prefer named arguments via `String.LocalizationValue`
when the order might shift across languages:

```swift
String(
    localized: "Pay \(amount) to \(name)",
    // German might render as "Zahle \(name) \(amount)" — string
    // catalog handles the reorder automatically because the
    // interpolations are positional placeholders.
    comment: "Settle Up button label."
)
```

---

## 5. Anti-patterns

- ❌ Concatenating `String + String` for localized output. Word order
  varies — use a single `String(localized:)` with interpolations.
- ❌ Stripping "(Pro)" suffix in code with `.replacingOccurrences(of:)`.
  Add a separate localized key per variant instead.
- ❌ Hardcoding plurals: `"\(count) item" + (count > 1 ? "s" : "")` —
  use plural variants instead.
- ❌ Storing copy in a server response that the client renders verbatim.
  Server returns codes; client maps to localized copy. (Already the
  pattern — see `ItineraryAIError` mapping `free_limit_reached` etc.)
- ❌ Putting product names ("Wayfind", "Wayfind Pro") inside
  `String(localized:)` without flagging in the comment that they're
  brand names. Translators should leave them untranslated.

---

## 6. Future locales — readiness checklist

Adding French (or any locale) post-v2:

1. Open `wayfind/Localizable.xcstrings` in Xcode.
2. Top-right "+" → add `French (fr)`.
3. For each entry, fill in the French translation using the comment
   for context.
4. For plurals, fill all required variants (`one`, `other` for FR).
5. Add `fr.lproj` to the `.xcodeproj` (Xcode handles this automatically).
6. Test by setting Scheme → Run → Options → Application Language → French.
7. Re-run the §0.7 locale spot-checks from the accessibility audit:
   long-string truncation, RTL safety (Arabic/Hebrew), date/currency
   formatting.

---

## 7. CI integration (deferred)

When the localization workflow matures, add:

- Lint check: every `String(localized:)` MUST have a `comment:` argument.
- CI gate: build fails if `Localizable.xcstrings` has any entry with
  `state: "new"` for shipping locales (forces translation completion
  before merge).
- Snapshot suite: render key surfaces in every locale to catch layout
  regressions.

These ship with v2.1 once we add the second locale.
