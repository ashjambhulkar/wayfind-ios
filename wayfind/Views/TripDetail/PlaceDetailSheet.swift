import MapKit
import SwiftUI

struct PlaceDetailSheet: View {
    let place: Place
    let previousPlace: Place?

    var onEdit: () -> Void = {}
    var onMove: () -> Void = {}
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private var categorySymbol: String {
        if place.isBooking {
            place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill"
        } else {
            place.categoryEnum.sfSymbol
        }
    }

    private var categoryLabel: String {
        if place.isBooking {
            place.bookingCategoryEnum?.label ?? "Booking"
        } else {
            place.categoryEnum.label
        }
    }

    private var bookingDetailLine: String? {
        guard place.isBooking, let details = place.bookingDetails else {
            return nil
        }
        switch details {
        case .flight(let f):
            return "\(f.departureAirport) → \(f.arrivalAirport)"
        case .hotel(let h):
            if let nights = h.nights {
                return "\(nights) nights"
            }
            return "Hotel"
        case .restaurant(let r):
            if let party = r.partySize {
                return "Party of \(party)"
            }
            return "Reservation"
        case .carRental(let c):
            return "\(c.pickupLocation) → \(c.dropoffLocation)"
        case .activity(let a):
            if let duration = a.duration, !duration.isEmpty {
                return duration
            }
            return a.provider
        case .transport(let t):
            return "\(t.departureStation) → \(t.arrivalStation)"
        }
    }

    private var timeRangeText: String? {
        switch (place.startTime, place.endTime) {
        case let (start?, end?):
            return "\(start.timeFormatted) - \(end.timeFormatted)"
        case let (start?, nil):
            return start.timeFormatted
        default:
            return nil
        }
    }

    private var hasCoordinates: Bool {
        guard let lat = place.lat, let lng = place.lng else { return false }
        return !lat.isNaN && !lng.isNaN
    }

    private var previousHasCoordinates: Bool {
        guard let previous = previousPlace,
              let lat = previous.lat,
              let lng = previous.lng else { return false }
        return !lat.isNaN && !lng.isNaN
    }

    private var travelModes: [HaversineDistance.TravelMode] {
        [.walking, .driving, .cycling, .transit]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text(place.name)
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)

                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                }

                HStack(spacing: AppSpacing.sm) {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: categorySymbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(categoryLabel)
                    }
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.appSurface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(AppColors.appDivider, lineWidth: 1)
                    )

                    if place.isBooking,
                       let confirmation = place.confirmationNumber,
                       !confirmation.isEmpty {
                        Text(confirmation)
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xs)
                            .background(AppColors.appPrimaryLight)
                            .clipShape(Capsule())
                    }
                }

                if place.isBooking, let bookingDetailLine {
                    Text(bookingDetailLine)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                if let timeRangeText {
                    Text(timeRangeText)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }

                Divider()
                    .background(AppColors.appDivider)

                Text("GETTING THERE")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .tracking(1.5)
                    .textCase(.uppercase)

                if let previous = previousPlace, previousHasCoordinates, hasCoordinates {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(Array(travelModes.enumerated()), id: \.offset) { _, mode in
                            let minutes = HaversineDistance.estimateTravelTime(
                                from: previous.coordinate,
                                to: place.coordinate,
                                mode: mode
                            )
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: mode.sfSymbol)
                                Text("\(minutes) min")
                            }
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xs)
                            .background(AppColors.appSurface)
                            .clipShape(Capsule())
                        }
                    }
                } else {
                    Text("First stop of the day")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }

                Spacer(minLength: AppSpacing.xl)

                if hasCoordinates {
                    AppButton(title: "Navigate", style: .primary) {
                        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                        mapItem.name = place.name
                        mapItem.openInMaps()
                    }
                }

                HStack(spacing: AppSpacing.md) {
                    AppButton(title: "Edit", style: .outline) {
                        onEdit()
                        dismiss()
                    }
                    AppButton(title: "Move", style: .outline) {
                        onMove()
                        dismiss()
                    }
                }

                Button {
                    onDelete()
                    dismiss()
                } label: {
                    Text("Delete")
                        .font(.appButton)
                        .foregroundStyle(AppColors.appError)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xxl)
        }
        .padding(.horizontal, AppSpacing.lg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .background(AppColors.appBackground)
    }
}
