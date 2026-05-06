//
//  AirportTimezones.swift
//  wayfind
//
//  Static IATA → IANA timezone lookup backed by `airport-timezones.json`
//  (bundled resource, sourced from mwgg/Airports curated snapshot).
//
//  Usage:
//    let tz = AirportTimezones.timeZone(forIATA: "JFK")   // America/New_York
//    let tz = AirportTimezones.timeZone(forIATA: "jfk")   // same — normalised
//    let tz = AirportTimezones.timeZone(forIATA: "XYZ")   // nil — unknown
//

import Foundation

enum AirportTimezones {
    // Populated once on first access; guarded against concurrent initialisers.
    private static let table: [String: String] = loadTable()

    private static func loadTable() -> [String: String] {
        guard
            let url = Bundle.main.url(forResource: "airport-timezones", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            assertionFailure("airport-timezones.json missing from bundle")
            return [:]
        }
        return dict
    }

    /// Returns the IANA timezone for the given IATA airport code, or `nil`
    /// when the code is unknown or invalid. Case-insensitive.
    static func timeZone(forIATA raw: String) -> TimeZone? {
        guard let code = AirportIATA.normalise(raw) else { return nil }
        guard let identifier = table[code] else { return nil }
        return TimeZone(identifier: identifier)
    }

    /// Returns the IANA identifier string for the given IATA code, or `nil`.
    static func identifier(forIATA raw: String) -> String? {
        guard let code = AirportIATA.normalise(raw) else { return nil }
        return table[code]
    }
}
