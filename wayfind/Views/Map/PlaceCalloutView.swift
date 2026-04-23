import MapKit
import SwiftUI

struct PlaceCalloutView: View {
    let place: Place

    private var timeRangeText: String? {
        switch (place.startTime, place.endTime) {
        case let (s?, e?):
            return "\(s.timeFormatted) – \(e.timeFormatted)"
        case let (s?, nil):
            return s.timeFormatted
        case let (nil, e?):
            return e.timeFormatted
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(place.name)
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)

            if let address = place.address, !address.isEmpty {
                Text(address)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
            }

            if let timeRangeText {
                Text(timeRangeText)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            VStack(spacing: AppSpacing.sm) {
                AppButton(title: "Navigate", style: .primary) {
                    let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                    mapItem.name = place.name
                    mapItem.openInMaps()
                }
                AppButton(title: "Edit", style: .outline) {}
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appBackground)
    }
}
