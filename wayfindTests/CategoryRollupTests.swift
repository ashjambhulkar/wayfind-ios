//
//  CategoryRollupTests.swift
//  wayfindTests
//
//  Phase 10 — Verifies that `CategoryRollup.compute` keeps Decimal precision
//  intact across additions and that per-currency segregation never collapses
//  mixed-currency totals into a single bucket. These are the foundational
//  invariants the BudgetSummaryCard + CategoryBudgetSection rely on; if they
//  drift, the summary card lies to the user.
//
//  We use `Decimal(string:)` literals throughout because `Decimal(0.1)` goes
//  through Double and silently introduces 1e-17 drift — the very thing the
//  production code is structured to avoid.
//

import XCTest
@testable import wayfind

final class CategoryRollupTests: XCTestCase {
    private let trip = UUID()
    private let alice = UUID()

    func testEmptySnapshotProducesEmptyRollup() {
        let rollup = CategoryRollup.compute(from: [])
        XCTAssertTrue(rollup.totalsByCurrency.isEmpty)
        XCTAssertTrue(rollup.perCategoryByCurrency.isEmpty)
        XCTAssertTrue(rollup.currencies.isEmpty)
        XCTAssertFalse(rollup.isMixedCurrency)
    }

    /// $33.33 + $33.33 + $33.34 = $100.00 exactly. The classic three-way
    /// split that exposes Double drift if Decimal isn't held end-to-end.
    func testThreeWayEqualSplitPrecision() {
        let expenses: [TripExpense] = [
            makeExpense(amount: Decimal(string: "33.33")!, category: .food),
            makeExpense(amount: Decimal(string: "33.33")!, category: .food),
            makeExpense(amount: Decimal(string: "33.34")!, category: .food),
        ]
        let rollup = CategoryRollup.compute(from: expenses)
        XCTAssertEqual(rollup.total(for: "USD"), Decimal(string: "100.00"))
        XCTAssertEqual(rollup.amount(for: "USD", category: .food), Decimal(string: "100.00"))
    }

    /// Two currencies should never net into one number — caller renders a
    /// mixed-currency banner instead of fake conversion.
    func testMixedCurrencyKeepsBucketsSeparate() {
        let expenses: [TripExpense] = [
            makeExpense(amount: 200, currency: "USD", category: .lodging),
            makeExpense(amount: 150, currency: "EUR", category: .food),
            makeExpense(amount: 50, currency: "USD", category: .food),
        ]
        let rollup = CategoryRollup.compute(from: expenses)
        XCTAssertEqual(rollup.total(for: "USD"), Decimal(250))
        XCTAssertEqual(rollup.total(for: "EUR"), Decimal(150))
        XCTAssertEqual(rollup.amount(for: "USD", category: .lodging), Decimal(200))
        XCTAssertEqual(rollup.amount(for: "USD", category: .food), Decimal(50))
        XCTAssertEqual(rollup.amount(for: "EUR", category: .food), Decimal(150))
        XCTAssertTrue(rollup.isMixedCurrency)
        XCTAssertEqual(rollup.currencies, ["USD", "EUR"])
    }

    /// Currency codes are normalised to uppercase so the lookup keys match
    /// the trip currency in `BudgetViewModel` (which also uppercases).
    func testCurrencyCodesAreUppercased() {
        let expenses: [TripExpense] = [
            makeExpense(amount: 10, currency: "usd", category: .other),
            makeExpense(amount: 20, currency: "USD", category: .other),
        ]
        let rollup = CategoryRollup.compute(from: expenses)
        XCTAssertEqual(rollup.total(for: "USD"), Decimal(30))
        XCTAssertEqual(rollup.total(for: "usd"), Decimal(30))
        XCTAssertEqual(rollup.currencies, ["USD"])
    }

    /// Many small additions must not introduce drift — guard against any
    /// future refactor that swaps Decimal for Double under the hood.
    func testLargeNumberOfSmallAmountsHoldsPrecision() {
        let expenses = (1...100).map { _ in
            makeExpense(amount: Decimal(string: "0.01")!, category: .food)
        }
        let rollup = CategoryRollup.compute(from: expenses)
        XCTAssertEqual(rollup.total(for: "USD"), Decimal(string: "1.00"))
    }

    // MARK: - Helpers

    private func makeExpense(
        amount: Decimal,
        currency: String = "USD",
        category: ExpenseCategory
    ) -> TripExpense {
        TripExpense(
            id: UUID(),
            tripId: trip,
            userId: alice,
            payerUserId: alice,
            bookingId: nil,
            title: "test",
            amount: amount,
            currencyCode: currency,
            category: category,
            splitType: .equal,
            expenseDate: Date(),
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
    }
}
