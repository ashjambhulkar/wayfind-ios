import CoreLocation
import MapKit
import SwiftUI

enum TimelineBetweenStopsMetrics {
    static let shortWalkThresholdKm: Double = 1.0
    /// Matches `TimelineSpineMetrics.columnWidth` so travel rows align with the time-pin column.
    static var timePinGutterWidth: CGFloat { TimelineSpineMetrics.columnWidth }
    /// Vertical padding on the full-width travel segment row (kept minimal so the timeline stays dense).
    static let gapRowVerticalPadding: CGFloat = 0

    /// Hub diameter for the mode ring — intentionally a bit smaller than activity spine pins
    /// (`2 * timePinBodyRadius`) so travel reads as a connector, not a full stop.
    static let modeCircleSide: CGFloat = 22

    static var minRowHeight: CGFloat { modeCircleSide + AppSpacing.xs }
}

enum TimelineBetweenStopsPresentation {
    static func sfSymbol(for mode: AppleTravelTimesService.Mode) -> String {
        switch mode {
        case .walking: return "figure.walk"
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        }
    }

    static func accessibilityLabel(for mode: AppleTravelTimesService.Mode) -> String {
        switch mode {
        case .walking: return String(localized: "Walking")
        case .driving: return String(localized: "Driving")
        case .transit: return String(localized: "Transit")
        }
    }

    /// Locale-aware distance; falls back to miles when formatter yields empty.
    static func formatDistance(meters: Int) -> String {
        let measurement = Measurement(value: Double(meters), unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 2
        formatter.numberFormatter.minimumFractionDigits = 0
        let formatted = formatter.string(from: measurement)
        return formatted.isEmpty ? fallBackImperialMiles(meters: meters) : formatted
    }

    /// TODO: Remove once `MeasurementFormatter` coverage is validated on all supported locales.
    private static func fallBackImperialMiles(meters: Int) -> String {
        let miles = Double(meters) / 1609.344
        return String(format: "%.2f mi", miles)
    }

    static func mkLaunchDirectionsMode(for mode: AppleTravelTimesService.Mode) -> String {
        switch mode {
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        }
    }

    static func normalizedGooglePlaceId(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Duration + distance for the collapsed travel segment row (comma-separated; localized pattern).
    static func summaryLine(minutesText: String, distanceText: String) -> String {
        String(format: String(localized: "Timeline travel duration and distance"), minutesText, distanceText)
    }

    private static let minutesPerHour = 60
    private static let minutesPerDay = minutesPerHour * 24

    /// Spine-only travel ETA: **`1h 20m`** under 24h; **`1d 2h`** (and optional **`…m`** when needed) across day boundaries.
    static func spineTravelDuration(minutes: Int) -> String {
        let total = max(0, minutes)
        if total == 0 { return "0m" }
        if total < minutesPerDay {
            return spineTravelUnderOneDay(total)
        }
        return spineTravelOneDayAndUp(total)
    }

    private static func spineTravelUnderOneDay(_ total: Int) -> String {
        let hours = total / minutesPerHour
        let mins = total % minutesPerHour
        if hours == 0 { return "\(mins)m" }
        if mins == 0 { return "\(hours)h" }
        return "\(hours)h \(mins)m"
    }

    private static func spineTravelOneDayAndUp(_ total: Int) -> String {
        let days = total / minutesPerDay
        let remainder = total % minutesPerDay
        let hours = remainder / minutesPerHour
        let mins = remainder % minutesPerHour

        var parts: [String] = []
        parts.append("\(days)d")
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 { parts.append("\(mins)m") }
        return parts.joined(separator: " ")
    }
}
