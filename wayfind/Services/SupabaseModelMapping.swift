import Foundation

/// Shared date + lifecycle helpers for mapping Supabase rows to native `Trip` / day models.
enum SupabaseModelMapping {
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let postgresTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func calendarDateOnlyString(from date: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date)
        return dateOnlyFormatter.string(from: start)
    }

    static func enumerateCalendarDateOnlyStrings(from start: Date, through end: Date, calendar: Calendar = .current) -> [String] {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay else { return [] }
        var dates: [String] = []
        var cursor = startDay
        while cursor <= endDay {
            dates.append(dateOnlyFormatter.string(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    static func addCalendarDaysString(_ isoDate: String, offsetDays: Int, calendar: Calendar = .current) -> String {
        guard let base = dateOnlyFormatter.date(from: String(isoDate.prefix(10))) else { return isoDate }
        let shifted = calendar.date(byAdding: .day, value: offsetDays, to: base) ?? base
        return dateOnlyFormatter.string(from: shifted)
    }

    static func parseDateOnly(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return dateOnlyFormatter.date(from: String(value.prefix(10)))
    }

    static func parsePostgresTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = postgresTimestampFormatter.date(from: value) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    /// Maps Expo `inferTripStatus` (`utils/dateHelpers.ts`) to DB `trips.status`.
    static func inferTripStatus(startDate: Date?, endDate: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let startDate, let endDate else { return "planned" }
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        if today < start { return "planned" }
        if today > end { return "completed" }
        return "active"
    }

    static func isTripActive(startDate: Date?, endDate: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        inferTripStatus(startDate: startDate, endDate: endDate, now: now, calendar: calendar) == "active"
    }
}

