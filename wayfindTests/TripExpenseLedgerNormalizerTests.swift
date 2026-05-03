//
//  TripExpenseLedgerNormalizerTests.swift
//  wayfindTests
//

import XCTest
@testable import wayfind

final class TripExpenseLedgerNormalizerTests: XCTestCase {

    func testSameCurrencyUsesMultiplierOne() {
        let out = TripExpenseLedgerNormalizer.tripLedgerAmount(
            originalAmount: Decimal(string: "42.12")!,
            originalCurrencyUppercased: "USD",
            tripBudgetCurrencyUppercased: "USD",
            tripUnitsPerOneOriginal: Decimal(string: "99.99")!
        )
        XCTAssertEqual(out.tripAmount, Decimal(string: "42.12")!)
        XCTAssertEqual(out.fxRate, 1)
    }

    func testCrossCurrencyMultipliesAndRoundsMoney() {
        let out = TripExpenseLedgerNormalizer.tripLedgerAmount(
            originalAmount: Decimal(100),
            originalCurrencyUppercased: "EUR",
            tripBudgetCurrencyUppercased: "USD",
            tripUnitsPerOneOriginal: Decimal(string: "1.1")!
        )
        XCTAssertEqual(out.tripAmount, Decimal(string: "110.00")!)
        XCTAssertGreaterThan(out.fxRate, 0)
    }

    func testNegativeOriginalTreatedAsZero() {
        let out = TripExpenseLedgerNormalizer.tripLedgerAmount(
            originalAmount: Decimal(-5),
            originalCurrencyUppercased: "EUR",
            tripBudgetCurrencyUppercased: "USD",
            tripUnitsPerOneOriginal: Decimal(2)
        )
        XCTAssertEqual(out.tripAmount, 0)
        XCTAssertEqual(out.fxRate, 1)
    }

    func testConvertSplitsPreservesTripTotalWithRounding() {
        let tripId = UUID()
        let expId = UUID()
        let splits = [
            ExpenseSplit(id: UUID(), expenseId: expId, tripId: tripId, userId: UUID(), amount: Decimal(string: "33.33")!, currencyCode: "USD", isAccepted: true, createdAt: nil, updatedAt: nil),
            ExpenseSplit(id: UUID(), expenseId: expId, tripId: tripId, userId: UUID(), amount: Decimal(string: "33.33")!, currencyCode: "USD", isAccepted: true, createdAt: nil, updatedAt: nil),
            ExpenseSplit(id: UUID(), expenseId: expId, tripId: tripId, userId: UUID(), amount: Decimal(string: "33.34")!, currencyCode: "USD", isAccepted: true, createdAt: nil, updatedAt: nil),
        ]
        let converted = TripExpenseLedgerNormalizer.convertSplitsToTripCurrency(
            splits: splits,
            originalExpenseTotal: Decimal(100),
            tripExpenseTotal: Decimal(string: "110.00")!,
            tripCurrencyCode: "EUR"
        )
        XCTAssertTrue(converted.allSatisfy { $0.currencyCode == "EUR" })
        let sum = converted.reduce(Decimal(0)) { $0 + $1.amount }
        XCTAssertEqual(sum, Decimal(string: "110.00")!)
    }

    func testConvertSplitsTwoPartyUnevenSharesSumToTripTotal() {
        let tripId = UUID()
        let expId = UUID()
        let splits = [
            ExpenseSplit(
                id: UUID(),
                expenseId: expId,
                tripId: tripId,
                userId: UUID(),
                amount: Decimal(string: "33.34")!,
                currencyCode: "USD",
                isAccepted: true,
                createdAt: nil,
                updatedAt: nil
            ),
            ExpenseSplit(
                id: UUID(),
                expenseId: expId,
                tripId: tripId,
                userId: UUID(),
                amount: Decimal(string: "66.66")!,
                currencyCode: "USD",
                isAccepted: true,
                createdAt: nil,
                updatedAt: nil
            ),
        ]
        let converted = TripExpenseLedgerNormalizer.convertSplitsToTripCurrency(
            splits: splits,
            originalExpenseTotal: Decimal(string: "100.00")!,
            tripExpenseTotal: Decimal(string: "87.50")!,
            tripCurrencyCode: "EUR"
        )
        let sum = converted.reduce(Decimal(0)) { $0 + $1.amount }
        XCTAssertEqual(sum, Decimal(string: "87.50")!)
        XCTAssertTrue(converted.allSatisfy { $0.currencyCode == "EUR" })
    }

    func testConvertSplitsWhenOriginalTotalZeroReturnsRoundedInputs() {
        let tripId = UUID()
        let expId = UUID()
        let splits = [
            ExpenseSplit(id: UUID(), expenseId: expId, tripId: tripId, userId: UUID(), amount: 5, currencyCode: "USD", isAccepted: true, createdAt: nil, updatedAt: nil),
        ]
        let converted = TripExpenseLedgerNormalizer.convertSplitsToTripCurrency(
            splits: splits,
            originalExpenseTotal: 0,
            tripExpenseTotal: 10,
            tripCurrencyCode: "EUR"
        )
        XCTAssertEqual(converted.first?.currencyCode, "EUR")
        XCTAssertEqual(converted.first?.amount, Decimal(string: "5.00")!)
    }
}


// =============================================================================
