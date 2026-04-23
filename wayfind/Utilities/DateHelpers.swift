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
}

extension Date {
    var shortFormatted: String {
        DateFormatters.short.string(from: self)
    }

    var timeFormatted: String {
        DateFormatters.time.string(from: self)
    }

    var dayOfWeekFull: String {
        DateFormatters.weekdayFull.string(from: self)
    }

    var dayOfWeekShort: String {
        DateFormatters.weekdayShort.string(from: self)
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
}

