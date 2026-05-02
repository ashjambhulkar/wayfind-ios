import Foundation

/// Destination + date lines for profile spotlight (Expo `formatTripDestinationTitle` / `formatTripDateRange`).
enum ProfileTripDisplayFormatting {
    static func destinationTitle(destination: String, tripTitle: String) -> String {
        let raw = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            let n = tripTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? "Trip" : n
        }

        let segments = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if segments.isEmpty {
            let n = tripTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? "Trip" : n
        }

        var deduped: [String] = []
        for s in segments {
            let prev = deduped.last
            if prev == nil || prev!.caseInsensitiveCompare(s) != .orderedSame {
                deduped.append(s)
            }
        }

        if deduped.count == 1 { return deduped[0] }

        let last = deduped[deduped.count - 1]
        let isUSCountry =
            last.caseInsensitiveCompare("USA") == .orderedSame
            || last.range(of: "^United States( of America)?$", options: [.regularExpression, .caseInsensitive]) != nil

        if isUSCountry && deduped.count >= 3 {
            let stateOrRegion = deduped[deduped.count - 2]
            if stateOrRegion.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil {
                return "\(deduped[0]), \(stateOrRegion.uppercased())"
            }
            return "\(deduped[0]), \(stateOrRegion)"
        }

        if isUSCountry && deduped.count == 2 {
            return "\(deduped[0]), USA"
        }

        if deduped.count == 2 {
            return "\(deduped[0]), \(deduped[1])"
        }

        return "\(deduped[0]), \(last)"
    }

    static func dateRangeLine(start: Date, end: Date, calendar: Calendar = .current) -> String {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        if startDay == endDay {
            return Self.mediumDateNoYear(start)
        }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if sameYear {
            return "\(Self.monthDay(start)) – \(Self.monthDayYear(end))"
        }
        return "\(Self.monthDayYear(start)) – \(Self.monthDayYear(end))"
    }

    private static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: date)
    }

    private static func monthDayYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return f.string(from: date)
    }

    private static func mediumDateNoYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}


// =============================================================================

