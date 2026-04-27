//
//  OpeningHoursDisplay.swift
//  wayfind
//
//  Parses `city_places.opening_hours` for PlaceDetailSheet — supports the
//  pooled `{ day, hours }[]` shape and Google-style `{ open_now, weekday_text }`.
//

import Foundation

struct OpeningHoursDisplay: Equatable {
    /// From Google-style payloads only; `nil` means unknown (do not infer).
    let openNow: Bool?
    let rows: [Row]

    struct Row: Identifiable, Equatable {
        /// Lowercase english weekday: `monday` … `sunday`.
        var id: String { dayKey }
        let dayKey: String
        let dayLabel: String
        let hoursText: String
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Short line for the hero clock pill (today’s hours or first row).
    func clockSummaryLine(calendar: Calendar = .current, now: Date = Date()) -> String? {
        if let today = todayRow(calendar: calendar, now: now) {
            return today.hoursText
        }
        return rows.first?.hoursText
    }

    func todayRow(calendar: Calendar = .current, now: Date = Date()) -> Row? {
        let idx = calendar.component(.weekday, from: now) - 1
        guard idx >= 0 && idx < 7 else { return nil }
        let key = Self.weekdayKeysSundayFirst[idx]
        return rows.first { $0.dayKey == key }
    }

    private static let weekdayKeysSundayFirst: [String] = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    private static let mondayFirstOrder: [String] = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    private static func daySortIndex(_ key: String) -> Int {
        mondayFirstOrder.firstIndex(of: key) ?? 99
    }

    private static func titleForDayKey(_ key: String) -> String {
        switch key {
        case "monday": return "Monday"
        case "tuesday": return "Tuesday"
        case "wednesday": return "Wednesday"
        case "thursday": return "Thursday"
        case "friday": return "Friday"
        case "saturday": return "Saturday"
        case "sunday": return "Sunday"
        default: return key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    static func normalizeDayKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lower = trimmed.lowercased().replacingOccurrences(of: ".", with: "")
        switch lower {
        case "mon", "monday": return "monday"
        case "tue", "tues", "tuesday": return "tuesday"
        case "wed", "weds", "wednesday": return "wednesday"
        case "thu", "thur", "thurs", "thursday": return "thursday"
        case "fri", "friday": return "friday"
        case "sat", "saturday": return "saturday"
        case "sun", "sunday": return "sunday"
        default: return nil
        }
    }

    static func sortedRows(_ unsorted: [Row]) -> [Row] {
        unsorted.sorted { daySortIndex($0.dayKey) < daySortIndex($1.dayKey) }
    }

    static func makeRow(dayKey: String, hoursText: String) -> Row {
        Row(dayKey: dayKey, dayLabel: titleForDayKey(dayKey), hoursText: hoursText)
    }
}

// MARK: - Parse

enum OpeningHoursParsing {
    static func display(from value: SupabaseManager.JSONValue?) -> OpeningHoursDisplay? {
        guard let value else { return nil }
        let top: Any?
        switch value {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{") || t.hasPrefix("["),
                  let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            top = obj
        default:
            top = jsonValueToAny(value)
        }

        if let arr = top as? [Any] {
            return parseDayHoursArray(arr)
        }
        if let dict = top as? [String: Any] {
            return parseGoogleStyle(dict)
        }
        return nil
    }

    private static func parseDayHoursArray(_ arr: [Any]) -> OpeningHoursDisplay? {
        var seen: [String: OpeningHoursDisplay.Row] = [:]
        seen.reserveCapacity(7)
        for item in arr {
            guard let obj = item as? [String: Any] else { continue }
            let dayRaw = (obj["day"] as? String) ?? (obj["Day"] as? String) ?? ""
            let hoursRaw = (obj["hours"] as? String) ?? (obj["Hours"] as? String) ?? ""
            let dayKey = OpeningHoursDisplay.normalizeDayKey(dayRaw) ?? ""
            let hours = hoursRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if dayKey.isEmpty || hours.isEmpty { continue }
            seen[dayKey] = OpeningHoursDisplay.makeRow(dayKey: dayKey, hoursText: hours)
        }
        let rows = OpeningHoursDisplay.sortedRows(Array(seen.values))
        guard !rows.isEmpty else { return nil }
        return OpeningHoursDisplay(openNow: nil, rows: rows)
    }

    private static func parseGoogleStyle(_ dict: [String: Any]) -> OpeningHoursDisplay? {
        let openNow = dict["open_now"] as? Bool
        if let wta = dict["weekday_text"] as? [String] {
            var seen: [String: OpeningHoursDisplay.Row] = [:]
            for line in wta {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let parts = trimmed.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2 else { continue }
                guard let dayKey = OpeningHoursDisplay.normalizeDayKey(parts[0]) else { continue }
                let hours = parts[1]
                if hours.isEmpty { continue }
                seen[dayKey] = OpeningHoursDisplay.makeRow(dayKey: dayKey, hoursText: hours)
            }
            let rows = OpeningHoursDisplay.sortedRows(Array(seen.values))
            if !rows.isEmpty {
                return OpeningHoursDisplay(openNow: openNow, rows: rows)
            }
        }
        if let openNow {
            return OpeningHoursDisplay(openNow: openNow, rows: [])
        }
        return nil
    }

    private static func jsonValueToAny(_ value: SupabaseManager.JSONValue) -> Any? {
        switch value {
        case .null:
            return nil
        case .bool(let b):
            return b
        case .number(let n):
            return n
        case .string(let s):
            return s
        case .array(let arr):
            return arr.compactMap { jsonValueToAny($0) }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o {
                guard let nested = jsonValueToAny(v) else { continue }
                out[k] = nested
            }
            return out
        }
    }
}
