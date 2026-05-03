//
//  BudgetFxTelemetryTests.swift
//  wayfindTests
//

import XCTest
@testable import wayfind

final class BudgetFxTelemetryTests: XCTestCase {

    func testTelemetrySmokeDoesNotTrap() {
        BudgetFxTelemetry.recordCacheHit(
            layer: .memory,
            base: "USD",
            quoteDate: "2024-01-02",
            symbolsCount: 2
        )
        BudgetFxTelemetry.recordNetworkFetchSuccess(
            day: .today,
            provider: .frankfurter,
            latencyMs: 42,
            base: "EUR",
            quoteDate: "2024-01-02",
            symbolsCount: 1,
            succeededOnAttempt: 1,
            frankfurterHadPayloadBeforeEdge: false
        )
        BudgetFxTelemetry.recordFetchFallback(
            kind: .networkTodayToYesterday,
            base: "GBP",
            quoteDate: "2024-01-01",
            symbolsCount: 1
        )
        BudgetFxTelemetry.recordSaveBlocked(
            supportReference: "A1B2C3D4",
            base: "JPY",
            quoteDate: "2024-03-10",
            symbolsCount: 1
        )
    }
}


// =============================================================================
