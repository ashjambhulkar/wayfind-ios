//
//  CurrencyRateFetchDedupeKey.swift
//  wayfind
//
//  pr-8 — stable key for coalescing concurrent identical FX network fetches
//  in `CurrencyService` (same base ISO, calendar date key, same symbol set).
//

import Foundation

enum CurrencyRateFetchDedupeKey {
    /// Canonical key: `BASE|yyyy-MM-dd|SYM1,SYM2,...` (symbols sorted, uppercased).
    static func make(base: String, symbols: [String], dateKey: String) -> String {
        let baseUpper = base.uppercased()
        let sortedSymbols = symbols.map { $0.uppercased() }.sorted().joined(separator: ",")
        return "\(baseUpper)|\(dateKey)|\(sortedSymbols)"
    }
}


// =============================================================================
