# Collaborative Budget — Manual QA Matrix

Companion to the Phase 10 deliverable in
`/Users/ashishjambhulkar/.cursor/plans/collaborative_budget_implementation_e445d1c8.plan.md`.

The unit tests in `wayfindTests/` cover the pure-logic layer
(`CategoryRollup`, `SettlementSimplifier`, `ExpenseCategory`,
`ActivityLogEntry.Action`). The SQL trigger smoke test in
`supabase/tests/budget_triggers_smoke.sql` covers the booking → expense
sync, idempotency, and the user-edit guard.

This document is the **manual** matrix that picks up everything those two
can't reach: the actual UI flows, realtime sync between two devices, the
permission gates, and the "weird shape" cases (mixed currencies, removed
collaborator with active splits, deleted booking).

Run each row before shipping a change that touches anything in
`wayfind/Views/Budget/`, `wayfind/Views/Bookings/`, `BudgetService.swift`,
`BudgetViewModel.swift`, or any of the SQL triggers in
`20260501120000_collaborative_budget_v1.sql`.

**Related:** FX / mixed-currency support triage — [`docs/budget-fx-support-runbook.md`](../../docs/budget-fx-support-runbook.md). Product rules — `wayfind/Utilities/BudgetCurrencyProductPolicy.swift`.

Mark each cell ✅ when verified on a real device, ⚠️ when there's a known
caveat (file an issue and link it), and ❌ when the flow is broken (fix
before merge).

---

## 1 · Solo trip × CRUD × split type

The table covers a one-collaborator (owner-only) trip. With a single user
on the splits, the simplifier has nothing to do — but the rest of the UI
still has to behave: amount field accepts decimal, swipe edit/delete
works, the summary card updates, and the activity feed records every
action.

| Action | Equal | Exact | Percentage | Just me (full) |
| --- | --- | --- | --- | --- |
| Add expense | | | | |
| Edit existing expense | | | | |
| Delete via swipe | | | | |
| Delete via context menu | | | | |
| Activity feed entry shows | | | | |

**Pass criteria per cell**:
- Amount entered renders correctly in summary card and category row.
- Decimal precision survives ($33.33 stays $33.33, never $33.330000001).
- Activity feed shows verb + amount + category (e.g. "You added a $25 food
  expense").
- Optimistic mutation: card appears instantly, no spinner gap.
- Deletion confirmation dialog appears and `HapticManager.warning()` fires.

---

## 2 · Group trip × CRUD × split type

Same matrix, but on a trip with **3 accepted collaborators**. The split
editor is exercised, the simplifier produces real settlement cards, and
the activity feed actor name is the editing user (not "Someone").

| Action | Equal | Exact | Percentage | Just me (full) |
| --- | --- | --- | --- | --- |
| Add expense (default = equal split with all 3) | | | | |
| Edit expense → change split type | | | | |
| Edit expense → uncheck one member from split | | | | |
| Delete via swipe | | | | |
| Realtime: change shows on second device within 2 s | | | | |

**Pass criteria per cell**:
- Splits sum to expense amount (live mismatch warning vanishes when
  balanced).
- "Just me (full)" produces zero entries for everyone except the payer.
- Settlement card recalculates within one tick of the change.
- Removed/unchecked members do not appear in the SettlementsSection.

---

## 3 · Auto-from-booking lifecycle

Verifies the SQL trigger pipeline end-to-end through the iOS UI.

| Step | Pass criteria |
| --- | --- |
| Add booking with cost $200 USD | Toast "Booking added · Tracked as $200 expense" appears with **View** action |
| Tap **View** | Switches to Budget tab, scrolls to new expense |
| New expense row shows | Title from booking, "From booking" caption, payer = current user |
| Edit booking amount → $250 | Auto-row refreshes to $250 (verify in budget tab) |
| Edit auto-row title in budget tab | Subsequent booking edits NO LONGER touch the row |
| Delete booking | Expense remains, "From booking" caption disappears (booking_id NULLed) |

The SQL trigger smoke test (`supabase/tests/budget_triggers_smoke.sql`)
asserts the same invariants at the database layer; this row verifies the
iOS UI surfaces them correctly.

---

## 4 · Permissions × access revocation

Walks the `can_see_expenses` flag through its lifecycle. The Budget tab
must appear/disappear cleanly when the gate flips.

| Step | Pass criteria |
| --- | --- |
| Owner invites collaborator with **Expenses access ON** | Collaborator joins, Budget tab visible immediately |
| Invite link reused; flags ON in InviteComposeSheet | New invite carries `can_see_expenses=true` (verify in `trip_invites`) |
| Owner toggles collaborator **Expenses access OFF** in EditAccessSheet | Within 2 s, Budget tab disappears from collaborator's device (no crash) |
| Owner toggles back ON | Budget tab returns; previous expenses visible |
| Collaborator with access OFF tries deep link to `/budget` | Tab is gone; deep link silently lands on the previous tab |

---

## 5 · Removed collaborator with active splits

Covers the "former member" case: a user who paid for or was split into
expenses leaves the trip. Their rows must persist and render with a
graceful fallback name.

| Step | Pass criteria |
| --- | --- |
| Group trip with 3 accepted members, several existing expenses | Settlement cards reference all 3 by display name |
| Owner removes collaborator B (used to be payer on Expense X) | Expense X still appears; payer label degrades to "Former member" |
| B's outstanding split on Expense Y still shows | Splits ledger preserved, balances still computed |
| New settlement created targeting removed user | UI shows handle / name fallback gracefully |

---

## 6 · Mixed-currency trip

Verifies the no-fake-FX guarantee. The summary card must NEVER collapse
USD + EUR into a single number.

| Step | Pass criteria |
| --- | --- |
| Add USD expense $100 | Summary card shows "$100" |
| Add EUR expense €50 | Mixed-currency banner appears at top of Budget tab |
| Summary card | Renders **per-currency** chips (USD primary, EUR secondary), not a single sum |
| Settlements section | Shows two independent settlement graphs (USD and EUR) |
| Edit trip currency to EUR | Existing USD expenses keep their currency; warning appears in EditTripBudgetSheet |

---

## 7 · Settlement & deep links

| Step | Pass criteria |
| --- | --- |
| Tap **Settle Up** on a settlement card | SettlementCompleteSheet opens at medium detent |
| Pick **Cash** → confirm | Confirmation dialog → success haptic → settled-row collapses to checkmark |
| Pick **Venmo** with recipient handle set | Universal Link opens Venmo with prefilled recipient + amount |
| Pick **Venmo** with recipient handle missing | Inline "Add their handle" prompt appears in-sheet |
| Pick **PayPal** with handle | PayPal.me link opens correctly |
| Settled row | Collapses to a single line "Settled · Apr 24" with disclosure to expand |

---

## 8 · Accessibility sweep

Run with VoiceOver on, Dynamic Type set to **Larger Accessibility Sizes
A11y 3** (Settings → Accessibility → Display & Text Size → Larger Text),
and Reduce Motion ON.

| Surface | Pass criteria |
| --- | --- |
| BudgetSummaryCard | Headline scales without truncation; progress bar has no fill animation |
| ExpenseRow | VoiceOver reads "Dinner at Tartine, $42, paid by Alex" as one phrase |
| SettlementCard | VoiceOver reads "Bob owes Alice $25" as one phrase; Settle Up button ≥44pt |
| AddExpenseSheet | Numpad-first focus; amount field reads "Amount, dollars"; sheet expands cleanly |
| ExpenseSplitEditorSheet | Each member row has a single accessible label combining name + amount |
| Reduce Motion ON | No spring on category-grid tap, no fill animation on progress bar |

---

## Sign-off

When every row above is ✅ on a build that passes
`xcodebuild test -only-testing:wayfindTests` AND the SQL test, the
collaborative-budget feature is shipping-ready.
