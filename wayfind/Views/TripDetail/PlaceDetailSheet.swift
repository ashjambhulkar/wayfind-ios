import MapKit
import SwiftUI

struct PlaceDetailSheet: View {
    let place: Place
    let previousPlace: Place?

    var onEdit: () -> Void = {}
    var onMove: () -> Void = {}
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    // MARK: – Computed helpers

    private var hasCoordinates: Bool {
        guard let lat = place.lat, let lng = place.lng else { return false }
        return !lat.isNaN && !lng.isNaN
    }

    private var categorySymbol: String {
        place.isBooking ? (place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill") : place.categoryEnum.sfSymbol
    }

    private var categoryLabel: String {
        place.isBooking ? (place.bookingCategoryEnum?.label ?? "Booking") : place.categoryEnum.label
    }

    private var scheduledTimeText: String? {
        switch (place.startTime, place.endTime) {
        case let (s?, e?): return "\(s.timeFormatted) – \(e.timeFormatted)"
        case let (s?, nil): return s.timeFormatted
        default: return nil
        }
    }

    private var durationText: String? {
        if let s = place.startTime, let e = place.endTime {
            let mins = Int(e.timeIntervalSince(s) / 60)
            if mins >= 60 {
                let h = mins / 60, m = mins % 60
                return m == 0 ? "\(h)h" : "\(h)h \(m)m"
            }
            return "\(mins) min"
        }
        if let mins = place.durationMinutes {
            let h = mins / 60, m = mins % 60
            return m == 0 ? "~\(h)h" : "~\(h)h \(m)m"
        }
        return nil
    }

    private var bookingDetailLine: String? {
        guard place.isBooking, let details = place.bookingDetails else { return nil }
        switch details {
        case .flight(let f): return "\(f.departureAirport) → \(f.arrivalAirport)"
        case .hotel(let h): return h.nights.map { "\($0) nights · \(h.roomType)" } ?? "Hotel"
        case .restaurant(let r): return r.partySize.map { "Party of \($0)" } ?? "Reservation"
        case .carRental(let c): return "\(c.pickupLocation) → \(c.dropoffLocation)"
        case .activity(let a): return a.duration?.isEmpty == false ? a.duration! : a.provider
        case .transport(let t): return "\(t.departureStation) → \(t.arrivalStation)"
        }
    }

    private func priceLabel(_ level: Int) -> String { String(repeating: "€", count: level) }

    // MARK: – Body

    var body: some View {
        if place.isBooking {
            bookingDetailBody
        } else {
            activityDetailBody
        }
    }

    // MARK: – Activity detail (museums, restaurants, parks, attractions…)

    private var activityDetailBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader

                VStack(alignment: .leading, spacing: 0) {
                    if scheduledTimeText != nil {
                        scheduleCard
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                    }

                    if let summary = place.aiSummary ?? place.aiShortSummary {
                        aboutSection(summary: summary)
                    }

                    if let bullets = place.whyGo, !bullets.isEmpty {
                        bulletSection(title: "Why Go", icon: "sparkles", bullets: bullets, color: AppColors.appPrimary)
                    }

                    if let tips = place.knowBeforeYouGo, !tips.isEmpty {
                        bulletSection(title: "Know Before You Go", icon: "lightbulb.fill", bullets: tips, color: .orange)
                    }

                    if let tags = place.reviewsTags, !tags.isEmpty {
                        tagsRow(tags: tags)
                    }

                    gettingThereSection

                    if place.website != nil || place.phoneNumber != nil {
                        contactSection
                    }

                    if let notes = place.notes, !notes.isEmpty {
                        notesSection(notes: notes)
                    }

                    actionsSection
                        .padding(.bottom, 40)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: – Booking detail (flights, hotels, restaurants with reservations, car rentals…)

    private var bookingDetailBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    bookingHeroStrip
                    bookingContent
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle(categoryLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // ── Booking hero strip (no full-bleed image — functional info first) ───

    private var bookingHeroStrip: some View {
        HStack(spacing: 16) {
            // Category icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((place.bookingCategoryEnum?.color ?? AppColors.appPrimary).opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: categorySymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                if let provider = bookingProvider {
                    Text(provider)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let conf = place.confirmationNumber, !conf.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CONF.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)
                    Text(conf)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
                }
            }
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var bookingProvider: String? {
        guard let details = place.bookingDetails else { return nil }
        switch details {
        case .flight(let f): return f.airline
        case .hotel: return nil
        case .restaurant: return nil
        case .carRental(let c): return c.company
        case .activity(let a): return a.provider
        case .transport(let t): return t.operatorName
        }
    }

    // ── Booking-specific content ────────────────────────────────────────────

    @ViewBuilder
    private var bookingContent: some View {
        if let details = place.bookingDetails {
            switch details {
            case .flight(let f): flightContent(f)
            case .hotel(let h): hotelContent(h)
            case .restaurant(let r): restaurantContent(r)
            case .carRental(let c): carRentalContent(c)
            case .activity(let a): activityContent(a)
            case .transport(let t): transportContent(t)
            }
        }

        // Common: user notes
        if let notes = place.notes, !notes.isEmpty {
            notesSection(notes: notes)
        }

        // Common: actions
        actionsSection
            .padding(.bottom, 40)
    }

    // Flight
    private func flightContent(_ f: FlightDetails) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Route visual
            bookingInfoCard {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(f.departureAirport)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            if let t = f.departureTime {
                                Text(t.timeFormatted)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(t.shortFormatted)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                        Image(systemName: "airplane")
                            .font(.system(size: 22))
                            .foregroundStyle(BookingCategory.flight.color)
                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(f.arrivalAirport)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            if let t = f.arrivalTime {
                                Text(t.timeFormatted)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(t.shortFormatted)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            bookingInfoCard {
                bookingRow(label: "Flight", value: "\(f.airline) \(f.flightNumber)")
                if !f.terminal.isEmpty { bookingRow(label: "Terminal", value: f.terminal) }
                if !f.gate.isEmpty     { bookingRow(label: "Gate",     value: f.gate) }
                if !f.seat.isEmpty     { bookingRow(label: "Seat",     value: f.seat) }
            }
        }
    }

    // Hotel
    private func hotelContent(_ h: HotelDetails) -> some View {
        bookingInfoCard {
            if let checkIn = h.checkInDate {
                bookingRow(label: "Check-in",  value: "\(checkIn.shortFormatted)\(h.checkInTime.map { " · \($0)" } ?? "")")
            }
            if let checkOut = h.checkOutDate {
                bookingRow(label: "Check-out", value: "\(checkOut.shortFormatted)\(h.checkOutTime.map { " · \($0)" } ?? "")")
            }
            if let nights = h.nights        { bookingRow(label: "Nights",    value: "\(nights)") }
            if !h.roomType.isEmpty          { bookingRow(label: "Room",      value: h.roomType) }
        }
    }

    // Restaurant
    private func restaurantContent(_ r: RestaurantDetails) -> some View {
        bookingInfoCard {
            if let t = r.reservationTime { bookingRow(label: "Time",  value: t.timeFormatted) }
            if let p = r.partySize       { bookingRow(label: "Party", value: "\(p) people") }
        }
    }

    // Car rental
    private func carRentalContent(_ c: CarRentalDetails) -> some View {
        bookingInfoCard {
            bookingRow(label: "Pick-up",    value: c.pickupLocation)
            bookingRow(label: "Drop-off",   value: c.dropoffLocation)
            if let t = c.pickupTime        { bookingRow(label: "Pick-up time",  value: t.timeFormatted) }
            if let t = c.dropoffTime       { bookingRow(label: "Drop-off time", value: t.timeFormatted) }
            if !c.carType.isEmpty          { bookingRow(label: "Car",           value: c.carType) }
        }
    }

    // Activity
    private func activityContent(_ a: ActivityDetails) -> some View {
        bookingInfoCard {
            if let d = a.duration, !d.isEmpty { bookingRow(label: "Duration", value: d) }
            if !a.provider.isEmpty             { bookingRow(label: "Provider", value: a.provider) }
            if !a.ticketNumber.isEmpty         { bookingRow(label: "Ticket",   value: a.ticketNumber) }
        }
    }

    // Transport
    private func transportContent(_ t: TransportDetails) -> some View {
        bookingInfoCard {
            bookingRow(label: "From",     value: t.departureStation)
            bookingRow(label: "To",       value: t.arrivalStation)
            if let dep = t.departureTime { bookingRow(label: "Departs", value: dep.timeFormatted) }
            if let arr = t.arrivalTime   { bookingRow(label: "Arrives", value: arr.timeFormatted) }
            if !t.serviceNumber.isEmpty  { bookingRow(label: "Service", value: t.serviceNumber) }
            if !t.seat.isEmpty           { bookingRow(label: "Seat",    value: t.seat) }
        }
    }

    // Shared booking card wrapper
    private func bookingInfoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // Shared label-value row inside booking cards
    private func bookingRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    // MARK: – Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            // Image
            Group {
                if let urlStr = place.heroImageUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            placeholderGradient
                        }
                    }
                } else {
                    placeholderGradient
                }
            }
            .frame(height: 280)
            .clipped()

            // Gradient overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )

            // Overlay content
            VStack(alignment: .leading, spacing: 8) {
                // Category + open badge
                HStack {
                    Label(categoryLabel, systemImage: categorySymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Capsule())

                    Spacer()

                    if let isOpen = place.isOpenNow {
                        Text(isOpen ? "Open" : "Closed")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isOpen ? .white : Color(UIColor.systemRed))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isOpen ? Color.green.opacity(0.85) : Color(UIColor.systemBackground).opacity(0.9))
                            .clipShape(Capsule())
                    }
                }

                // Place name
                Text(place.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                // Rating + price row
                HStack(spacing: 12) {
                    if let rating = place.rating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            if let total = place.userRatingsTotal {
                                Text("(\(total.formatted()))")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }

                    if let level = place.priceLevel, level > 0 {
                        Text(priceLabel(level))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    if let hours = place.openingHoursText, place.isOpenNow != nil {
                        Text(hours)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 280)
        .overlay(alignment: .topLeading) {
            // Close button
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .padding(.top, 50)
        }
    }

    private var placeholderGradient: some View {
        let colors: [Color] = {
            switch place.categoryEnum {
            case .attraction: return [Color(hue: 0.58, saturation: 0.6, brightness: 0.5), Color(hue: 0.62, saturation: 0.7, brightness: 0.35)]
            case .restaurant: return [Color(hue: 0.05, saturation: 0.7, brightness: 0.55), Color(hue: 0.08, saturation: 0.6, brightness: 0.35)]
            case .nature: return [Color(hue: 0.35, saturation: 0.5, brightness: 0.45), Color(hue: 0.38, saturation: 0.6, brightness: 0.3)]
            case .nightlife: return [Color(hue: 0.75, saturation: 0.6, brightness: 0.3), Color(hue: 0.8, saturation: 0.7, brightness: 0.2)]
            case .shopping: return [Color(hue: 0.0, saturation: 0.5, brightness: 0.5), Color(hue: 0.95, saturation: 0.6, brightness: 0.35)]
            default: return [Color(hue: 0.55, saturation: 0.4, brightness: 0.5), Color(hue: 0.58, saturation: 0.5, brightness: 0.35)]
            }
        }()
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Schedule Card

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                // Time
                if let timeText = scheduledTimeText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TIME")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .kerning(0.5)
                        Text(timeText)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                if scheduledTimeText != nil && durationText != nil {
                    Color(UIColor.separator).frame(width: 0.5, height: 36)
                }

                // Duration
                if let dur = durationText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DURATION")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .kerning(0.5)
                        Text(dur)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                Spacer()

                // Confirmation number for bookings
                if let conf = place.confirmationNumber, !conf.isEmpty {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("CONFIRMATION")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .kerning(0.5)
                        Text(conf)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppColors.appPrimary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: – About

    private func aboutSection(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("About")
            Text(summary)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: – Bullet sections (Why Go / Know Before You Go)

    private func bulletSection(title: String, icon: String, bullets: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(bullet)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(3)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: – Reviews tags

    private func tagsRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.tertiarySystemFill))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 16)
    }

    // MARK: – Getting There

    private var gettingThereSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Getting There")

            // Travel time from previous stop
            if let previous = previousPlace, hasCoordinates,
               let pLat = previous.lat, let pLng = previous.lng,
               !pLat.isNaN, !pLng.isNaN {

                Text("From \(previous.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(HaversineDistance.TravelMode.allCases, id: \.self) { mode in
                        let mins = HaversineDistance.estimateTravelTime(
                            from: previous.coordinate, to: place.coordinate, mode: mode
                        )
                        VStack(spacing: 4) {
                            Image(systemName: mode.sfSymbol)
                                .font(.system(size: 18))
                                .foregroundStyle(AppColors.appPrimary)
                            Text("\(mins) min")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                Text("First stop of the day")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // Address + navigate
            if let address = place.address, !address.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AppColors.appPrimary)
                    Text(address)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }

                if hasCoordinates {
                    Button {
                        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                        mapItem.name = place.name
                        mapItem.openInMaps()
                    } label: {
                        Label("Navigate", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(AppColors.appPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: – Contact

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Contact")

            if let website = place.website, let url = URL(string: website) {
                Link(destination: url) {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 16))
                            .foregroundStyle(AppColors.appPrimary)
                            .frame(width: 24)
                        Text(website
                            .replacingOccurrences(of: "https://", with: "")
                            .replacingOccurrences(of: "http://", with: "")
                            .replacingOccurrences(of: "www.", with: ""))
                            .font(.body)
                            .foregroundStyle(AppColors.appPrimary)
                            .lineLimit(1)
                    }
                }
            }

            if let phone = place.phoneNumber {
                HStack(spacing: 12) {
                    Image(systemName: "phone")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(phone)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: – Notes

    private func notesSection(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Notes")
            Text(notes)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: – Booking details

    // MARK: – Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.top, 32)
                .padding(.horizontal, 20)

            HStack(spacing: 0) {
                actionButton(label: "Edit", icon: "pencil") { onEdit(); dismiss() }
                Divider().frame(height: 20)
                actionButton(label: "Move", icon: "arrow.right.circle") { onMove(); dismiss() }
                Divider().frame(height: 20)
                actionButton(label: "Delete", icon: "trash", destructive: true) { onDelete(); dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    private func actionButton(label: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(destructive ? Color(UIColor.systemRed) : AppColors.appPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: – Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }
}

extension HaversineDistance.TravelMode: CaseIterable {
    public static var allCases: [HaversineDistance.TravelMode] { [.walking, .driving, .cycling, .transit] }
}


// =============================================================================

