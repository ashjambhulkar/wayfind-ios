//
//  BudgetExpenseMockRoundTripTests.swift
//  wayfindTests
//
//  pr-10 — Client-side “integration” path through `MockDataService` budget
//  mutations (same normalization surface as live `BudgetService` / DataService
//  without Supabase). Live Supabase round-trips belong in CI with secrets;
//  these catch regressions in mock FX + ledger math.
//

import XCTest
@testable import wayfind

final class BudgetExpenseMockRoundTripTests: XCTestCase {

    private let tripId = UUID()
    private let userId = UUID()

    func testAddMixedCurrencyExpenseNormalizesToTripCap() async throws {
        let mock = MockDataService()
        let expense = makeComposerExpense(amount: 100, currency: "EUR")
        let split = ExpenseSplit(
            id: UUID(),
            expenseId: expense.id,
            tripId: tripId,
            userId: userId,
            amount: 100,
            currencyCode: "EUR",
            isAccepted: true,
            createdAt: nil,
            updatedAt: nil
        )
        let saved = try await mock.addExpense(expense, splits: [split], tripBudgetCurrency: "USD")
        let mockMult = AppConfig.mockBudgetForeignToTripLedgerMultiplier
        let expected = TripExpenseLedgerNormalizer.tripLedgerAmount(
            originalAmount: 100,
            originalCurrencyUppercased: "EUR",
            tripBudgetCurrencyUppercased: "USD",
            tripUnitsPerOneOriginal: mockMult
        )
        XCTAssertEqual(saved.currencyCode, "USD")
        XCTAssertEqual(saved.originalCurrencyCode, "EUR")
        XCTAssertEqual(saved.originalAmount, 100)
        XCTAssertEqual(saved.amount, expected.tripAmount)
        XCTAssertEqual(saved.fxRateAtCapture, expected.fxRate)

        let snap = await mock.fetchBudgetSnapshot(tripId: tripId)
        XCTAssertEqual(snap.expenses.count, 1)
        XCTAssertEqual(snap.expenses.first?.id, saved.id)
        XCTAssertEqual(snap.splits.count, 1)
        XCTAssertEqual(snap.splits.first?.currencyCode, "USD")
    }

    func testAddSameCurrencyExpenseUsesUnitRate() async throws {
        let mock = MockDataService()
        let expense = makeComposerExpense(amount: 42.5, currency: "usd")
        let split = ExpenseSplit(
            id: UUID(),
            expenseId: expense.id,
            tripId: tripId,
            userId: userId,
            amount: 42.5,
            currencyCode: "USD",
            isAccepted: true,
            createdAt: nil,
            updatedAt: nil
        )
        let saved = try await mock.addExpense(expense, splits: [split], tripBudgetCurrency: "USD")
        XCTAssertEqual(saved.currencyCode, "USD")
        XCTAssertEqual(saved.originalCurrencyCode, "USD")
        XCTAssertEqual(saved.amount, Decimal(string: "42.50"))
        XCTAssertEqual(saved.fxRateAtCapture, 1)
    }

    func testUpdateExpensePreservesLockedFxWhenAmountChangesSameDay() async throws {
        let mock = MockDataService()
        let day = ExpenseDateFormatter.parse("2024-08-20")!
        let expense = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Train",
            amount: 100,
            currencyCode: "EUR",
            category: .transport,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        let split = ExpenseSplit(
            id: UUID(),
            expenseId: expense.id,
            tripId: tripId,
            userId: userId,
            amount: 100,
            currencyCode: "EUR",
            isAccepted: true,
            createdAt: nil,
            updatedAt: nil
        )
        let persisted = try await mock.addExpense(expense, splits: [split], tripBudgetCurrency: "USD")
        let mockMult = AppConfig.mockBudgetForeignToTripLedgerMultiplier
        let expectedLocked = TripExpenseLedgerNormalizer.tripLedgerAmount(
            originalAmount: 100,
            originalCurrencyUppercased: "EUR",
            tripBudgetCurrencyUppercased: "USD",
            tripUnitsPerOneOriginal: mockMult
        )
        XCTAssertEqual(persisted.fxRateAtCapture, expectedLocked.fxRate)

        let editedComposer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Train updated",
            amount: 200,
            currencyCode: "EUR",
            category: .transport,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: persisted.createdAt,
            updatedAt: nil
        )
        let editedSplit = ExpenseSplit(
            id: split.id,
            expenseId: persisted.id,
            tripId: tripId,
            userId: userId,
            amount: 200,
            currencyCode: "EUR",
            isAccepted: true,
            createdAt: nil,
            updatedAt: nil
        )
        try await mock.updateExpense(
            editedComposer,
            splits: [editedSplit],
            tripBudgetCurrency: "USD",
            previousPersistedRow: persisted
        )
        let snap = await mock.fetchBudgetSnapshot(tripId: tripId)
        let row = try XCTUnwrap(snap.expenses.first)
        let expectedTripAfterEdit = TripExpenseLedgerNormalizer.roundMoney2(
            200 * expectedLocked.fxRate
        )
        XCTAssertEqual(row.originalAmount, 200)
        XCTAssertEqual(row.fxRateAtCapture, expectedLocked.fxRate)
        XCTAssertEqual(row.amount, expectedTripAfterEdit)
    }

    private func makeComposerExpense(amount: Decimal, currency: String) -> TripExpense {
        TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Meal",
            amount: amount,
            currencyCode: currency,
            category: .food,
            splitType: .full,
            expenseDate: Date(),
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
    }
}


// =============================================================================
