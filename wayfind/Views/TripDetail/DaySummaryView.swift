import CoreLocation
import SwiftUI

/// One-line summary of a day's plan, rendered just under the day header.
///
/// Surfaces the two most useful "shape of the day" signals — total planned
/// duration and approximate walking distance between consecutive stops — so
/// the user can feel the day at a glance instead of reading every card.
struct DaySummaryView: View {
    let places: [Place]
    /// Shown when the day has no stops (quiet empty day); ongoing cross-day rows are handled in the parent.
    var showNoPlansYet: Bool = false
    var emptyDayPrompt: String = "No plans yet"

    private var totalDurationMinutes: Int {
        places.reduce(0) { sum, place in
            guard let start = place.startTime else { return sum }
            let end = place.endTime ?? start.addingTimeInterval(60 * 60)
            let mins = max(0, Int(end.timeIntervalSince(start) / 60))
            return sum + mins
        }
    }

    /// Sum of point-to-point distances between consecutive geocoded stops, in km.
    /// Approximates how much ground the user covers across the day; useful even
    /// when the actual mode is car (still indicates day footprint).
    private var totalDistanceKm: Double {
        guard places.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 1..<places.count {
            let prev = places[i - 1]
            let curr = places[i]
            guard let aLat = prev.lat, let aLng = prev.lng,
                  let bLat = curr.lat, let bLng = curr.lng else { continue }
            total += HaversineDistance.distance(
                from: CLLocationCoordinate2D(latitude: aLat, longitude: aLng),
                to: CLLocationCoordinate2D(latitude: bLat, longitude: bLng)
            )
        }
        return total
    }

    private var summaryParts: [String] {
        var parts: [String] = []
        if let duration = formattedDuration(totalDurationMinutes) {
            parts.append("\(duration) planned")
        }
        if let distance = formattedDistance(totalDistanceKm) {
            parts.append("\(distance) total")
        }
        return parts
    }

    var body: some View {
        if showNoPlansYet {
            Text(emptyDayPrompt)
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.sm)
        } else if !summaryParts.isEmpty {
            Text(summaryParts.joined(separator: " · "))
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.sm)
        }
    }

    private func formattedDuration(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Returns `"1.2 km"` / `"450 m"`. Suppresses noise under 100 m which is
    /// usually within the same building or block.
    private func formattedDistance(_ km: Double) -> String? {
        guard km > 0.1 else { return nil }
        if km >= 1 {
            return String(format: "%.1f km", km)
        }
        let meters = Int((km * 1000).rounded())
        return "\(meters) m"
    }
}


// =============================================================================

#if DEBUG
#Preview("Day summary") {
    DaySummaryView(places: [.previewAttraction, .previewRestaurant, .previewHotel])
        .padding()
        .background(AppColors.appBackground)
}
#endif
