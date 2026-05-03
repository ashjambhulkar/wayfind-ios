//
//  CurrencyRateAPIContractTests.swift
//  wayfindTests
//
//  pr-10 — Contract tests for FX JSON shapes consumed by `CurrencyService`
//  (Frankfurter direct + `currency-rates` Edge). If these fail, update both
//  the service decoders and fixtures together.
//

import XCTest

final class CurrencyRateAPIContractTests: XCTestCase {

    // MARK: - Frankfurter (api.frankfurter.app)

    func testDecodesFrankfurterDailyRatesPayload() throws {
        let json = """
        {"amount":1.0,"base":"EUR","date":"2024-06-10","rates":{"USD":1.0845,"JPY":168.12}}
        """
        let body = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(FrankfurterRatesBody.self, from: body)
        XCTAssertEqual(decoded.date, "2024-06-10")
        XCTAssertEqual(decoded.rates["USD"], 1.0845)
        XCTAssertEqual(decoded.rates["JPY"], 168.12)
    }

    // MARK: - Edge function `currency-rates`

    func testDecodesCurrencyRatesEdgePayloadWithSource() throws {
        let json = """
        {
          "base": "USD",
          "date": "2026-04-25",
          "rates": {"AED": 3.673, "EUR": 0.92},
          "missing": [],
          "source": {"primary": "frankfurter", "fallback": ["exchangerate.host"]}
        }
        """
        let body = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(CurrencyRatesEdgeBody.self, from: body)
        XCTAssertEqual(decoded.base, "USD")
        XCTAssertEqual(decoded.date, "2026-04-25")
        XCTAssertEqual(decoded.rates["AED"], 3.673)
        XCTAssertEqual(decoded.source?.primary, "frankfurter")
        XCTAssertEqual(decoded.source?.fallback, ["exchangerate.host"])
    }

    func testDecodesCurrencyRatesEdgePayloadWithoutOptionalSource() throws {
        let json = """
        {"base":"GBP","date":"2025-01-01","rates":{"USD":1.27}}
        """
        let body = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(CurrencyRatesEdgeBody.self, from: body)
        XCTAssertNil(decoded.source)
        XCTAssertNil(decoded.missing)
    }
}

// MARK: - Fixture shapes (keep aligned with `CurrencyService` decoders)

private struct FrankfurterRatesBody: Decodable {
    let date: String
    let rates: [String: Double]
}

private struct CurrencyRatesEdgeBody: Decodable {
    struct Source: Decodable {
        let primary: String
        let fallback: [String]
    }

    let base: String
    let date: String
    let rates: [String: Double]
    let missing: [String]?
    let source: Source?
}


// =============================================================================
