//
//  OpeningHoursOpenEvaluator.swift
//  wayfind
//
//  Best-effort “open now?” from Serp/Google-style hour strings in the venue’s
//  local timezone (e.g. "12–8 PM", "10:30 AM–8 PM", comma-separated ranges).
//

import Foundation

enum OpeningHoursOpenEvaluator {

    /// Returns `nil` when the string cannot be interpreted as a same-day schedule.
    static func isOpen(hoursText: String, at now: Date, timeZone: TimeZone) -> Bool? {
        let trimmed = hoursText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let folded = trimmed.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let lower = folded.lowercased()

        if lower == "closed" {
            return false
        }
        if lower.contains("24") && (lower.contains("hour") || lower.contains("hr")) {
            return true
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: now)

        let segments = lower
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "closed" }

        var intervals: [(Date, Date)] = []
        for seg in segments {
            guard let pair = splitRangePair(seg),
                  let interval = makeInterval(left: pair.0, right: pair.1, dayStart: dayStart, calendar: calendar) else {
                continue
            }
            intervals.append(interval)
        }

        guard !intervals.isEmpty else { return nil }

        return intervals.contains { now >= $0.0 && now <= $0.1 }
    }

    // MARK: - Range split

    private static func splitRangePair(_ segment: String) -> (String, String)? {
        let delimiters = [" – ", " — ", " - ", "–", "—", "-"]
        for d in delimiters {
            let parts = segment.components(separatedBy: d)
            if parts.count >= 2 {
                let left = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = parts.dropFirst().joined(separator: d).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty, !right.isEmpty { return (left, right) }
            }
        }
        return nil
    }

    private static func makeInterval(left rawLeft: String, right: String, dayStart: Date, calendar: Calendar) -> (Date, Date)? {
        let rawLower = rawLeft.lowercased()
        let leftHadMeridiem = rawLower.contains("am") || rawLower.contains("pm")
        let (lPm, rStr) = inferMeridiems(left: rawLeft, right: right)

        if let pair = buildIntervalPair(startToken: lPm, endToken: rStr, dayStart: dayStart, calendar: calendar) {
            let hrs = pair.1.timeIntervalSince(pair.0) / 3600.0
            if leftHadMeridiem || hrs <= 12 {
                return pair
            }
        }

        if !leftHadMeridiem {
            let amTry = rawLeft.trimmingCharacters(in: .whitespacesAndNewlines) + " AM"
            if let pair = buildIntervalPair(startToken: amTry, endToken: rStr, dayStart: dayStart, calendar: calendar) {
                return pair
            }
        }
        return nil
    }

    private static func buildIntervalPair(startToken: String, endToken: String, dayStart: Date, calendar: Calendar) -> (Date, Date)? {
        guard let start = parseTime(startToken, on: dayStart, calendar: calendar),
              var end = parseTime(endToken, on: dayStart, calendar: calendar) else { return nil }

        if end <= start {
            guard let endNext = calendar.date(byAdding: .day, value: 1, to: end) else { return nil }
            end = endNext
        }

        let hours = end.timeIntervalSince(start) / 3600.0
        if hours > 22 {
            return nil
        }
        return (start, end)
    }

    /// If the left token omits AM/PM, infer from the right (e.g. `12–8 PM` → noon–8 PM).
    private static func inferMeridiems(left: String, right: String) -> (String, String) {
        var l = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        let lLower = l.lowercased()
        let rLower = r.lowercased()
        let lHasMer = lLower.contains("am") || lLower.contains("pm")
        let rHasPm = rLower.contains("pm")
        let rHasAm = rLower.contains("am")

        if !lHasMer {
            if rHasPm {
                l = l + " PM"
            } else if rHasAm {
                l = l + " AM"
            }
        }
        return (l, r)
    }

    // MARK: - Time parse

    private static func parseTime(_ token: String, on dayStart: Date, calendar: Calendar) -> Date? {
        var core = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if core.isEmpty { return nil }

        var isPM = false
        var has12h = false
        if core.hasSuffix("am") {
            core = String(core.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            isPM = false
            has12h = true
        } else if core.hasSuffix("pm") {
            core = String(core.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            isPM = true
            has12h = true
        }

        let parts = core.split(separator: ":")
        guard let hRaw = parts.first, let h12 = Int(hRaw.trimmingCharacters(in: .whitespaces)) else { return nil }
        let minute: Int = {
            guard parts.count >= 2 else { return 0 }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }()
        guard h12 >= 0, h12 <= 23, minute >= 0, minute <= 59 else { return nil }

        let hour24: Int
        if has12h {
            if h12 == 12 {
                hour24 = isPM ? 12 : 0
            } else {
                hour24 = isPM ? h12 + 12 : h12
            }
        } else {
            hour24 = h12
        }

        return calendar.date(bySettingHour: hour24, minute: minute, second: 0, of: dayStart)
    }
}
