import SwiftUI

/// Booking row in the trip-detail timeline. Sibling of `TimelinePlaceCardView`
/// — same chassis, same pin column, same rhythm — distinguished by type-specific
/// content: flights use `TimelineFlightBookingPassCard`, transport uses
/// `TimelineTransportBookingCard`, activity / restaurant / car rental use
/// dedicated pass cards, and remaining kinds use `TimelineBookingPassCard`.
/// Full booking detail lives on the detail screen.
struct TimelineBookingCardView: View {
    let place: Place
    let dayNumber: Int
    var timelineDisplayTimeZone: TimeZone = .current
    /// When set, narrows the hotel card to check-in or check-out (split stay).
    var hotelTimelineRole: HotelTimelineDisplayRole? = nil
    /// When set, narrows the car rental card to pickup or drop-off (split days).
    var carRentalTimelineRole: CarRentalTimelineDisplayRole? = nil

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
    /// `true` when the booking's primary date sits outside the trip's day
    /// range — the row was forced onto the first scheduled day as a fallback.
    var isOutsideTripDates: Bool = false
    /// When this flight follows a previous flight with a layover, the compact duration
    /// string (e.g. "4h 20m"). Rendered as a transit-style spine row above the card.
    var layoverDurationText: String? = nil
    /// IATA code of the layover airport (arrival of the previous leg). Shown as
    /// "4h 20m layover in TIA" when present.
    var layoverAirport: String? = nil

    init(
        place: Place,
        dayNumber: Int,
        timelineDisplayTimeZone: TimeZone = .current,
        hotelTimelineRole: HotelTimelineDisplayRole? = nil,
        carRentalTimelineRole: CarRentalTimelineDisplayRole? = nil,
        onEdit: @escaping () -> Void = {},
        onMoveToDay: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onAttachments: (() -> Void)? = nil,
        flightStatus: FlightStatus? = nil,
        isFlightStale: Bool = false,
        flightTint: FlightStatus.DisplayState.Tint = .neutral,
        isProUser: Bool = true,
        onUpgradeTap: (() -> Void)? = nil,
        onFlightBadgeTap: (() -> Void)? = nil,
        isOutsideTripDates: Bool = false,
        layoverDurationText: String? = nil,
        layoverAirport: String? = nil
    ) {
        self.place = place
        self.dayNumber = dayNumber
        self.timelineDisplayTimeZone = timelineDisplayTimeZone
        self.hotelTimelineRole = hotelTimelineRole
        self.carRentalTimelineRole = carRentalTimelineRole
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
        self.isOutsideTripDates = isOutsideTripDates
        self.layoverDurationText = layoverDurationText
        self.layoverAirport = layoverAirport
    }

    @Environment(\.colorScheme) private var colorScheme

    private var bookingCategory: BookingCategory {
        place.bookingCategoryEnum ?? .activity
    }

    /// Car rental / activity: use booking family color instead of muted timeline chroma.
    private var carRentalBookingChrome: Color { BookingCategory.carRental.color }
    private var activityBookingChrome: Color { BookingCategory.activity.color }

    private var timelineScheduleAccent: Color {
        if bookingCategory == .carRental { return carRentalBookingChrome }
        if bookingCategory == .activity { return activityBookingChrome }
        return TimelineCategoryChroma.stripeColor(for: bookingCategory)
    }

    private var timelineSpinePinColor: Color {
        if bookingCategory == .carRental { return carRentalBookingChrome }
        if bookingCategory == .activity { return activityBookingChrome }
        return TimelineCategoryChroma.pinColor(for: bookingCategory)
    }

    /// Wall-clock instant shown on the spine (start of the row); falls back to
    /// category-specific primary times when `place.startTime` is unset.
    private var spineStartTime: Date? {
        if place.bookingCategoryEnum == .flight,
           case .flight(let details) = place.bookingDetails {
            if let start = place.startTime { return start }
            return flightDepartureTime(details)
        }
        return place.timelineSpineSortInstant(
            hotelTimelineRole: hotelTimelineRole,
            carRentalTimelineRole: carRentalTimelineRole
        )
    }

    private var spineAccessibilityLabel: String {
        if let time = spineStartTime {
            return "Starts \(time.timeFormatted(timeZone: timelineDisplayTimeZone))"
        }
        return String(localized: "Flexible time")
    }

    var body: some View {
        VStack(spacing: 0) {
            if layoverDurationText != nil {
                layoverSpineRow
            }

            HStack(alignment: .center, spacing: TimelineSpineMetrics.pinColumnToCardSpacing) {
                TimelineSpineTimeColumn(
                    startTime: spineStartTime,
                    accentColor: timelineSpinePinColor,
                    symbol: bookingCategory.sfSymbol,
                    timeZone: timelineDisplayTimeZone,
                    accessibilityLabel: spineAccessibilityLabel
                )

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    if isOutsideTripDates {
                        outsideTripDatesBanner
                    }
                    cardSurface
                }
            }
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

    /// Inline warning shown above the booking card when the booking's date
    /// falls outside the trip's day range. The booking is still rendered on
    /// the first scheduled day so it isn't hidden, but the chip explains why
    /// it's there and prompts the user to fix the date.
    private var outsideTripDatesBanner: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(AppColors.appWarning)
                .accessibilityHidden(true)
            Text("Outside trip dates · tap Edit to fix")
                .font(.appSmall.weight(.medium))
                .foregroundStyle(AppColors.appWarning)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
    }

    /// Transit-style layover connector — mirrors `TimelineGapView.collapsedRow` with a
    /// clock icon in a ringed circle on the spine rail and the duration + airport as text.
    private var layoverSpineRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            ZStack {
                Circle()
                    .fill(AppColors.appBackground)
                    .frame(
                        width: TimelineBetweenStopsMetrics.modeCircleSide,
                        height: TimelineBetweenStopsMetrics.modeCircleSide
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(
                                TimelineSpineMetrics.continuousRailColor(colorScheme: colorScheme),
                                lineWidth: TimelineSpineMetrics.continuousRailLineWidth
                            )
                    }
                Image(systemName: "clock")
                    .font(.timelineSpineTravelModeIcon)
                    .imageScale(.small)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .offset(x: -TimelineSpineMetrics.spineCenterlineNudgeLeft)
            .frame(width: TimelineBetweenStopsMetrics.timePinGutterWidth, alignment: .center)

            Text(layoverRowLabel)
                .font(.appFootnote)
                .foregroundStyle(AppColors.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 0)
        }
        .frame(minHeight: TimelineBetweenStopsMetrics.minRowHeight)
        .padding(.vertical, TimelineBetweenStopsMetrics.gapRowVerticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layoverRowLabel)
    }

    private var layoverRowLabel: String {
        guard let duration = layoverDurationText else { return "" }
        if let airport = layoverAirport, !airport.isEmpty {
            return "\(duration) layover in \(airport)"
        }
        return "\(duration) layover"
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
                displayTimeZone: timelineDisplayTimeZone,
                departureTimeZone: details.resolvedDepartureTimeZone(fallback: timelineDisplayTimeZone),
                arrivalTimeZone: details.resolvedArrivalTimeZone(fallback: timelineDisplayTimeZone),
                scheduleAccent: timelineScheduleAccent,
                statusText: flightStatusText ?? "Flight",
                showFlightStatusBadge: shouldShowFlightBadge,
                flightStatus: flightStatus,
                isFlightStale: isFlightStale,
                flightTint: flightTint,
                isProUser: isProUser,
                onFlightBadgeTap: onFlightBadgeTap,
                onFlightUpsellTap: onUpgradeTap
            )
        } else if case .transport(let transportDetails) = place.bookingDetails {
            TimelineTransportBookingCard(
                details: transportDetails,
                placeStartTime: place.startTime,
                placeEndTime: place.endTime,
                displayTimeZone: timelineDisplayTimeZone,
                stripeAccent: timelineScheduleAccent,
                confirmationChip: confirmationCode
            )
        } else if case .carRental(let carDetails) = place.bookingDetails {
            TimelineCarRentalBookingPassCard(
                stripeAccent: carRentalBookingChrome,
                role: carRentalTimelineRole ?? .pickup,
                companyName: clean(carDetails.company, fallback: TimelinePlaceDisplayName.timelineDisplay(place.name)),
                pickupLocation: carDetails.pickupLocation,
                dropoffLocation: carDetails.dropoffLocation,
                pickupTime: carDetails.pickupTime ?? place.startTime,
                dropoffTime: carDetails.dropoffTime ?? place.endTime,
                carType: carDetails.carType,
                displayTimeZone: timelineDisplayTimeZone,
                confirmationCode: confirmationValue
            )
        } else if case .activity(let activityDetails) = place.bookingDetails {
            TimelineActivityBookingPassCard(
                stripeAccent: activityBookingChrome,
                details: activityDetails,
                activityName: TimelinePlaceDisplayName.timelineDisplay(place.name),
                startTime: place.startTime,
                address: place.address,
                displayTimeZone: timelineDisplayTimeZone
            )
        } else if case .restaurant(let restaurantDetails) = place.bookingDetails {
            TimelineRestaurantBookingPassCard(
                stripeAccent: timelineScheduleAccent,
                reservationTime: restaurantDetails.reservationTime ?? place.startTime,
                displayTimeZone: timelineDisplayTimeZone,
                venueName: TimelinePlaceDisplayName.timelineDisplay(place.name),
                bookingAddress: restaurantDetails.address,
                placeAddress: place.address,
                partySize: restaurantDetails.partySize
            )
        } else {
            TimelineBookingPassCard(
                category: bookingCategory,
                stripeAccent: timelineScheduleAccent,
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

    /// Footer summary lines for timeline booking cards; `nil` when unused.
    private var timelineFooterSummaryLines: [String]? { nil }

    /// Status capsule on the eyebrow row — unused on `TimelineBookingPassCard` (title row is enough; flight uses its own card).
    private var passTimelineStatusChipText: String { "" }

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

    private var passTitleTrailingText: String? {
        transportTitleTrailingText
            ?? hotelNightsTitleTrailingText
    }

    /// Timeline hotel rows: time only (date is implied by the day header / spine).
    private func hotelTimelineTimeOnlyString(date: Date?, timeString: String?, timeZone: TimeZone) -> String {
        let trimmedTime = timeString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTime.isEmpty { return trimmedTime }
        if let date { return date.timeFormatted(timeZone: timeZone) }
        return String(localized: "TBD")
    }

    private func hotelTimelineSubtitle(_ h: HotelDetails) -> String {
        let tz = timelineDisplayTimeZone
        let checkInLabel = String(localized: "Check-in")
        let checkOutLabel = String(localized: "Check-out")
        switch hotelTimelineRole {
        case .checkIn:
            return "\(checkInLabel) · \(hotelTimelineTimeOnlyString(date: h.checkInDate, timeString: h.checkInTime, timeZone: tz))"
        case .checkOut:
            return "\(checkOutLabel) · \(hotelTimelineTimeOnlyString(date: h.checkOutDate, timeString: h.checkOutTime, timeZone: tz))"
        case nil:
            var lines: [String] = []
            if h.checkInDate != nil {
                lines.append("\(checkInLabel) · \(hotelTimelineTimeOnlyString(date: h.checkInDate, timeString: h.checkInTime, timeZone: tz))")
            }
            if h.checkOutDate != nil {
                lines.append("\(checkOutLabel) · \(hotelTimelineTimeOnlyString(date: h.checkOutDate, timeString: h.checkOutTime, timeZone: tz))")
            }
            if lines.isEmpty { return String(localized: "Dates TBD") }
            return lines.joined(separator: "\n")
        }
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
            return hotelTimelineSubtitle(h)
        case .restaurant:
            return ""
        case .carRental:
            return ""
        case .activity:
            return ""
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
        case .restaurant:
            return []
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

    private func transportAccessibilitySummary(label: String, details t: TransportDetails, scheduling: String) -> String {
        let tz = timelineDisplayTimeZone
        let from = clean(t.departureStation, fallback: String(localized: "Departure TBD"))
        let to = clean(t.arrivalStation, fallback: String(localized: "Arrival TBD"))
        let fromToLine = String(
            format: String(localized: "From %1$@ to %2$@"),
            locale: .current,
            from,
            to
        )
        let op = t.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let svc = t.serviceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let opLine: String = {
            if op.isEmpty && svc.isEmpty { return String(localized: "Operator and service not set") }
            if op.isEmpty { return svc }
            if svc.isEmpty { return op }
            return "\(op) · \(svc)"
        }()
        let timePart = TimelineTransportBookingCard.scheduleRowDisplay(
            details: t,
            placeStartTime: place.startTime,
            placeEndTime: place.endTime,
            displayTimeZone: tz
        )
        let confRaw = place.confirmationNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let confSpeak = confRaw.isEmpty ? String(localized: "Confirmation TBD") : confRaw
        return "\(label), \(confSpeak). \(fromToLine). \(timePart). \(opLine). \(scheduling)"
    }

    private func timelineRestaurantResolvedAddress(booking: RestaurantDetails, placeAddress: String?) -> String? {
        let fromBooking = booking.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromBooking.isEmpty { return fromBooking }
        let fromPlace = placeAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromPlace.isEmpty ? nil : fromPlace
    }

    private var accessibilityDescription: String {
        let scheduling = TimelineScheduleChroma.accessibilitySchedulingBucket(
            scheduleInstant: spineStartTime,
            timeZone: timelineDisplayTimeZone
        )
        let label = place.bookingCategoryEnum?.label ?? "Booking"
        if case .hotel = place.bookingDetails {
            let nightsPart = passTitleTrailingText ?? String(localized: "Nights not set")
            let addr = hotelTimelineAddressFootnote.map { ", \($0)" } ?? ""
            return "\(label): \(passTitle), \(nightsPart), \(passSubtitle)\(addr), \(scheduling)"
        }
        if case .carRental(let c) = place.bookingDetails {
            let role = carRentalTimelineRole ?? .pickup
            let company = clean(c.company, fallback: place.name)
            let locLine: String = {
                switch role {
                case .pickup:
                    let loc = c.pickupLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                    return loc.isEmpty
                        ? String(localized: "Pickup location not set")
                        : String(format: String(localized: "Pickup from %@"), locale: .current, loc)
                case .dropoff:
                    let loc = c.dropoffLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                    return loc.isEmpty
                        ? String(localized: "Drop-off location not set")
                        : String(format: String(localized: "Drop-off at %@"), locale: .current, loc)
                }
            }()
            let timePart: String = {
                let t = role == .pickup ? (c.pickupTime ?? place.startTime) : (c.dropoffTime ?? place.endTime)
                let prefix = role == .pickup ? String(localized: "Pickup") : String(localized: "Drop-off")
                if let t {
                    return "\(prefix) \(t.timeFormatted(timeZone: timelineDisplayTimeZone))"
                }
                return "\(prefix) \(String(localized: "time TBD"))"
            }()
            let carLine: String = {
                let t = c.carType.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? String(localized: "Car type not set") : t
            }()
            let confRaw = place.confirmationNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let confPart = confRaw.isEmpty ? "" : ", confirmation \(confRaw)"
            return "\(label): \(company). \(locLine). \(timePart). \(carLine)\(confPart). \(scheduling)"
        }
        if case .transport(let t) = place.bookingDetails {
            return transportAccessibilitySummary(label: label, details: t, scheduling: scheduling)
        }
        if case .activity(let a) = place.bookingDetails {
            let ticket = a.ticketNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = a.provider.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerTrail = !ticket.isEmpty ? ticket : (!provider.isEmpty ? provider : String(localized: "Details not set"))
            let startsLabel = String(localized: "Starts at")
            let timePart: String = {
                if let t = place.startTime {
                    return "\(startsLabel) · \(t.timeFormatted(timeZone: timelineDisplayTimeZone))"
                }
                return "\(startsLabel) · \(String(localized: "time TBD"))"
            }()
            let addr = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let addrPart = addr.isEmpty ? String(localized: "Address not set") : addr
            return "\(label): \(headerTrail). \(place.name). \(timePart). \(addrPart). \(scheduling)"
        }
        if case .restaurant(let r) = place.bookingDetails {
            let tz = timelineDisplayTimeZone
            let category = BookingCategory.restaurant.label
            let partyPart: String = {
                guard let p = r.partySize, p > 0 else { return "" }
                return p == 1 ? String(localized: "1 guest") : "\(p) guests"
            }()
            let headerPart = partyPart.isEmpty ? category : "\(category), \(partyPart)"
            let schedulePart: String = {
                let reservationLabel = String(localized: "Reservation")
                guard let t = r.reservationTime ?? place.startTime else {
                    return "\(reservationLabel) · \(String(localized: "time not set"))"
                }
                return "\(reservationLabel) · \(t.timeFormatted(timeZone: tz))"
            }()
            let addrPart: String = {
                if let a = timelineRestaurantResolvedAddress(booking: r, placeAddress: place.address) {
                    return a
                }
                return String(localized: "Address TBD")
            }()
            return "\(label): \(headerPart). \(place.name). \(schedulePart). \(addrPart). \(scheduling)"
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
        pieces.append(scheduling)
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
    let stripeAccent: Color   // kept for API compatibility
    let eyebrow: String       // kept for API compatibility
    let title: String
    let subtitle: String
    let statusText: String    // kept for API compatibility
    let metrics: [TimelineBookingPassMetric] // kept for API compatibility
    var footerSummaryLines: [String]? = nil  // kept for API compatibility
    /// Key datum on the eyebrow line (e.g. "2 nights", "Party of 2", "9:00 AM").
    var titleTrailing: String? = nil
    var eyebrowTrailingText: String? = nil   // kept for API compatibility
    var addressFootnote: String? = nil       // kept for API compatibility

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            eyebrowRow
            nameRow
            detailRow
            addressFootnoteRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCardChassis(
            stripeColor: stripeAccent,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Rows

    /// "Hotel · 2 nights" — tinted category label signals confirmed booking vs activity.
    private var eyebrowRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Text(category.label)
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(TimelineCategoryChroma.pinColor(for: category))
                .lineLimit(1)

            if let trailing = titleTrailing?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trailing.isEmpty {
                Text("·")
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(trailing)
                    .font(.appFootnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Venue / company / operator name.
    private var nameRow: some View {
        Text(title)
            .font(.timelineRowTitle)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    /// Route, dates, or reservation time — secondary confirmation at a glance.
    @ViewBuilder
    private var detailRow: some View {
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(.appFootnote)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(3)
                .minimumScaleFactor(0.88)
        }
    }

    /// Property / venue address (e.g. hotel) under the schedule line.
    @ViewBuilder
    private var addressFootnoteRow: some View {
        let trimmed = addressFootnote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)

                Text(trimmed)
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, AppSpacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Address"))
            .accessibilityValue(trimmed)
        }
    }

    private var accessibilityText: String {
        let trailing = titleTrailing.map { ", \($0)" } ?? ""
        let detail = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let addr = addressFootnote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if addr.isEmpty {
            return "\(category.label)\(trailing): \(title). \(detail)"
        }
        return "\(category.label)\(trailing): \(title). \(detail). \(addr)"
    }
}

// MARK: - Car rental (timeline — pickup / drop-off cards)

private struct TimelineCarRentalBookingPassCard: View {
    let stripeAccent: Color
    let role: CarRentalTimelineDisplayRole
    let companyName: String
    let pickupLocation: String
    let dropoffLocation: String
    let pickupTime: Date?
    let dropoffTime: Date?
    let carType: String
    let displayTimeZone: TimeZone
    let confirmationCode: String

    private var categoryTint: Color { BookingCategory.carRental.color }

    private func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayCompany: String {
        let t = trimmed(companyName)
        return t.isEmpty ? String(localized: "Rental company TBD") : t
    }

    private var locationLine: String {
        switch role {
        case .pickup:
            let loc = trimmed(pickupLocation)
            if loc.isEmpty { return String(localized: "Pickup location TBD") }
            return String(format: String(localized: "Pickup from %@"), locale: .current, loc)
        case .dropoff:
            let loc = trimmed(dropoffLocation)
            if loc.isEmpty { return String(localized: "Drop-off location TBD") }
            return String(format: String(localized: "Drop-off at %@"), locale: .current, loc)
        }
    }

    private var legScheduleInstant: Date? {
        switch role {
        case .pickup: return pickupTime
        case .dropoff: return dropoffTime
        }
    }

    private var timeRowText: String {
        let prefix = role == .pickup ? String(localized: "Pickup") : String(localized: "Drop-off")
        if let t = legScheduleInstant {
            return "\(prefix) · \(t.timeFormatted(timeZone: displayTimeZone))"
        }
        return "\(prefix) · \(String(localized: "time TBD"))"
    }

    private var carTypeLine: String {
        let t = trimmed(carType)
        if t.isEmpty { return String(localized: "Car type TBD") }
        return String(format: String(localized: "Car type · %@"), locale: .current, t)
    }

    private var confirmationFootnote: String? {
        let trimmedCode = confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCode != "—", !trimmedCode.isEmpty else { return nil }
        return "#\(trimmedCode)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(BookingCategory.carRental.label)
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(categoryTint)
                    .lineLimit(1)
                Text("·")
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(displayCompany)
                    .font(.appFootnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(locationLine)
                .font(.timelineRowTitle)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            Text(timeRowText)
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.88)

            Text(carTypeLine)
                .font(.appFootnote)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(2)

            if let confDisplay = confirmationFootnote {
                Text(confDisplay)
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
                    .accessibilityLabel(String(localized: "Confirmation"))
                    .accessibilityValue(confDisplay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCardChassis(
            stripeColor: stripeAccent,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [BookingCategory.carRental.label, displayCompany, locationLine, timeRowText, carTypeLine]
        if let confirmationFootnote { parts.append(confirmationFootnote) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Activity (timeline-only layout)

private struct TimelineActivityBookingPassCard: View {
    let stripeAccent: Color
    let details: ActivityDetails
    let activityName: String
    let startTime: Date?
    let address: String?
    let displayTimeZone: TimeZone

    private var categoryTint: Color { BookingCategory.activity.color }

    private func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ticket number when set; otherwise provider (e.g. Viator).
    private var ticketOrProviderLine: String {
        let ticket = trimmed(details.ticketNumber)
        if !ticket.isEmpty { return ticket }
        let provider = trimmed(details.provider)
        if !provider.isEmpty { return provider }
        return String(localized: "Details TBD")
    }

    private var displayActivityName: String {
        let t = trimmed(activityName)
        return t.isEmpty ? String(localized: "Activity TBD") : t
    }

    private var startsAtScheduleText: String {
        let startsLabel = String(localized: "Starts at")
        guard let t = startTime else {
            return "\(startsLabel) · \(String(localized: "time TBD"))"
        }
        return "\(startsLabel) · \(t.timeFormatted(timeZone: displayTimeZone))"
    }

    private var resolvedAddress: String? {
        let a = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty ? nil : a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(BookingCategory.activity.label)
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(categoryTint)
                    .lineLimit(1)
                Text("·")
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(ticketOrProviderLine)
                    .font(.appFootnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(displayActivityName)
                .font(.timelineRowTitle)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text(startsAtScheduleText)
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.88)
                .accessibilityLabel(String(localized: "Starts at"))

            if let line = resolvedAddress {
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.appFootnote.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.appFootnote)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(String(localized: "Address TBD"))
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCardChassis(
            stripeColor: stripeAccent,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [
            BookingCategory.activity.label,
            ticketOrProviderLine,
            displayActivityName,
            startsAtScheduleText
        ]
        if let resolvedAddress {
            parts.append(resolvedAddress)
        } else {
            parts.append(String(localized: "Address TBD"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Restaurant (timeline-only layout)

private struct TimelineRestaurantBookingPassCard: View {
    let stripeAccent: Color
    let reservationTime: Date?
    let displayTimeZone: TimeZone
    let venueName: String
    let bookingAddress: String?
    let placeAddress: String?
    let partySize: Int?

    private var categoryTint: Color { TimelineCategoryChroma.pinColor(for: BookingCategory.restaurant) }

    private var guestsLabel: String? {
        guard let p = partySize, p > 0 else { return nil }
        return p == 1 ? String(localized: "1 guest") : "\(p) guests"
    }

    /// Label + wall time for the reservation row (trip destination timezone).
    private var reservationScheduleText: String {
        let reservationLabel = String(localized: "Reservation")
        guard let t = reservationTime else {
            return "\(reservationLabel) · \(String(localized: "time TBD"))"
        }
        let timePart = t.timeFormatted(timeZone: displayTimeZone)
        return "\(reservationLabel) · \(timePart)"
    }

    private var resolvedAddress: String? {
        let b = bookingAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !b.isEmpty { return b }
        let p = placeAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? nil : p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            categoryAndGuestsRow

            Text(venueName)
                .font(.timelineRowTitle)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text(reservationScheduleText)
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.88)
                .accessibilityLabel(String(localized: "Reservation"))

            addressRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCardChassis(
            stripeColor: stripeAccent,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Top line: **Restaurant · N guests** (guests omitted when party size unset).
    private var categoryAndGuestsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Text(BookingCategory.restaurant.label)
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(categoryTint)
                .lineLimit(1)

            if let guestsLabel {
                Text("·")
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(guestsLabel)
                    .font(.appFootnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    /// Final row: venue address from booking or place, or placeholder when missing.
    @ViewBuilder
    private var addressRow: some View {
        if let line = resolvedAddress {
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)

                Text(line)
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Address"))
            .accessibilityValue(line)
        } else {
            Text(String(localized: "Address TBD"))
                .font(.appFootnote)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(2)
                .accessibilityLabel(String(localized: "Address"))
                .accessibilityValue(String(localized: "Address TBD"))
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = [BookingCategory.restaurant.label]
        if let guestsLabel { parts.append(guestsLabel) }
        parts.append(venueName)
        parts.append(reservationScheduleText)
        if let resolvedAddress {
            parts.append(resolvedAddress)
        } else {
            parts.append(String(localized: "Address TBD"))
        }
        return parts.joined(separator: ", ")
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
    /// Fallback timezone used when per-airport timezones are not available.
    var displayTimeZone: TimeZone = .current
    /// Airport-specific timezone for the departure endpoint.
    var departureTimeZone: TimeZone = .current
    /// Airport-specific timezone for the arrival endpoint.
    var arrivalTimeZone: TimeZone = .current
    /// Route / plane glyph tint aligned with spine (local departure time bucket).
    let scheduleAccent: Color
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
            .shadow(
                color: Color.black.opacity(TimelineCardLayoutMetrics.cardShadowOpacity),
                radius: TimelineCardLayoutMetrics.cardShadowRadius,
                x: 0,
                y: TimelineCardLayoutMetrics.cardShadowYOffset
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
    }

    private var resolvedDepartureTimeZone: TimeZone { departureTimeZone }
    private var resolvedArrivalTimeZone: TimeZone { arrivalTimeZone }

    private func depTimeLabel(_ instant: Date) -> String {
        instant.timeFormatted(timeZone: resolvedDepartureTimeZone)
    }

    private func arrTimeLabel(_ instant: Date) -> String {
        instant.timeFormatted(timeZone: resolvedArrivalTimeZone)
    }

    private var accessibilitySummary: String {
        let depTZ = resolvedDepartureTimeZone
        let arrTZ = resolvedArrivalTimeZone
        let dep = departureTime.map { "\($0.timeFormatted(timeZone: depTZ)) \($0.timeZoneAbbreviation(timeZone: depTZ))" } ?? "departure time unknown"
        let arr = arrivalTime.map { "\($0.timeFormatted(timeZone: arrTZ)) \($0.timeZoneAbbreviation(timeZone: arrTZ))" } ?? "arrival time unknown"
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
                    .font(.appFootnote.weight(.semibold))
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
                    showsSecondarySubtitle: false,
                    onUpsellTap: onFlightUpsellTap,
                    onTap: onFlightBadgeTap
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// Row 1: departure icon + time + tz abbreviation (leading) · center plane · arrival time + tz + icon (trailing).
    private var rowTimesAndCenterPlane: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "airplane.departure")
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(scheduleAccent)
                if let dep = departureTime {
                    Text(depTimeLabel(dep))
                        .font(.appFootnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textSecondary)
                    Text(dep.timeZoneAbbreviation(timeZone: resolvedDepartureTimeZone))
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                } else {
                    Text("Time TBD")
                        .font(.appFootnote.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "airplane")
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(scheduleAccent)
                .frame(width: LayoutMetrics.centerRouteColumnWidth, alignment: .center)

            HStack(spacing: AppSpacing.xs) {
                if let arr = arrivalTime {
                    if let depDate = departureTime,
                       let offsetLabel = Date.dayOffsetLabel(
                            from: depDate, in: resolvedDepartureTimeZone,
                            to: arr, in: resolvedArrivalTimeZone) {
                        Text(offsetLabel)
                            .font(.appSmall.weight(.semibold))
                            .foregroundStyle(AppColors.appPrimary)
                    }
                    Text(arr.timeZoneAbbreviation(timeZone: resolvedArrivalTimeZone))
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                    Text(arrTimeLabel(arr))
                        .font(.appFootnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    Text("Time TBD")
                        .font(.appFootnote.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                }
                Image(systemName: "airplane.arrival")
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(scheduleAccent)
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
                .font(.appFootnote)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(duration ?? "—")
                .font(.appFootnote)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .frame(width: LayoutMetrics.centerRouteColumnWidth, alignment: .center)

            Text("Airport")
                .font(.appFootnote)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var routeArcStroke: some View {
        TimelineFlightRouteArc()
            .stroke(scheduleAccent.opacity(0.42), style: Self.flightRouteStrokeStyle)
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
