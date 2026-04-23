import CoreLocation
import SwiftUI

struct TimelineGapView: View {
    let fromPlace: Place
    let toPlace: Place

    var body: some View {
        Group {
            if let walk = travelMinutes(from: fromPlace, to: toPlace, mode: .walking),
               let drive = travelMinutes(from: fromPlace, to: toPlace, mode: .driving) {
                HStack {
                    Spacer()
                        .frame(width: 40)
                    HStack(spacing: AppSpacing.sm) {
                        Label("\(walk) min", systemImage: "figure.walk")
                        Text("·")
                        Label("\(drive) min", systemImage: "car.fill")
                    }
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, AppSpacing.sm)
                .padding(.horizontal, AppSpacing.lg)
            }
        }
    }

    private func travelMinutes(from: Place, to: Place, mode: HaversineDistance.TravelMode) -> Int? {
        guard let aLat = from.lat, let aLng = from.lng,
              let bLat = to.lat, let bLng = to.lng else {
            return nil
        }
        let fromCoord = CLLocationCoordinate2D(latitude: aLat, longitude: aLng)
        let toCoord = CLLocationCoordinate2D(latitude: bLat, longitude: bLng)
        return HaversineDistance.estimateTravelTime(from: fromCoord, to: toCoord, mode: mode)
    }
}

