import CoreLocation
import SwiftUI

/// Travel-time row rendered between two consecutive timeline cards.
///
/// Data priority:
/// 1. `toPlace.travelFromPreviousMinutes` + `toPlace.travelMode` — the
///    server-precomputed value (Mapbox / Google / curated). Always trust this
///    when present so manual itinerary tweaks survive into the UI.
/// 2. Haversine fallback — distance between coordinates with a single mode
///    chosen by distance (walk under 1 km, drive otherwise) so the user is
///    never asked to choose between modes mid-itinerary.
///
/// Hides itself entirely when the gap is trivially short (< 2 min). Surfacing
/// `0 min` reads as a UI bug, not a feature.
struct TimelineGapView: View {
    let fromPlace: Place
    let toPlace: Place

    /// Distance threshold in km below which we recommend walking instead of
    /// driving. Roughly aligns with what Apple Maps suggests as a walkable hop.
    private static let walkThresholdKm: Double = 1.0

    /// Below this number of minutes the row is suppressed — it's not interesting,
    /// and rendering "1 min" or "0 min" rows just adds noise.
    private static let minMinutesToShow: Int = 2

    private struct Gap {
        let mode: HaversineDistance.TravelMode
        let minutes: Int
    }

    private var gap: Gap? {
        // Prefer server-computed travel data on the destination place.
        if let stored = toPlace.travelFromPreviousMinutes, stored >= Self.minMinutesToShow {
            let mode = parseTravelMode(toPlace.travelMode) ?? defaultMode()
            return Gap(mode: mode, minutes: stored)
        }

        // Fallback: estimate from coordinates with Haversine.
        guard let aLat = fromPlace.lat, let aLng = fromPlace.lng,
              let bLat = toPlace.lat, let bLng = toPlace.lng else {
            return nil
        }
        let from = CLLocationCoordinate2D(latitude: aLat, longitude: aLng)
        let to = CLLocationCoordinate2D(latitude: bLat, longitude: bLng)
        let km = HaversineDistance.distance(from: from, to: to)
        let mode: HaversineDistance.TravelMode = km < Self.walkThresholdKm ? .walking : .driving
        let minutes = HaversineDistance.estimateTravelTime(from: from, to: to, mode: mode)
        guard minutes >= Self.minMinutesToShow else { return nil }
        return Gap(mode: mode, minutes: minutes)
    }

    var body: some View {
        if let gap {
            HStack(spacing: AppSpacing.xs) {
                Spacer().frame(width: 40)
                Image(systemName: gap.mode.sfSymbol)
                    .font(.system(size: 11, weight: .medium))
                Text("\(gap.minutes) min")
                    .font(.appCaption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppColors.textTertiary)
            .padding(.vertical, AppSpacing.xs)
            .padding(.horizontal, AppSpacing.lg)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(gap.minutes) minutes by \(modeDescription(gap.mode))")
        }
    }

    /// Map a free-form `travel_mode` string from `trip_activities` (e.g.
    /// `"walk"`, `"walking"`, `"DRIVING"`, `"transit"`) onto our local enum.
    /// Returns `nil` for unknown / empty inputs so the caller can fall back to
    /// the distance heuristic.
    private func parseTravelMode(_ raw: String?) -> HaversineDistance.TravelMode? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "walk", "walking", "foot", "on_foot": return .walking
        case "drive", "driving", "car", "taxi", "rideshare", "uber": return .driving
        case "bike", "bicycle", "cycling", "cycle": return .cycling
        case "transit", "metro", "subway", "bus", "train", "tram", "rail":
            return .transit
        default: return nil
        }
    }

    /// Used when we have server minutes but no usable mode string.
    private func defaultMode() -> HaversineDistance.TravelMode {
        guard let aLat = fromPlace.lat, let aLng = fromPlace.lng,
              let bLat = toPlace.lat, let bLng = toPlace.lng else {
            return .driving
        }
        let from = CLLocationCoordinate2D(latitude: aLat, longitude: aLng)
        let to = CLLocationCoordinate2D(latitude: bLat, longitude: bLng)
        let km = HaversineDistance.distance(from: from, to: to)
        return km < Self.walkThresholdKm ? .walking : .driving
    }

    private func modeDescription(_ mode: HaversineDistance.TravelMode) -> String {
        switch mode {
        case .walking: return "walking"
        case .driving: return "car"
        case .cycling: return "bike"
        case .transit: return "transit"
        }
    }
}


// =============================================================================

#if DEBUG
#Preview("Travel gap") {
    VStack {
        TimelineGapView(
            fromPlace: .previewAttraction,
            toPlace: .previewRestaurant
        )
        TimelineGapView(
            fromPlace: .previewRestaurant,
            toPlace: .previewHotel
        )
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
