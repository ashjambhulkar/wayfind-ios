//
//  AirportIATA.swift
//  wayfind
//
//  Validates and normalises IATA airport codes (three uppercase ASCII letters).
//

import Foundation

enum AirportIATA {
    private static let pattern = try! NSRegularExpression(pattern: "^[A-Z]{3}$")

    /// Returns the canonical (uppercased, trimmed) IATA code if `raw` is a valid
    /// three-letter airport code; otherwise `nil`.
    static func normalise(_ raw: String) -> String? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = NSRange(candidate.startIndex..., in: candidate)
        guard pattern.firstMatch(in: candidate, range: range) != nil else { return nil }
        return candidate
    }

    /// Returns `true` when `raw` is a valid IATA airport code.
    static func isValid(_ raw: String) -> Bool {
        normalise(raw) != nil
    }
}
