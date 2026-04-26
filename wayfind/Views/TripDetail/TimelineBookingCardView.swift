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
    /// Wave 1.2 — opens the attachments manager for this booking.
    /// Optional so callers that don't yet wire it (e.g. previews) compile.
    var onAttachments: (() -> Void)? = nil
    /// Wave 3.3 — live (or last-known) flight status. Only consulted
    /// when this booking's category is `.flight`. Defaults to nil so
    /// non-flight previews / older callers stay source-compatible.
    var flightStatus: FlightStatus? = nil
    var isFlightStale: Bool = false
    var flightTint: FlightStatus.DisplayState.Tint = .neutral
    var isProUser: Bool = true
    var onUpgradeTap: (() -> Void)? = nil
    var onFlightBadgeTap: (() -> Void)? = nil

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
            if let onAttachments {
                Button("Files & Photos", action: onAttachments)
            }
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

            if shouldShowFlightBadge {
                FlightStatusBadge(
                    status: flightStatus,
                    isStale: isFlightStale,
                    tint: flightTint,
                    isProUser: isProUser,
                    onUpsellTap: onUpgradeTap,
                    onTap: onFlightBadgeTap
                )
            }
        }
        .timelineCardChassis(stripeColor: bookingColor)
    }

    /// Only render the badge for flight bookings — and even then only
    /// when we either have a status to show or we're soft-upselling
    /// the free user. Hides the badge entirely on hotels / restaurants
    /// / activities so the timeline stays uncluttered.
    private var shouldShowFlightBadge: Bool {
        guard place.bookingCategoryEnum == .flight else { return false }
        if flightStatus != nil { return true }
        // Free user with no status yet → show the upsell pill so they
        // can discover the feature. Pro user with no status row yet
        // (haven't started tracking) → hide; the explicit "Track flight"
        // entry point lives in the booking detail screen.
        return isProUser == false
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

#if DEBUG
#Preview("Booking cards") {
    ScrollView {
        VStack(spacing: 0) {
            TimelineBookingCardView(place: .previewHotel, dayNumber: 1)
            TimelineBookingCardView(place: .previewFlight, dayNumber: 1)
        }
        .padding()
    }
    .background(AppColors.appBackground)
}
#endif
