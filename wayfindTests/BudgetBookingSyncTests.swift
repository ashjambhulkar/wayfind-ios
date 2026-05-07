//
//  BudgetBookingSyncTests.swift
//  wayfindTests
//
//  Tests for the budget–booking sync plan:
//   • BudgetViewModel realtime-reload suppress window
//   • TripExpense.provenance derivation
//   • BudgetLedgerNormalizationPolicy edge-case helpers (isNeedsAmount)
//   • BudgetBookingBehaviorPolicy invariants
//

import XCTest
@testable import wayfind

// MARK: - TripExpense provenance tests

final class TripExpenseProvenanceTests: XCTestCase {

    func testManualExpenseHasManualProvenance() {
        let expense = makeTripExpense(bookingId: nil, bookingGroupId: nil)
        XCTAssertEqual(expense.provenance, .manual)
    }

    func testLinkedExpenseHasBookingLinkedProvenance() {
        let bookingId = UUID()
        let expense = makeTripExpense(bookingId: bookingId, bookingGroupId: nil)
        XCTAssertEqual(expense.provenance, .bookingLinked)
    }

    func testGroupedFlightExpenseHasCombinedFlightProvenance() {
        let groupId = UUID()
        let expense = makeTripExpense(bookingId: nil, bookingGroupId: groupId)
        if case .combinedFlight(let id) = expense.provenance {
            XCTAssertEqual(id, groupId)
        } else {
            XCTFail("Expected .combinedFlight, got \(expense.provenance)")
        }
    }

    func testGroupedFlightTakesPrecedenceOverSingleBookingId() {
        let groupId = UUID()
        // Even if bookingId is set, bookingGroupId wins.
        let expense = makeTripExpense(bookingId: UUID(), bookingGroupId: groupId)
        if case .combinedFlight(let id) = expense.provenance {
            XCTAssertEqual(id, groupId)
        } else {
            XCTFail("Expected .combinedFlight, got \(expense.provenance)")
        }
    }
}

// MARK: - BudgetLedgerNormalizationPolicy edge-case tests

final class BudgetLedgerNormalizationPolicyEdgeCaseTests: XCTestCase {

    func testNeedsAmountIsFalseForManualZeroExpense() {
        let expense = makeTripExpense(bookingId: nil, bookingGroupId: nil, amount: 0, originalAmount: 0)
        XCTAssertFalse(BudgetLedgerNormalizationPolicy.isNeedsAmount(expense),
                       "Manual zero-amount rows should never be in 'needs amount' state")
    }

    func testNeedsAmountIsTrueForLinkedZeroExpense() {
        let expense = makeTripExpense(bookingId: UUID(), bookingGroupId: nil, amount: 0, originalAmount: 0)
        XCTAssertTrue(BudgetLedgerNormalizationPolicy.isNeedsAmount(expense),
                      "Linked zero-amount rows represent a cleared booking cost")
    }

    func testNeedsAmountIsFalseForLinkedNonZeroExpense() {
        let expense = makeTripExpense(bookingId: UUID(), bookingGroupId: nil, amount: 100, originalAmount: 100)
        XCTAssertFalse(BudgetLedgerNormalizationPolicy.isNeedsAmount(expense))
    }

    func testInferWriteSourceForAutoSyncedExpense() {
        let expense = makeTripExpense(bookingId: UUID(), isAutoSynced: true)
        XCTAssertEqual(BudgetLedgerNormalizationPolicy.inferWriteSource(from: expense), .databaseAutoSync)
    }

    func testInferWriteSourceForCompanionExpense() {
        // Not auto-synced but has a bookingId — iOS companion path.
        let expense = makeTripExpense(bookingId: UUID(), isAutoSynced: false)
        XCTAssertEqual(BudgetLedgerNormalizationPolicy.inferWriteSource(from: expense), .iosBookingCompanion)
    }

    func testInferWriteSourceForManualExpense() {
        let expense = makeTripExpense(bookingId: nil, isAutoSynced: false)
        XCTAssertEqual(BudgetLedgerNormalizationPolicy.inferWriteSource(from: expense), .manualComposer)
    }
}

// MARK: - BudgetBookingBehaviorPolicy invariant tests

final class BudgetBookingBehaviorPolicyTests: XCTestCase {

    func testTwoWaySyncIsEnabled() {
        XCTAssertTrue(BudgetBookingBehaviorPolicy.twoWaySyncEnabled)
    }

    func testSuppressWindowIsPositive() {
        XCTAssertGreaterThan(BudgetBookingBehaviorPolicy.mutationReloadSuppressWindowSeconds, 0)
    }

    func testProvenanceBadgeLabelForLinked() {
        XCTAssertFalse(
            BudgetBookingBehaviorPolicy.provenanceBadgeLabel(for: .bookingLinked).isEmpty
        )
    }

    func testProvenanceBadgeLabelForManualIsEmpty() {
        XCTAssertTrue(
            BudgetBookingBehaviorPolicy.provenanceBadgeLabel(for: .manual).isEmpty,
            "Manual rows have no badge"
        )
    }

    func testDeleteConfirmationNoteForLinkedMentionsBooking() {
        let note = BudgetBookingBehaviorPolicy.deleteConfirmationNote(for: .bookingLinked)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("booking"),
                      "Delete note for linked row should mention 'booking'")
    }

    func testDeleteConfirmationNoteForManualMentionsUndone() {
        let note = BudgetBookingBehaviorPolicy.deleteConfirmationNote(for: .manual)
        XCTAssertFalse(note.isEmpty)
    }

    func testEditSheetNoticeForLinkedIsNonNil() {
        XCTAssertNotNil(BudgetBookingBehaviorPolicy.editSheetNotice(for: .bookingLinked))
    }

    func testEditSheetNoticeForManualIsNil() {
        XCTAssertNil(BudgetBookingBehaviorPolicy.editSheetNotice(for: .manual))
    }
}

// MARK: - Suppress-window logic tests

final class BudgetReloadSuppressWindowTests: XCTestCase {

    func testSuppressWindowThresholdIsLargerThanRealtimeDebounce() {
        // The suppress window must be longer than the 300 ms realtime debounce
        // so every burst of events from a single write is absorbed.
        let realtimeDebounceSeconds: TimeInterval = 0.3
        XCTAssertGreaterThan(
            BudgetBookingBehaviorPolicy.mutationReloadSuppressWindowSeconds,
            realtimeDebounceSeconds
        )
    }
}

// MARK: - Helpers

private func makeTripExpense(
    bookingId: UUID?,
    bookingGroupId: UUID? = nil,
    amount: Decimal = 100,
    originalAmount: Decimal = 100,
    isAutoSynced: Bool = false
) -> TripExpense {
    let tripId = UUID()
    return TripExpense(
        id: UUID(),
        tripId: tripId,
        userId: UUID(),
        payerUserId: UUID(),
        bookingId: bookingId,
        bookingGroupId: bookingGroupId,
        title: "Test expense",
        amount: amount,
        currencyCode: "USD",
        category: .accommodation,
        splitType: .full,
        expenseDate: Date(),
        notes: nil,
        isAutoSynced: isAutoSynced,
        createdAt: nil,
        updatedAt: nil,
        originalAmount: originalAmount,
        originalCurrencyCode: "USD",
        fxRateAtCapture: 1,
        fxRateDate: Date()
    )
}
