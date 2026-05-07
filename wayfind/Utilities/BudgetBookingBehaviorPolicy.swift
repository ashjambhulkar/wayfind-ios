//
//  BudgetBookingBehaviorPolicy.swift
//  wayfind
//
//  Single authoritative source for every invariant that governs how budget
//  entries and bookings relate to each other. Reference this file — not
//  scattered comments — whenever implementing or reviewing budget/booking
//  write paths.
//
//  Decision log
//  ────────────
//  • Two-way sync:        Approved. Editing a linked budget amount writes back
//                         to `trip_bookings.amount` so both screens stay in sync.
//  • Combined-flight row: One budget row per itinerary (return + connectors),
//                         keyed by `booking_group_id`. Amount = sum of all legs.
//  • Delete booking:      Linked expense's `booking_id` becomes NULL (DB FK
//                         SET NULL). The expense survives as orphaned spend
//                         history. No auto-delete of the budget row.
//  • Clear amount:        Booking `amount` set to 0/nil → linked expense NOT
//                         auto-deleted; row transitions to "Needs amount" state.
//  • Canonical writer:    DB trigger `tg_sync_booking_expense` is the sole
//                         booking→budget writer for auto-synced rows.
//                         iOS companion `trackBookingExpenseIfNeeded` must skip
//                         rows already owned by the trigger (isAutoSynced=true).
//

import Foundation

enum BudgetBookingBehaviorPolicy {

    // MARK: - Sync direction

    /// `true` — edits to a linked expense amount propagate back to
    /// `trip_bookings.amount`. The DB trigger handles the reverse
    /// (booking→expense); iOS handles the forward (expense→booking).
    static let twoWaySyncEnabled = true

    /// Suppress window (seconds) after an explicit mutation reload.
    /// Realtime echoes arriving inside this window are dropped to prevent
    /// the double-fetch that occurs on every write.
    static let mutationReloadSuppressWindowSeconds: TimeInterval = 1.5

    // MARK: - Flight grouping

    /// Combined single-budget-row policy for multi-leg/return itineraries.
    /// When `true`, all flight bookings sharing a `booking_group_id` are
    /// represented by one `trip_expenses` row whose amount = sum of legs.
    static let combinedFlightRowEnabled = true

    // MARK: - Linked row lifecycle

    /// When a booking is deleted, the linked expense's `booking_id` is set
    /// to NULL (FK ON DELETE SET NULL). The expense is preserved as orphaned
    /// spend history — not hard-deleted.
    static let deletedBookingOrphansExpense = true

    /// When a booking's amount is cleared (set to 0 or nil), the linked
    /// expense is NOT auto-deleted. Instead it transitions to a "Needs amount"
    /// state visible in the budget list until the user resolves it.
    static let clearedBookingAmountKeepsExpenseRow = true

    // MARK: - Edit authority

    /// `true` — the DB trigger is the sole writer for `isAutoSynced = true`
    /// expense rows. The iOS companion path must check this flag and skip
    /// those rows to avoid double-writes and flag corruption.
    static let dbTriggerOwnedRowsBlockIOSCompanionWrite = true

    // MARK: - User-facing copy helpers

    static func provenanceBadgeLabel(for provenance: TripExpense.Provenance) -> String {
        switch provenance {
        case .bookingLinked:    return String(localized: "Linked")
        case .combinedFlight:   return String(localized: "Combined")
        case .manual:           return ""
        }
    }

    static func editSheetNotice(for provenance: TripExpense.Provenance) -> String? {
        switch provenance {
        case .bookingLinked:
            return String(localized: "Changes to amount also update the linked booking.")
        case .combinedFlight:
            return String(localized: "Changes to amount update all legs in this flight itinerary.")
        case .manual:
            return nil
        }
    }

    static func deleteConfirmationNote(for provenance: TripExpense.Provenance) -> String {
        switch provenance {
        case .bookingLinked:
            return String(localized: "The linked booking will keep its cost, but the budget row won't track it anymore.")
        case .combinedFlight:
            return String(localized: "The linked flight bookings will keep their costs, but the combined budget row will be removed.")
        case .manual:
            return String(localized: "This can't be undone.")
        }
    }
}
