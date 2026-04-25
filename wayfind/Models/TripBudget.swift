//
//  TripBudget.swift
//  wayfind
//
//  One row in `trip_budgets` — the planned spend for a single category. The
//  database has a `spent_amount` column too, but the iOS budget feature
//  intentionally treats `trip_expenses` as the single source of truth and
//  computes spent on demand. We never read or write `spent_amount` from
//  iOS — the column is left for legacy compatibility only.
//

import Foundation

struct TripBudget: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let userId: UUID
    let category: ExpenseCategory
    let plannedAmount: Decimal
    let currencyCode: String
    let createdAt: Date?
    let updatedAt: Date?
}


// =============================================================================
