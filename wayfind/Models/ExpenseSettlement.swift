//
//  ExpenseSettlement.swift
//  wayfind
//
//  One row in `expense_settlements`. Append-only: there's no DELETE policy,
//  and "un-settling" a payment isn't supported in the UI either — the user
//  creates a reverse settlement to cancel one out. `settledVia` is intentionally
//  open-ended (`other` bucket) so a future deep-link target — Cash App,
//  Zelle, Wise — can ship without a schema migration.
//

import Foundation

struct ExpenseSettlement: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    /// Whoever owes the money in this row. They press "Settle Up" from their
    /// own device and the matching settlement card appears for the recipient.
    let fromUserId: UUID
    /// Whoever receives the money. They get the activity-feed entry once
    /// `isSettled` flips to `true`.
    let toUserId: UUID
    let amount: Decimal
    let currencyCode: String
    let isSettled: Bool
    let settledAt: Date?
    let settledVia: SettlementMethod?
    let notes: String?
    let createdAt: Date?
    let updatedAt: Date?

    enum SettlementMethod: String, Hashable, Sendable, CaseIterable {
        case cash
        case venmo
        case paypal
        case other

        /// Body-copy label used in the method picker and the settled-row
        /// caption ("Settled via Venmo · Apr 24").
        var displayLabel: String {
            switch self {
            case .cash: return "Cash"
            case .venmo: return "Venmo"
            case .paypal: return "PayPal"
            case .other: return "Other"
            }
        }

        /// SF Symbol shown next to the method label. Apple Pay Cash isn't
        /// represented because Apple has no public P2P deep link scheme; for
        /// in-person cash we use the wallet glyph.
        var systemImage: String {
            switch self {
            case .cash: return "banknote"
            case .venmo: return "v.circle.fill"
            case .paypal: return "p.circle.fill"
            case .other: return "ellipsis.circle"
            }
        }

        static func from(rawValue raw: String?) -> SettlementMethod? {
            guard let raw, !raw.isEmpty else { return nil }
            return SettlementMethod(rawValue: raw.lowercased())
        }
    }
}


// =============================================================================
