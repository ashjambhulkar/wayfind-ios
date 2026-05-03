//
//  BudgetCurrencyProductPolicyTests.swift
//  wayfindTests
//

import XCTest
@testable import wayfind

final class BudgetCurrencyProductPolicyTests: XCTestCase {

    func testNormalizedTripBudgetCurrencyTrimsAndUppercases() {
        XCTAssertEqual(BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(" eur "), "EUR")
    }

    func testNormalizedTripBudgetCurrencyEmptyFallsBackToUSD() {
        XCTAssertEqual(BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(""), "USD")
        XCTAssertEqual(BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode("   "), "USD")
    }

    func testPersonalDisplayCurrencyPrefersProfileWhenValid() {
        let code = BudgetCurrencyProductPolicy.personalDisplayCurrencyCode(
            preferredFromProfile: "gbp",
            localeCurrencyCode: "JPY"
        )
        XCTAssertEqual(code, "GBP")
    }

    func testPersonalDisplayCurrencyFallsBackToLocaleWhenProfileEmpty() {
        let code = BudgetCurrencyProductPolicy.personalDisplayCurrencyCode(
            preferredFromProfile: nil,
            localeCurrencyCode: "cad"
        )
        XCTAssertEqual(code, "CAD")
    }

    func testPersonalDisplayCurrencyFallsBackToLocaleWhenProfileWhitespace() {
        let code = BudgetCurrencyProductPolicy.personalDisplayCurrencyCode(
            preferredFromProfile: "   ",
            localeCurrencyCode: "CHF"
        )
        XCTAssertEqual(code, "CHF")
    }

    func testPersonalDisplayCurrencyUSDWhenBothMissing() {
        let code = BudgetCurrencyProductPolicy.personalDisplayCurrencyCode(
            preferredFromProfile: nil,
            localeCurrencyCode: nil
        )
        XCTAssertEqual(code, "USD")
    }

    func testSettlementAndProFlagsDocumentContract() {
        XCTAssertTrue(
            BudgetCurrencyProductPolicy.settlementsArePerCurrencyOnly,
            "Settlements must stay per-currency until an explicit product adds cross-currency netting."
        )
        XCTAssertTrue(
            BudgetCurrencyProductPolicy.proFeatureTripVersusPersonalHeaderToggle,
            "Header toggle remains Pro-gated; flip only with paywall + copy updates."
        )
    }
}


// =============================================================================
