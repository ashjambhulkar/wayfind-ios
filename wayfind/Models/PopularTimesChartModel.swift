//
//  PopularTimesChartModel.swift
//  wayfind
//
//  Parses `city_places.popular_times` (graph_results + current_day) for
//  PlaceDetailSheet — shape matches Serp/Google-style hourly busyness.
//

import Foundation
import SwiftUI

// MARK: - Model

struct PopularTimesChartModel: Equatable {
    let currentDayKey: String?
    let days: [PopularTimesDayColumn]

    func column(forDayId id: String) -> PopularTimesDayColumn? {
        days.first { $0.id == id }
    }

    /// Prefer server `current_day`, else today's weekday if present in data, else first column.
    func preferredDayKey(referenceDate: Date = Date(), calendar: Calendar = .current) -> String {
        let orderedKeys = Self.weekdayKeysSundayFirst
        let todayIdx = max(0, min(6, calendar.component(.weekday, from: referenceDate) - 1))
        let todayKey = orderedKeys[todayIdx]

        if let currentDayKey,
           days.contains(where: { $0.id == currentDayKey }) {
            return currentDayKey
        }
        if days.contains(where: { $0.id == todayKey }) {
            return todayKey
        }
        return days.first?.id ?? todayKey
    }

    private static let weekdayKeysSundayFirst: [String] = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]
}

struct PopularTimesDayColumn: Identifiable, Equatable {
    let id: String
    let weekdayShort: String
    let slots: [PopularTimesHourSlot]
}

struct PopularTimesHourSlot: Identifiable, Equatable {
    let id: Int
    let timeLabel: String
    let busynessPercent: Int
    let busyCaption: String?
}

// MARK: - Parsing

enum PopularTimesParsing {
    static func chartModel(from value: SupabaseManager.JSONValue?) -> PopularTimesChartModel? {
        guard let value else { return nil }
        let top: Any?
        switch value {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{"), let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            top = obj
        default:
            top = foundationObject(from: value)
        }
        guard let dict = top as? [String: Any],
              let graph = dict["graph_results"] as? [String: Any] else { return nil }
        let current = (dict["current_day"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ordering = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        var columns: [PopularTimesDayColumn] = []
        for dayKey in ordering {
            guard let rawArr = graph[dayKey] as? [Any] else { continue }
            var slots: [PopularTimesHourSlot] = []
            for (idx, item) in rawArr.enumerated() {
                guard let obj = item as? [String: Any],
                      let timeLabel = obj["time"] as? String else { continue }
                let trimmedTime = timeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTime.isEmpty { continue }
                let score: Int?
                if let i = obj["busyness_score"] as? Int {
                    score = i
                } else if let d = obj["busyness_score"] as? Double {
                    score = Int(d.rounded())
                } else {
                    score = nil
                }
                guard let score else { continue }
                let clamped = min(100, max(0, score))
                let info = obj["info"] as? String
                slots.append(
                    PopularTimesHourSlot(
                        id: idx,
                        timeLabel: trimmedTime,
                        busynessPercent: clamped,
                        busyCaption: info
                    )
                )
            }
            if !slots.isEmpty {
                columns.append(
                    PopularTimesDayColumn(
                        id: dayKey,
                        weekdayShort: shortWeekday(dayKey),
                        slots: slots
                    )
                )
            }
        }
        guard !columns.isEmpty else { return nil }
        return PopularTimesChartModel(currentDayKey: current, days: columns)
    }

    private static func shortWeekday(_ key: String) -> String {
        switch key.lowercased() {
        case "monday": return "Mon"
        case "tuesday": return "Tue"
        case "wednesday": return "Wed"
        case "thursday": return "Thu"
        case "friday": return "Fri"
        case "saturday": return "Sat"
        case "sunday": return "Sun"
        default: return key.prefix(3).capitalized
        }
    }

    private static func foundationObject(from value: SupabaseManager.JSONValue) -> Any? {
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
            return arr.compactMap { foundationObject(from: $0) }
        case .object(let o):
            var out: [String: Any] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o {
                guard let nested = foundationObject(from: v) else { continue }
                out[k] = nested
            }
            return out
        }
    }
}

// MARK: - Chart (SwiftUI)

struct PopularTimesBarChart: View {
    let slots: [PopularTimesHourSlot]

    private let barMaxHeight: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(slots) { slot in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barFill(for: slot.busynessPercent))
                            .frame(height: barHeight(slot.busynessPercent))
                            .accessibilityLabel("\(slot.timeLabel), \(slot.busynessPercent) percent as busy as peak")

                        if shouldShowTimeLabel(slot) {
                            Text(compactTime(slot.timeLabel))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(height: 10)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: barMaxHeight + 22)

            if let caption = peakCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Popular times by hour for the selected day")
    }

    private var peakCaption: String? {
        guard let peak = slots.max(by: { $0.busynessPercent < $1.busynessPercent }),
              peak.busynessPercent > 0 else { return nil }
        return peak.busyCaption
    }

    private func barHeight(_ percent: Int) -> CGFloat {
        let f = CGFloat(percent) / 100.0
        return max(3, f * barMaxHeight)
    }

    private func barFill(for percent: Int) -> Color {
        AppColors.appPrimary.opacity(0.22 + Double(percent) / 100.0 * 0.68)
    }

    private func shouldShowTimeLabel(_ slot: PopularTimesHourSlot) -> Bool {
        guard let idx = slots.firstIndex(where: { $0.id == slot.id }) else { return false }
        return idx % 2 == 0
    }

    private func compactTime(_ full: String) -> String {
        full.replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - Copy

enum TypicalVisitFormatting {
    /// Sentence for `time_spent_min` / `time_spent_max` from city_places.
    static func line(minMinutes: Int?, maxMinutes: Int?) -> String? {
        guard let minM = minMinutes, minM > 0 else { return nil }
        if let maxM = maxMinutes, maxM > minM {
            return "People typically spend \(formatMinutes(minM))–\(formatMinutes(maxM)) here."
        }
        return "People typically spend about \(formatMinutes(minM)) here."
    }

    static func formatMinutes(_ m: Int) -> String {
        if m >= 60 {
            let h = m / 60
            let r = m % 60
            if r == 0 { return h == 1 ? "1 hr" : "\(h) hr" }
            return "\(h) hr \(r) min"
        }
        return "\(m) min"
    }
}
