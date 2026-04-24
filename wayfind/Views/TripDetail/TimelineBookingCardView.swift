import SwiftUI

/// Booking row in the trip-detail timeline. Sibling of `TimelinePlaceCardView`
/// — same chassis, same pin column, same rhythm — distinguished by an inline
/// type icon (plane / bed / fork…) and a type-specific subtitle line that
/// surfaces the booking's most useful fact at a glance: a flight's route, a
/// hotel's nights, a restaurant's party size, etc. The full booking detail
/// (confirmation chip, address, room type, etc.) lives on the detail screen.
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

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            leadingMarker
            cardSurface
        }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Move to Day", action: onMoveToDay)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Leading marker

    @ViewBuilder
    private var leadingMarker: some View {
        if let start = place.startTime {
            TimePinView(time: start, tint: bookingColor)
        } else {
            UnscheduledMarkerView(tint: bookingColor)
        }
    }

    // MARK: - Card surface

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Image(systemName: bookingSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(bookingColor)
                    .frame(width: 16, alignment: .center)

                // Use `Color.primary` for true system-correct contrast,
                // matching `TimelinePlaceCardView`. See note there.
                Text(place.name)
                    .font(.cardTitle)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }

            if !subtitleParts.isEmpty {
                Text(subtitleParts.joined(separator: " · "))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .timelineCardChassis(stripeColor: bookingColor)
    }

    // MARK: - Type-aware subtitle
    //
    // One short line that surfaces the booking's identifying fact, optionally
    // followed by a compact `#confirmation` so travelers can spot it without
    // tapping in. Keep this to 1 line — long fields (hotels with no nights,
    // confirmation strings) gracefully truncate via `lineLimit(1)`.

    private var subtitleParts: [String] {
        var parts: [String] = []

        if let lead = primaryDetail() {
            parts.append(lead)
        } else if let area = neighborhood(from: place.address) {
            parts.append(area)
        }

        if let conf = place.confirmationNumber, !conf.isEmpty {
            parts.append("#\(conf)")
        }

        return parts
    }

    private func primaryDetail() -> String? {
        guard let details = place.bookingDetails else {
            return place.bookingCategoryEnum?.label
        }
        switch details {
        case .flight(let f):
            return "\(f.departureAirport) → \(f.arrivalAirport)"
        case .hotel(let h):
            if let nights = h.nights, nights > 0 {
                return nights == 1 ? "1 night" : "\(nights) nights"
            }
            return "Hotel"
        case .restaurant(let r):
            if let party = r.partySize, party > 0 {
                return party == 1 ? "Party of 1" : "Party of \(party)"
            }
            return "Reservation"
        case .carRental(let c):
            return "\(c.pickupLocation) → \(c.dropoffLocation)"
        case .activity(let a):
            if let dur = a.duration, !dur.isEmpty { return dur }
            return a.provider.isEmpty ? "Activity" : a.provider
        case .transport(let t):
            return "\(t.departureStation) → \(t.arrivalStation)"
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var pieces: [String] = []
        let label = place.bookingCategoryEnum?.label ?? "Booking"
        pieces.append("\(label): \(place.name)")
        if let lead = primaryDetail() {
            pieces.append(lead)
        }
        if let start = place.startTime {
            if let end = place.endTime {
                pieces.append("\(start.timeFormatted) to \(end.timeFormatted)")
            } else {
                pieces.append(start.timeFormatted)
            }
        }
        if let conf = place.confirmationNumber, !conf.isEmpty {
            pieces.append("confirmation \(conf)")
        }
        return pieces.joined(separator: ", ")
    }
}

// `neighborhood(from:)` is shared from `TimelinePlaceCardView.swift` (file-
// private was promoted to internal so both timeline cards parse addresses the
// same way).


// =============================================================================
