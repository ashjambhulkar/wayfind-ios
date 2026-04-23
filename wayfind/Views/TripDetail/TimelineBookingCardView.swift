import SwiftUI

struct TimelineBookingCardView: View {
    let place: Place
    let dayNumber: Int

    var onEdit: () -> Void = {}
    var onMoveToDay: () -> Void = {}
    var onDelete: () -> Void = {}

    private var bookingColor: Color {
        place.bookingCategoryEnum?.color ?? AppColors.appPrimary
    }

    private var bookingSymbol: String {
        place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill"
    }

    private var detailLine: String? {
        guard let details = place.bookingDetails else {
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

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            ZStack(alignment: .top) {
                TimelineRailView.railLine()
                    .frame(maxHeight: .infinity)
                TimelineRailView.railDot(isBooking: true, color: bookingColor)
                    .padding(.top, 2)
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    Image(systemName: bookingSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(bookingColor)
                    Text(place.name)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                }

                if let detailLine {
                    Text(detailLine)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                }

                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }

                if let timeRangeText {
                    Text(timeRangeText)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }

                if let confirmation = place.confirmationNumber, !confirmation.isEmpty {
                    Text(confirmation)
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xs)
                        .background(AppColors.appPrimaryLight)
                        .clipShape(Capsule())
                }
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(bookingColor)
                    .frame(width: 4)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Move to Day", action: onMoveToDay)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.bookingCategoryEnum?.label ?? "Booking"): \(place.name)\(place.confirmationNumber.map { ", confirmation \($0)" } ?? "")")
    }
}

