//
//  ExpenseSplit.swift
//  wayfind
//
//  One row in `expense_splits`. The `tripId` mirror lives on every row so
//  Realtime can filter by `trip_id=eq.<id>` (the `expense_id` foreign key
//  alone wouldn't let us scope subscriptions efficiently). The denormalised
//  column is populated by `tg_expense_splits_set_trip_id` whenever the row
//  is inserted with a NULL trip id.
//

import Foundation

struct ExpenseSplit: Identifiable, Hashable, Sendable {
    let id: UUID
    let expenseId: UUID
    /// Denormalised mirror of `trip_expenses.trip_id`. Set by a DB trigger
    /// when missing, but iOS always populates it on write so the trigger is
    /// belt-and-suspenders for legacy rows.
    let tripId: UUID
    let userId: UUID
    /// Owed share for this user — Decimal to avoid Double drift across very
    /// small percentages or three-way equal splits of $100 ($33.33×3).
    let amount: Decimal
    let currencyCode: String
    /// `false` until the user explicitly opts out of being part of the split.
    /// Default is `true` — every member is in unless they uncheck themselves
    /// in the split editor.
    let isAccepted: Bool
    let createdAt: Date?
    let updatedAt: Date?
}


// =============================================================================
