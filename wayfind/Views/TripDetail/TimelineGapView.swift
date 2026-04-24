import CoreLocation
import SwiftUI

/// Travel-time row rendered between two consecutive timeline cards.
///
/// Picks **one** primary travel mode based on distance (walk under 1 km, drive
/// otherwise) so the user is never asked to choose between modes mid-itinerary.
/// Hides itself entirely when the trip is trivially short (< 2 min) — surfacing
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
