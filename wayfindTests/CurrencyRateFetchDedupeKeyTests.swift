//
//  CurrencyRateFetchDedupeKeyTests.swift
//  wayfindTests
//

import XCTest
@testable import wayfind

final class CurrencyRateFetchDedupeKeyTests: XCTestCase {

    func testDedupeKeySortsSymbolsSoOrderDoesNotMatter() {
        let a = CurrencyRateFetchDedupeKey.make(
            base: "eur",
            symbols: ["USD", "jpy"],
            dateKey: "2024-06-01"
        )
        let b = CurrencyRateFetchDedupeKey.make(
            base: "EUR",
            symbols: ["JPY", "USD"],
            dateKey: "2024-06-01"
        )
        XCTAssertEqual(a, b)
    }

    func testDedupeKeyChangesWhenDateChanges() {
        let a = CurrencyRateFetchDedupeKey.make(base: "USD", symbols: ["EUR"], dateKey: "2024-06-01")
        let b = CurrencyRateFetchDedupeKey.make(base: "USD", symbols: ["EUR"], dateKey: "2024-06-02")
        XCTAssertNotEqual(a, b)
    }
}


// =============================================================================
