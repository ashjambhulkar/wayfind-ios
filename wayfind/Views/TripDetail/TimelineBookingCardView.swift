import SwiftUI

/// Booking row in the trip-detail timeline. Sibling of `TimelinePlaceCardView`
/// — same chassis, same pin column, same rhythm — distinguished by a type-specific subtitle line that
/// surfaces the booking's most useful fact at a glance: a flight's route, a
/// hotel's nights, a restaurant's party size, etc. The full booking detail
/// (confirmation chip, address, room type, etc.) lives on the detail screen.
struct TimelineBookingCardView: View {
    let place: Place
    let dayNumber: Int
    var timelineDisplayTimeZone: TimeZone = .current
    /// When set, narrows the hotel card to check-in or check-out (split stay).
    var hotelTimelineRole: HotelTimelineDisplayRole? = nil

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

    init(
        place: Place,
        dayNumber: Int,
        timelineDisplayTimeZone: TimeZone = .current,
        hotelTimelineRole: HotelTimelineDisplayRole? = nil,
        onEdit: @escaping () -> Void = {},
        onMoveToDay: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onAttachments: (() -> Void)? = nil,
        flightStatus: FlightStatus? = nil,
        isFlightStale: Bool = false,
        flightTint: FlightStatus.DisplayState.Tint = .neutral,
        isProUser: Bool = true,
        onUpgradeTap: (() -> Void)? = nil,
        onFlightBadgeTap: (() -> Void)? = nil
    ) {
        self.place = place
        self.dayNumber = dayNumber
        self.timelineDisplayTimeZone = timelineDisplayTimeZone
        self.hotelTimelineRole = hotelTimelineRole
        self.onEdit = onEdit
        self.onMoveToDay = onMoveToDay
        self.onDelete = onDelete
        self.onAttachments = onAttachments
        self.flightStatus = flightStatus
        self.isFlightStale = isFlightStale
        self.flightTint = flightTint
        self.isProUser = isProUser
        self.onUpgradeTap = onUpgradeTap
        self.onFlightBadgeTap = onFlightBadgeTap
    }

    private var bookingColor: Color {
        place.bookingCategoryEnum?.color ?? AppColors.appPrimary
    }

    private var bookingCategory: BookingCategory {
        place.bookingCategoryEnum ?? .activity
    }

    /// Wall-clock instant shown on the spine (start of the row); falls back to
    /// category-specific primary times when `place.startTime` is unset.
    private var spineStartTime: Date? {
        if let start = place.startTime { return start }
        switch place.bookingDetails {
        case .flight(let details):
            return flightDepartureTime(details)
        case .hotel(let hotel):
            if hotelTimelineRole == .checkOut {
                return hotel.checkOutDate
            }
            return hotel.checkInDate
        case .restaurant(let restaurant):
            return restaurant.reservationTime
        case .carRental(let rental):
            return rental.pickupTime
        case .transport(let transport):
            return transport.departureTime
        case .activity, nil:
            return nil
        }
    }

    private var spineAccessibilityLabel: String {
        if let time = spineStartTime {
            return "Starts \(time.timeFormatted(timeZone: timelineDisplayTimeZone))"
        }
        return String(localized: "Flexible time")
    }

    var body: some View {
        HStack(alignment: .top, spacing: TimelineSpineMetrics.pinColumnToCardSpacing) {
            TimelineSpineTimeColumn(
                startTime: spineStartTime,
                accentColor: bookingColor,
                timeZone: timelineDisplayTimeZone,
                accessibilityLabel: spineAccessibilityLabel
            )

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

    // MARK: - Card surface

    @ViewBuilder
    private var cardSurface: some View {
        if case .flight(let details) = place.bookingDetails {
            TimelineFlightBookingPassCard(
                airlineName: flightAirlineDisplayName(details),
                carrierIATA: flightCarrierCode(details),
                departureAirport: flightDepartureAirport(details),
                arrivalAirport: flightArrivalAirport(details),
                departureTime: flightDepartureTime(details),
                arrivalTime: flightArrivalTime(details),
                duration: flightDuration(details),
                statusText: flightStatusText ?? "Flight",
                showFlightStatusBadge: shouldShowFlightBadge,
                flightStatus: flightStatus,
                isFlightStale: isFlightStale,
                flightTint: flightTint,
                isProUser: isProUser,
                onFlightBadgeTap: onFlightBadgeTap,
                onFlightUpsellTap: onUpgradeTap
            )
        } else {
            TimelineBookingPassCard(
                category: bookingCategory,
                eyebrow: passEyebrow,
                title: passTitle,
                subtitle: passSubtitle,
                statusText: passTimelineStatusChipText,
                metrics: passMetrics,
                footerSummaryLines: timelineFooterSummaryLines,
                titleTrailing: passTitleTrailingText,
                eyebrowTrailingText: nil,
                addressFootnote: hotelTimelineAddressFootnote
            )
        }
    }

    /// Timeline-only: hotel property address under the subtitle.
    private var hotelTimelineAddressFootnote: String? {
        guard place.bookingCategoryEnum == .hotel else { return nil }
        let trimmed = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Footer summary lines for timeline booking cards; `nil` falls back to metric columns.
    private var timelineFooterSummaryLines: [String]? {
        restaurantTimelineFooterSummaryLines
    }

    /// Status capsule on the eyebrow row — unused on `TimelineBookingPassCard` (title row is enough; flight uses its own card).
    private var passTimelineStatusChipText: String { "" }

    /// Restaurant: party count on the same row as the venue title.
    private var restaurantTitleTrailingText: String? {
        guard case .restaurant(let r) = place.bookingDetails else { return nil }
        if let party = r.partySize, party > 0 {
            return party == 1 ? "1 guest" : "\(party) guests"
        }
        return nil
    }

    /// Event / activity ticket: start time on the title row (trailing).
    private var activityTitleTrailingText: String? {
        guard case .activity = place.bookingDetails else { return nil }
        if let start = place.startTime {
            return start.timeFormatted(timeZone: timelineDisplayTimeZone)
        }
        return String(localized: "Time TBD")
    }

    /// Transit: departure time only on the title row (trailing); date belongs on the spine / detail.
    private var transportTitleTrailingText: String? {
        guard case .transport(let t) = place.bookingDetails else { return nil }
        let tz = timelineDisplayTimeZone
        if let dep = t.departureTime {
            return dep.timeFormatted(timeZone: tz)
        }
        return String(localized: "Time TBD")
    }

    /// Hotel: night count on the title row (trailing), same for split check-in / check-out rows.
    private var hotelNightsTitleTrailingText: String? {
        guard case .hotel(let h) = place.bookingDetails else { return nil }
        guard let n = h.nights, n > 0 else { return nil }
        return n == 1
            ? String(localized: "1 night")
            : String(format: String(localized: "%d nights"), n)
    }

    /// Car rental: pickup time only on the title row (trailing); date belongs on the spine / detail.
    private var carRentalTitleTrailingText: String? {
        guard case .carRental(let c) = place.bookingDetails else { return nil }
        let tz = timelineDisplayTimeZone
        if let pickup = c.pickupTime {
            return pickup.timeFormatted(timeZone: tz)
        }
        return String(localized: "Pickup TBD")
    }

    private var passTitleTrailingText: String? {
        transportTitleTrailingText
            ?? hotelNightsTitleTrailingText
            ?? carRentalTitleTrailingText
            ?? activityTitleTrailingText
            ?? restaurantTitleTrailingText
    }

    private func hotelCheckInOutMoment(label: String, date: Date?, timeString: String?, timeZone: TimeZone, missing: String) -> String {
        guard let date else { return "\(label) \(missing)" }
        let datePart = date.shortFormatted(timeZone: timeZone)
        let trimmedTime = timeString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timePart = trimmedTime.isEmpty ? date.timeFormatted(timeZone: timeZone) : trimmedTime
        return "\(label) \(datePart) · \(timePart)"
    }

    /// Restaurant: one scannable footer line — time · guests · confirmation.
    private var restaurantTimelineFooterSummaryLines: [String]? {
        guard case .restaurant(let r) = place.bookingDetails else { return nil }
        let tz = timelineDisplayTimeZone
        let timePart: String
        if let t = r.reservationTime {
            timePart = "Time \(t.timeFormatted(timeZone: tz))"
        } else {
            timePart = "Time TBD"
        }
        let partyPart: String
        if let p = r.partySize, p > 0 {
            partyPart = p == 1 ? "Guests 1" : "Guests \(p)"
        } else {
            partyPart = "Guests —"
        }
        let code = confirmationValue
        let confirmPart = code == "—" ? "—" : code
        let line = "\(timePart) · \(partyPart) · \(confirmPart)"
        return [line]
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

    private var flightStatusText: String? {
        guard shouldShowFlightBadge else { return nil }
        guard let flightStatus else { return isProUser ? "Tracking" : "Pro tracking" }
        if isFlightStale { return "Stale" }
        switch flightStatus.displayState {
        case .scheduled:
            if let delay = flightStatus.delayMinutes, delay >= 5 { return "+\(delay)m" }
            return "On time"
        case .active: return "In flight"
        case .landed: return "Landed"
        case .cancelled: return "Cancelled"
        case .diverted: return "Diverted"
        case .unknown: return "Unknown"
        }
    }

    /// Non-flight pass cards omit the uppercase eyebrow row (restaurant “Table Card”, etc.).
    /// Flight uses `TimelineFlightBookingPassCard`, not this string.
    private var passEyebrow: String { "" }

    private var passTitle: String {
        guard let details = place.bookingDetails else { return place.name }
        switch details {
        case .flight(let f):
            return "\(clean(f.departureAirport, fallback: "TBD")) → \(clean(f.arrivalAirport, fallback: "TBD"))"
        case .hotel, .restaurant, .activity:
            return TimelinePlaceDisplayName.timelineDisplay(place.name)
        case .carRental(let c):
            let title = clean(c.company, fallback: place.name)
            return TimelinePlaceDisplayName.timelineDisplay(title)
        case .transport(let t):
            let operatorLabel = clean(t.operatorName, fallback: "")
            if !operatorLabel.isEmpty { return TimelinePlaceDisplayName.timelineDisplay(operatorLabel) }
            let fallbackTitle = "\(clean(t.serviceNumber, fallback: ""))".trimmingCharacters(in: .whitespacesAndNewlines)
            if fallbackTitle.isEmpty { return TimelinePlaceDisplayName.timelineDisplay(place.name) }
            return TimelinePlaceDisplayName.timelineDisplay(fallbackTitle)
        }
    }

    private var passSubtitle: String {
        guard let details = place.bookingDetails else {
            return primaryDetail() ?? bookingCategory.label
        }
        switch details {
        case .flight(let f):
            return flightCode(f)
        case .hotel(let h):
            let tz = timelineDisplayTimeZone
            let checkInLine = hotelCheckInOutMoment(
                label: String(localized: "Check-in"),
                date: h.checkInDate,
                timeString: h.checkInTime,
                timeZone: tz,
                missing: String(localized: "TBD")
            )
            let checkOutLine = hotelCheckInOutMoment(
                label: String(localized: "Check-out"),
                date: h.checkOutDate,
                timeString: h.checkOutTime,
                timeZone: tz,
                missing: String(localized: "TBD")
            )
            return "\(checkInLine) · \(checkOutLine)"
        case .restaurant(let r):
            if let t = r.reservationTime {
                return "\(t.shortFormatted(timeZone: timelineDisplayTimeZone)) · \(t.timeFormatted(timeZone: timelineDisplayTimeZone))"
            }
            return "Reservation"
        case .carRental(let c):
            return "\(clean(c.pickupLocation, fallback: "Pickup TBD")) → \(clean(c.dropoffLocation, fallback: "Dropoff TBD"))"
        case .activity:
            let trimmed = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind = place.placeKindLabel ?? place.categoryEnum.label
            let rawDetail = primaryDetail() ?? ""
            let extra: String? = {
                let d = rawDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !d.isEmpty, d != kind, d != "Activity" else { return nil }
                return d
            }()
            var segments: [String] = [kind]
            if let extra {
                segments.append(extra)
            }
            if !trimmed.isEmpty {
                segments.append(trimmed)
            } else if segments.count == 1 {
                return String(localized: "Location not added")
            }
            return segments.joined(separator: " · ")
        case .transport(let t):
            return "\(clean(t.departureStation, fallback: "Departure TBD")) → \(clean(t.arrivalStation, fallback: "Arrival TBD"))"
        }
    }

    private var passMetrics: [TimelineBookingPassMetric] {
        guard let details = place.bookingDetails else {
            return [
                dateTimeMetric(title: "When", date: place.startTime),
                TimelineBookingPassMetric(title: "Confirm", value: confirmationValue)
            ]
        }
        switch details {
        case .flight:
            // Flight timeline uses `TimelineFlightBookingPassCard` (no metric footer).
            return []
        case .hotel:
            return []
        case .restaurant(let r):
            return [
                TimelineBookingPassMetric(title: "Time", value: r.reservationTime?.timeFormatted(timeZone: timelineDisplayTimeZone) ?? "TBD"),
                TimelineBookingPassMetric(title: "Party", value: r.partySize.map { "\($0)" } ?? "—"),
                TimelineBookingPassMetric(title: "Confirm", value: confirmationValue)
            ]
        case .carRental:
            return []
        case .activity:
            return []
        case .transport:
            return []
        }
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

        return parts
    }

    private var confirmationCode: String? {
        guard let conf = place.confirmationNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !conf.isEmpty else {
            return nil
        }
        return "#\(conf)"
    }

    private var confirmationValue: String {
        clean(place.confirmationNumber, fallback: "—")
    }

    private func dateTimeMetric(title: String, date: Date?) -> TimelineBookingPassMetric {
        guard let date else { return TimelineBookingPassMetric(title: title, value: "TBD") }
        return TimelineBookingPassMetric(
            title: title,
            value: date.shortFormatted(timeZone: timelineDisplayTimeZone),
            detail: date.timeFormatted(timeZone: timelineDisplayTimeZone)
        )
    }

    private func flightCode(_ details: FlightDetails) -> String {
        let carrier = clean(details.carrierIATA, fallback: "")
        let number = clean(details.flightNumber, fallback: "")
        let combined = "\(carrier) \(number)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? clean(details.airline, fallback: "Flight") : combined
    }

    private func flightCarrierCode(_ details: FlightDetails) -> String? {
        let fromDetails = details.carrierIATA?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromStatus = flightStatus?.carrierIata.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = fromDetails, !d.isEmpty { return d }
        if let s = fromStatus, !s.isEmpty { return s }
        return nil
    }

    private func flightAirlineDisplayName(_ details: FlightDetails) -> String {
        let name = details.airline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return flightCode(details)
    }

    private func flightDepartureAirport(_ details: FlightDetails) -> String {
        clean(flightStatus?.originAirportIata, fallback: clean(details.departureAirport, fallback: "TBD"))
    }

    private func flightArrivalAirport(_ details: FlightDetails) -> String {
        clean(flightStatus?.destinationAirportIata, fallback: clean(details.arrivalAirport, fallback: "TBD"))
    }

    private func flightDepartureTime(_ details: FlightDetails) -> Date? {
        flightStatus?.estimatedDepartureUTC
            ?? flightStatus?.actualDepartureUTC
            ?? flightStatus?.scheduledDepartureUTC
            ?? details.departureTime
            ?? place.startTime
    }

    private func flightArrivalTime(_ details: FlightDetails) -> Date? {
        flightStatus?.estimatedArrivalUTC
            ?? flightStatus?.actualArrivalUTC
            ?? flightStatus?.scheduledArrivalUTC
            ?? details.arrivalTime
            ?? place.endTime
    }

    private func flightDuration(_ details: FlightDetails) -> String? {
        guard let departure = flightDepartureTime(details), let arrival = flightArrivalTime(details) else { return nil }
        let minutes = max(0, Int(arrival.timeIntervalSince(departure) / 60))
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return "\(mins)m" }
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    private func clean(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
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
        let label = place.bookingCategoryEnum?.label ?? "Booking"
        if case .hotel = place.bookingDetails {
            let nightsPart = passTitleTrailingText ?? String(localized: "Nights not set")
            let addr = hotelTimelineAddressFootnote.map { ", \($0)" } ?? ""
            return "\(label): \(passTitle), \(nightsPart), \(passSubtitle)\(addr)"
        }
        if case .carRental = place.bookingDetails {
            let schedule = passTitleTrailingText ?? String(localized: "Pickup TBD")
            return "\(label): \(passTitle), \(schedule), \(passSubtitle)"
        }
        if case .transport = place.bookingDetails {
            let schedule = passTitleTrailingText ?? String(localized: "Time TBD")
            return "\(label): \(passTitle), \(schedule), \(passSubtitle)"
        }
        if case .activity = place.bookingDetails {
            let timePart = place.startTime.map { $0.timeFormatted(timeZone: timelineDisplayTimeZone) }
                ?? String(localized: "Time TBD")
            return "\(label): \(place.name), \(timePart), \(passSubtitle)"
        }
        var pieces: [String] = []
        pieces.append("\(label): \(place.name)")
        if let lead = primaryDetail() {
            pieces.append(lead)
        }
        if let start = place.startTime {
            if let end = place.endTime {
                pieces.append("\(start.timeFormatted(timeZone: timelineDisplayTimeZone)) to \(end.timeFormatted(timeZone: timelineDisplayTimeZone))")
            } else {
                pieces.append(start.timeFormatted(timeZone: timelineDisplayTimeZone))
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

private struct TimelineBookingPassMetric: Identifiable {
    let title: String
    let value: String
    var detail: String? = nil

    var id: String { title }
}

private struct TimelineBookingPassCard: View {
    let category: BookingCategory
    let eyebrow: String
    let title: String
    let subtitle: String
    let statusText: String
    let metrics: [TimelineBookingPassMetric]
    /// When set (e.g. restaurant footer), replaces the metric-column footer with stacked summary lines.
    var footerSummaryLines: [String]? = nil
    /// Optional trailing text on the title row (e.g. restaurant party size).
    var titleTrailing: String? = nil
    /// Optional trailing text on the eyebrow row (e.g. car rental pickup date); secondary, no capsule.
    var eyebrowTrailingText: String? = nil
    /// Hotel address line (timeline-only); shown with a map pin under the subtitle.
    var addressFootnote: String? = nil

    private var hasFooter: Bool {
        if let lines = footerSummaryLines, !lines.isEmpty { return true }
        return !metrics.isEmpty
    }

    private var showsEyebrowRow: Bool {
        !eyebrow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || showsStatusChip
            || !(eyebrowTrailingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private var showsStatusChip: Bool {
        !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var titleTrailingFont: Font {
        switch category {
        case .transport, .carRental, .activity:
            return .appSmall.weight(.semibold)
        default:
            return .subheadline.weight(.semibold)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            if showsEyebrowRow {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(eyebrow.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .tracking(0.7)
                        .lineLimit(1)

                    Spacer(minLength: AppSpacing.xs)

                    if showsStatusChip {
                        statusChip
                    } else if let eyebrowTrailing = eyebrowTrailingText?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !eyebrowTrailing.isEmpty {
                        Text(eyebrowTrailing)
                            .font(.footnote)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
            }

            if let trailing = titleTrailing?.trimmingCharacters(in: .whitespacesAndNewlines), !trailing.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(title)
                        .font(.timelineRowTitle)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(trailing)
                        .font(titleTrailingFont)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            } else {
                Text(title)
                    .font(.timelineRowTitle)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(3)
                .minimumScaleFactor(0.85)

            if let address = addressFootnote?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textSecondary)
                    Text(address)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Address"))
            }

            if hasFooter {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Divider()

                    if let lines = footerSummaryLines, !lines.isEmpty {
                        if lines.count == 1, let line = lines.first {
                            Text(line)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppColors.textSecondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(index == 0 ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                                        .foregroundStyle(AppColors.textSecondary)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.78)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            ForEach(Array(metrics.prefix(3).enumerated()), id: \.offset) { _, metric in
                                metricColumn(metric)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, AppSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCardChassis(
            stripeColor: category.color,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentVerticalPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.label), \(title), \(subtitle)")
    }

    private var statusChip: some View {
        Text(statusText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(category.color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(category.color.opacity(0.2), lineWidth: 0.5)
            }
    }

    private func metricColumn(_ metric: TimelineBookingPassMetric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.value)
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let detail = metric.detail {
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Text(metric.title)
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TimelineFlightBookingPassCard: View {
    /// Shared width for the center column (row-1 plane, row-2 arc, row-3 duration) so the route reads as one vertical band between flexible side columns.
    private enum LayoutMetrics {
        static let centerRouteColumnWidth: CGFloat = 72
        static let routeArcHeight: CGFloat = 16
    }

    private static let flightRouteStrokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round)

    let airlineName: String
    let carrierIATA: String?

    let departureAirport: String
    let arrivalAirport: String
    let departureTime: Date?
    let arrivalTime: Date?
    let duration: String?
    /// Supplementary summary for the card-level VoiceOver label when the
    /// status badge is hidden (e.g. Pro user before tracking).
    let statusText: String
    var showFlightStatusBadge: Bool = false
    var flightStatus: FlightStatus? = nil
    var isFlightStale: Bool = false
    var flightTint: FlightStatus.DisplayState.Tint = .neutral
    var isProUser: Bool = true
    var onFlightBadgeTap: (() -> Void)? = nil
    var onFlightUpsellTap: (() -> Void)? = nil

    var body: some View {
        header
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TimelineCardLayoutMetrics.contentHorizontalPadding)
            .padding(.vertical, TimelineCardLayoutMetrics.contentVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.07), radius: 8, y: 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let dep = departureTime?.timeFormatted ?? "departure time unknown"
        let arr = arrivalTime?.timeFormatted ?? "arrival time unknown"
        let dur = duration.map { ", duration \($0)" } ?? ""
        return "Flight \(airlineName), \(departureAirport) to \(arrivalAirport), departs \(dep), arrives \(arr)\(dur). \(statusText)"
    }

    private var header: some View {
        VStack(spacing: AppSpacing.xs) {
            rowTimesAndCenterPlane
            rowAirportCodesAndArc
            rowAirportCaptionsAndDuration
            airlineBrandingAndStatusRow
        }
    }

    /// Bottom row: airline identity (leading) · flight status pill (trailing).
    private var airlineBrandingAndStatusRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                AirlineLogoView(
                    carrierIATA: carrierIATA,
                    airlineNameFallback: airlineName,
                    variant: .timelineCard
                )
                Text(airlineName)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if showFlightStatusBadge {
                FlightStatusBadge(
                    status: flightStatus,
                    isStale: isFlightStale,
                    tint: flightTint,
                    isProUser: isProUser,
                    onUpsellTap: onFlightUpsellTap,
                    onTap: onFlightBadgeTap
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// Row 1: departure icon + time (leading) · center plane · arrival time + arrival icon (trailing).
    private var rowTimesAndCenterPlane: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "airplane.departure")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(BookingCategory.flight.color)
                Text(departureTime?.timeFormatted ?? "Time TBD")
                    .font(.appSmall.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "airplane")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(BookingCategory.flight.color)
                .frame(width: LayoutMetrics.centerRouteColumnWidth, alignment: .center)

            HStack(spacing: AppSpacing.xs) {
                Text(arrivalTime?.timeFormatted ?? "Time TBD")
                    .font(.appSmall.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
                Image(systemName: "airplane.arrival")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(BookingCategory.flight.color)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Row 2: IATA codes (primary) · route arc only.
    private var rowAirportCodesAndArc: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            Text(departureAirport)
                .font(.timelineRowTitle)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            routeArcStroke
                .frame(width: LayoutMetrics.centerRouteColumnWidth, height: LayoutMetrics.routeArcHeight)

            Text(arrivalAirport)
                .font(.timelineRowTitle)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Row 3: "Airport" captions · total duration centered under the arc.
    private var rowAirportCaptionsAndDuration: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text("Airport")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(duration ?? "—")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .frame(width: LayoutMetrics.centerRouteColumnWidth, alignment: .center)

            Text("Airport")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var routeArcStroke: some View {
        TimelineFlightRouteArc()
            .stroke(BookingCategory.flight.color.opacity(0.42), style: Self.flightRouteStrokeStyle)
    }
}

private struct TimelineFlightRouteArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        return path
    }
}


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
