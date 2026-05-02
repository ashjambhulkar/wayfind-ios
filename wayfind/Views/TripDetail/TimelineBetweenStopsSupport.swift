import CoreLocation
import MapKit
import SwiftUI

enum TimelineBetweenStopsMetrics {
    static let shortWalkThresholdKm: Double = 1.0
    /// Matches `TimelineSpineMetrics.columnWidth` so travel gaps align with card time-pin column.
    static var timePinGutterWidth: CGFloat { TimelineSpineMetrics.columnWidth }
    static let minRowHeight: CGFloat = 44
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

    static func title(for mode: AppleTravelTimesService.Mode) -> String {
        switch mode {
        case .walking: return String(localized: "Walking")
        case .driving: return String(localized: "Driving")
        case .transit: return String(localized: "Transit")
        }
    }

    /// Compact label for inline timeline mode chips.
    static func shortLabel(for mode: AppleTravelTimesService.Mode) -> String {
        switch mode {
        case .walking: return String(localized: "Walk")
        case .driving: return String(localized: "Drive")
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
}
