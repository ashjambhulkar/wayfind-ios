//
//  DateHelpers.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation

private enum DateFormatters {
    static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static let weekdayFull: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static let weekdayShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static let monthDayYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()
}

extension Date {
    var shortFormatted: String {
        DateFormatters.short.string(from: self)
    }

    func shortFormatted(timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        return f.string(from: self)
    }

    /// Note list footer: Today / Yesterday / MMM d (this year) / MMM d, yyyy.
    var noteListCaption: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            return String(localized: "Today")
        }
        if cal.isDateInYesterday(self) {
            return String(localized: "Yesterday")
        }
        if cal.component(.year, from: self) == cal.component(.year, from: Date()) {
            return DateFormatters.short.string(from: self)
        }
        return DateFormatters.monthDayYear.string(from: self)
    }

    var timeFormatted: String {
        DateFormatters.time.string(from: self)
    }

    func timeFormatted(timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        return f.string(from: self)
    }

    /// Short timezone abbreviation for the given timezone at this instant (e.g. "EDT", "PDT", "MST").
    func timeZoneAbbreviation(timeZone: TimeZone) -> String {
        timeZone.abbreviation(for: self) ?? timeZone.abbreviation() ?? ""
    }

    var dayOfWeekFull: String {
        DateFormatters.weekdayFull.string(from: self)
    }

    var dayOfWeekShort: String {
        DateFormatters.weekdayShort.string(from: self)
    }

    func dayOfWeekShort(timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        return f.string(from: self)
    }

    var relativeDaysText: String {
        let calendar = Calendar.current
        let startSelf = calendar.startOfDay(for: self)
        let startToday = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: startToday, to: startSelf).day ?? 0

        if days == 0 {
            return "Today"
        }
        if days == 1 {
            return "In 1 day"
        }
        if days == -1 {
            return "Yesterday"
        }
        if days > 1 {
            return "In \(days) days"
        }
        return "\(-days) days ago"
    }

    static func daysBetween(from start: Date, to end: Date) -> Int {
        Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// Returns a day-offset suffix label relative to `reference` in their
    /// respective timezones, e.g. `"+1d"`, `"+2d"`, or `nil` when the local
    /// calendar date is the same.
    ///
    /// - Parameters:
    ///   - referenceDate: The "from" instant (departure time in departure TZ).
    ///   - referenceTZ:   Timezone used to determine the reference calendar date.
    ///   - targetTZ:      Timezone used to determine the target (arrival) calendar date.
    static func dayOffsetLabel(from referenceDate: Date, in referenceTZ: TimeZone, to targetDate: Date, in targetTZ: TimeZone) -> String? {
        var refCal = Calendar(identifier: .gregorian)
        refCal.timeZone = referenceTZ
        var tgtCal = Calendar(identifier: .gregorian)
        tgtCal.timeZone = targetTZ

        let refStart = refCal.startOfDay(for: referenceDate)
        let tgtStart = tgtCal.startOfDay(for: targetDate)

        // Compare using a neutral calendar — startOfDay values are midnight UTC-anchored here
        let dayDiff = Calendar.current.dateComponents([.day], from: refStart, to: tgtStart).day ?? 0
        guard dayDiff != 0 else { return nil }
        return dayDiff > 0 ? "+\(dayDiff)d" : "\(dayDiff)d"
    }

    /// Returns a `Date` whose UTC instant is adjusted so that the wall-clock
    /// time in `newTZ` matches what this date displays in `oldTZ`.
    ///
    /// Useful for rebasing a `DatePicker` selection when the user changes an
    /// airport code and the resolved timezone shifts — preserving the typed
    /// wall-clock time while moving the underlying UTC.
    func rebased(from oldTZ: TimeZone, to newTZ: TimeZone) -> Date {
        let delta = TimeInterval(oldTZ.secondsFromGMT(for: self) - newTZ.secondsFromGMT(for: self))
        return addingTimeInterval(delta)
    }
}


// =============================================================================

extension Calendar {
    /// Returns a copy of this calendar with the given timezone applied.
    func with(timeZone tz: TimeZone) -> Calendar {
        var copy = self
        copy.timeZone = tz
        return copy
    }
}

// MARK: - Duration formatting

extension TimeInterval {
    /// Formats a duration in seconds as a compact "Xh Ym" string suitable for
    /// flight layover chips. Examples: "45m", "1h 20m", "14h".
    var compactDurationLabel: String {
        let totalMinutes = Int(self / 60)
        guard totalMinutes > 0 else { return "0m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}

