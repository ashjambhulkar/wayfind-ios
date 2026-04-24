//
//  PreferredCurrencyFormatting.swift
//  wayfind
//
//  Mirrors Expo `utils/preferredCurrencyCycle.ts` for profile preferred currency.
//

import Foundation

enum PreferredCurrencyFormatting {
    static let codeMaxLength = 3

    /// Preset cycle order (nil = follow trip / device defaults).
    static let presetCycle: [String?] = [nil, "USD", "EUR", "GBP", "CAD", "AUD", "JPY"]

    static func normalizeInput(_ raw: String) -> String? {
        let letters = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        return String(letters.prefix(codeMaxLength))
    }

    static func displayLabel(code: String?) -> String {
        guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Default"
        }
        return code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func nextInCycle(current: String?) -> String? {
        let upper = current?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalized = (upper?.isEmpty == true) ? nil : upper
        let list = presetCycle
        let i = list.firstIndex { element in
            switch (element, normalized) {
            case (nil, nil): return true
            case let (a?, b?): return a == b
            default: return false
            }
        } ?? 0
        let nextIndex = (i + 1) % list.count
        return list[nextIndex]
    }
}


// =============================================================================

