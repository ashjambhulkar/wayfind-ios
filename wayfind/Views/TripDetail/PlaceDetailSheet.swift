import CoreLocation
import MapKit
import SwiftUI

struct PlaceDetailSheet: View {
    let place: Place
    let previousPlace: Place?
    var tripId: UUID? = nil

    var onEdit: () -> Void = {}
    var onMove: () -> Void = {}
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DataService.self) private var dataService

    @State private var liveEnrichment: SupabaseManager.CityPlaceEnrichmentRow?
    @State private var enrichmentLoadAttempted: Bool = false

    @State private var showingReportSheet: Bool = false
    @State private var reportToastVisible: Bool = false
    @State private var showingPhotosSheet: Bool = false
    @State private var selectedPopularDayKey: String?
    @State private var venueTimeZone: TimeZone?

    // Apple Maps style interactive stage
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapPitchEnabled: Bool = true
    @State private var showingExpandedMap = false
    @State private var aboutSummaryExpanded = false

    // MARK: - Derived Data

    private var isLikelyLoadingEnrichment: Bool {
        guard place.googlePlaceId?.isEmpty == false else { return false }
        let haveAnyEnrichment =
            place.aiSummary != nil ||
            place.aiShortSummary != nil ||
            place.rating != nil ||
            (place.whyGo?.isEmpty == false) ||
            liveEnrichment != nil
        return !haveAnyEnrichment && !enrichmentLoadAttempted
    }

    private var effectiveAISummary: String? {
        liveEnrichment?.ai_editorial_summary
        ?? place.aiSummary
        ?? place.aiShortSummary
        ?? liveEnrichment?.ai_short_summary
    }

    private var effectiveWhyGo: [String]? {
        liveEnrichment?.ai_why_go ?? place.whyGo
    }

    private var effectiveKnowBefore: [String]? {
        liveEnrichment?.ai_know_before_you_go ?? place.knowBeforeYouGo
    }

    private var effectiveWebsite: String? {
        place.website ?? liveEnrichment?.website
    }

    private var effectivePhone: String? {
        place.phoneNumber ?? liveEnrichment?.formatted_phone_number
    }

    private var effectiveRating: Double? {
        place.rating ?? liveEnrichment?.rating
    }

    private var effectiveUserRatingsTotal: Int? {
        place.userRatingsTotal ?? liveEnrichment?.user_ratings_total
    }

    private var effectivePriceLevel: Int? {
        place.priceLevel ?? liveEnrichment?.price_level
    }

    private var popularTimesModel: PopularTimesChartModel? {
        PopularTimesParsing.chartModel(from: liveEnrichment?.popular_times)
    }

    private var typicalVisitDurationLine: String? {
        TypicalVisitFormatting.line(
            minMinutes: liveEnrichment?.time_spent_min ?? place.durationMinutes,
            maxMinutes: liveEnrichment?.time_spent_max
        )
    }

    private var resolvedPopularTimesDayId: String? {
        guard let model = popularTimesModel else { return nil }
        if let key = selectedPopularDayKey, model.column(forDayId: key) != nil {
            return key
        }
        return model.preferredDayKey()
    }

    private var openingHoursDisplay: OpeningHoursDisplay? {
        OpeningHoursParsing.display(from: liveEnrichment?.opening_hours)
    }

    private var scheduleDerivedOpenNow: Bool? {
        guard let hours = openingHoursDisplay, let tz = venueTimeZone else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let row = hours.todayRow(calendar: cal) else { return nil }
        return OpeningHoursOpenEvaluator.isOpen(hoursText: row.hoursText, at: Date(), timeZone: tz)
    }

    private var effectiveIsOpenNowForHero: Bool? {
        if let fromSchedule = scheduleDerivedOpenNow {
            return fromSchedule
        }
        if let fromLive = openingHoursDisplay?.openNow {
            return fromLive
        }
        var cal = Calendar(identifier: .gregorian)
        if let tz = venueTimeZone {
            cal.timeZone = tz
        }
        if let today = openingHoursDisplay?.todayRow(calendar: cal),
           today.hoursText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "closed" {
            return false
        }
        return place.isOpenNow
    }

    private var effectiveOpeningHoursClockPill: String? {
        if let hours = openingHoursDisplay, let tz = venueTimeZone {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            if let line = hours.clockSummaryLine(calendar: cal), !line.isEmpty {
                return line
            }
        }
        if let line = openingHoursDisplay?.clockSummaryLine(), !line.isEmpty {
            return line
        }
        if let t = place.openingHoursText, !t.isEmpty {
            return t
        }
        return nil
    }

    private var attributionCaption: String? {
        let lines = PlaceAttributionFormatter.lines(
            imageSource: liveEnrichment?.image_source,
            thumbnailAttribution: liveEnrichment?.thumbnail_attribution,
            ai: liveEnrichment?.ai_source_attribution
        )
        return lines.isEmpty ? nil : lines.joined(separator: " · ")
    }

    private var hasCoordinates: Bool {
        guard let lat = place.lat, let lng = place.lng else { return false }
        return !lat.isNaN && !lng.isNaN
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard hasCoordinates, let lat = place.lat, let lng = place.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
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
                let h = mins / 60
                let m = mins % 60
                return m == 0 ? "\(h)h" : "\(h)h \(m)m"
            }
            return "\(mins) min"
        }
        if let mins = place.durationMinutes {
            let h = mins / 60
            let m = mins % 60
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

    private func priceLabel(_ level: Int) -> String {
        String(repeating: "€", count: level)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if place.isBooking {
                bookingDetailBody
            } else {
                activityDetailBody
            }
        }
        .sheet(isPresented: $showingReportSheet) {
            if let placeId = place.googlePlaceId, !placeId.isEmpty {
                ReportPlaceSheet(
                    placeName: place.name,
                    googlePlaceId: placeId
                ) { reason in
                    handleReport(reason: reason, googlePlaceId: placeId)
                }
            }
        }
        .sheet(isPresented: $showingPhotosSheet) {
            if let tripId {
                ActivityPhotosSheet(
                    activityId: place.id,
                    tripId: tripId,
                    activityTitle: place.name
                )
            }
        }
        .overlay(alignment: .top) {
            if reportToastVisible {
                ReportThankYouToast()
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Activity Detail

    private var activityDetailBody: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    mapStageHeader

                    VStack(spacing: 22) {
                        titleSection
                        routeAndTimingSection
                        

                        if let summary = effectiveAISummary {
                            aboutSection(summary)
                        } else if isLikelyLoadingEnrichment {
                            aboutSkeleton
                        }

                        popularTimesAndVisitSection
                        if let why = effectiveWhyGo, !why.isEmpty {
                            bulletCardSection(
                                title: "Why go",
                                icon: "sparkles",
                                color: AppColors.appPrimary,
                                bullets: why
                            )
                        } else if isLikelyLoadingEnrichment {
                            bulletSkeleton(title: "Why Go", icon: "sparkles", color: AppColors.appPrimary)
                        }

                        if let tips = effectiveKnowBefore, !tips.isEmpty {
                            bulletCardSection(
                                title: "Know before you go",
                                icon: "lightbulb.fill",
                                color: .orange,
                                bullets: tips
                            )
                        }

                        if let tags = place.reviewsTags, !tags.isEmpty {
                            tagsSection(tags)
                        }

                        practicalSection

                        if let notes = place.notes, !notes.isEmpty {
                            notesCard(notes)
                        }

                        if let caption = attributionCaption {
                            attributionFooter(caption: caption)
                                .padding(.top, 4)
                                .padding(.bottom, 8)
                        } else {
                            Color.clear.frame(height: 8)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(uiColor: .systemBackground))
                    )
                    .offset(y: -18)
                }
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                placeDetailBottomToolbarItems
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showingExpandedMap) {
            PlaceExpandedMapView(
                place: place,
                categorySymbol: categorySymbol,
                initialPosition: mapPosition
            )
        }
        .task {
            await refetchEnrichment(requestRefresh: true)
            updateMapCamera(animated: false)
        }
        .task(id: place.id) {
            await resolveVenueTimeZone()
            updateMapCamera(animated: false)
        }
        .onChange(of: place.id) { _, _ in
            selectedPopularDayKey = nil
            venueTimeZone = nil
            aboutSummaryExpanded = false
            updateMapCamera(animated: false)
        }
        .onChange(of: liveEnrichment?.place_id) { _, _ in
            selectedPopularDayKey = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refetchEnrichment(requestRefresh: false) }
            }
        }
    }

    // MARK: - Map Stage Header

    private var mapStageHeader: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(height: 300)

            if let coordinate {
                mapStage
                    .frame(height: 300)
            } else {
                unavailableMapStage
                    .frame(height: 300)
            }

            topMapChrome
        }
        .frame(height: 300)
        .clipped()
    }

    private var mapStage: some View {
        ZStack {
            Map(position: $mapPosition, interactionModes: [.pan, .zoom, .pitch, .rotate]) {
                if let coordinate {
                    Marker(place.name, systemImage: categorySymbol, coordinate: coordinate)
                        .tint(AppColors.appPrimary)
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .mapControlVisibility(.hidden)
            .onTapGesture {
                showingExpandedMap = true
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showingExpandedMap = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Expand map"))
                    .padding(16)
                }
            }
        }
    }

    private var unavailableMapStage: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .tertiarySystemFill),
                    Color(uiColor: .secondarySystemFill)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 12) {
                Image(systemName: "map")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Map preview unavailable")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.primary)

                Text("This place doesn’t have location coordinates yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private var topMapChrome: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close"))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ToolbarContentBuilder
    private var placeDetailBottomToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                openInMaps()
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color.primary)
            .accessibilityLabel(String(localized: "Directions"))

            Button {
                onEdit()
                dismiss()
            } label: {
                Image(systemName: "pencil")
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color.primary)
            .accessibilityLabel(String(localized: "Edit"))

            if tripId != nil {
                Button {
                    showingPhotosSheet = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .symbolRenderingMode(.monochrome)
                }
                .tint(Color.primary)
                .accessibilityLabel(String(localized: "Photos"))
            }

            Button {
                onMove()
                dismiss()
            } label: {
                Image(systemName: "arrow.right.circle")
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color.primary)
            .accessibilityLabel(String(localized: "Move"))

            Menu {
                if place.googlePlaceId?.isEmpty == false {
                    Button {
                        showingReportSheet = true
                    } label: {
                        Label(String(localized: "Report this place"), systemImage: "flag")
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color.primary)
            .accessibilityLabel(String(localized: "More"))
        }
    }

    // MARK: - Title / Metadata

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(3)

                    if let bookingDetailLine {
                        Text(bookingDetailLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: categorySymbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AppColors.appPrimary)
                    }
            }

            HStack(spacing: 8) {
                chip(categoryLabel, icon: categorySymbol)

                if let isOpen = effectiveIsOpenNowForHero {
                    statusChip(
                        text: isOpen ? "Open now" : "Closed",
                        tint: isOpen ? .green : .red
                    )
                }

                if let level = effectivePriceLevel, level > 0 {
                    chip(priceLabel(level), icon: "creditcard")
                }
            }

            HStack(spacing: 12) {
                if let rating = effectiveRating {
                    statRow(
                        icon: "star.fill",
                        text: effectiveUserRatingsTotal != nil
                        ? "\(String(format: "%.1f", rating)) • \(effectiveUserRatingsTotal!.formatted()) reviews"
                        : String(format: "%.1f", rating)
                    )
                }

                if let line = effectiveOpeningHoursClockPill, !line.isEmpty {
                    statRow(icon: "clock", text: line)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Route & Timing

    private var routeAndTimingSection: some View {
        let showVisit = scheduledTimeText != nil || durationText != nil
        let previousForRoute = gettingTherePreviousPlace

        return Group {
            if showVisit || previousForRoute != nil {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    if showVisit {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            sectionTitle("Visit")

                            HStack(alignment: .top, spacing: AppSpacing.md) {
                                if let scheduledTimeText {
                                    visitMetricTile(
                                        title: String(localized: "Time"),
                                        value: scheduledTimeText,
                                        icon: "clock"
                                    )
                                }

                                if let durationText {
                                    visitMetricTile(
                                        title: String(localized: "Duration"),
                                        value: durationText,
                                        icon: "timer"
                                    )
                                }
                            }
                        }
                    }

                    if let previous = previousForRoute {
                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            fromPreviousHeadline(previousName: previous.name)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(alignment: .top, spacing: AppSpacing.sm) {
                                ForEach(HaversineDistance.TravelMode.allCases, id: \.self) { mode in
                                    travelModeEstimateTile(
                                        mode: mode,
                                        from: previous.coordinate,
                                        to: place.coordinate
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Previous stop with valid coordinates for “Getting there” estimates.
    private var gettingTherePreviousPlace: Place? {
        guard let previous = previousPlace, hasCoordinates,
              let pLat = previous.lat, let pLng = previous.lng,
              !pLat.isNaN, !pLng.isNaN else { return nil }
        return previous
    }

    private func travelModeShortLabel(_ mode: HaversineDistance.TravelMode) -> String {
        switch mode {
        case .walking: return String(localized: "Walk")
        case .driving: return String(localized: "Drive")
        case .cycling: return String(localized: "Bike")
        case .transit: return String(localized: "Transit")
        }
    }

    private func fromPreviousHeadline(previousName: String) -> Text {
        Text(String(localized: "From"))
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
        + Text(verbatim: " ")
        + Text(previousName)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
    }

    /// Single surface per metric — no outer card wrapper.
    private func visitMetricTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.appPrimary)

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(0.6)
            }

            Text(value)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.85)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, 14)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
    }

    private func travelModeEstimateTile(
        mode: HaversineDistance.TravelMode,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> some View {
        let mins = HaversineDistance.estimateTravelTime(from: from, to: to, mode: mode)
        return VStack(spacing: 8) {
            Image(systemName: mode.sfSymbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AppColors.appPrimary)

            Text(travelModeShortLabel(mode))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.45)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("\(mins) min")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.xs)
        .padding(.vertical, AppSpacing.md)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(travelModeShortLabel(mode)), \(mins) minutes")
    }

    // MARK: - Popular Times

    @ViewBuilder
    private var popularTimesAndVisitSection: some View {
        let chart = popularTimesModel
        let visit = typicalVisitDurationLine

        if chart != nil || visit != nil {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Popular times")

                infoCard {
                    VStack(alignment: .leading, spacing: 16) {
                        if let visit {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 16))
                                    .foregroundStyle(AppColors.appPrimary)

                                Text(visit)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if let model = chart {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.days) { day in
                                        let isSelected = day.id == resolvedPopularTimesDayId
                                        Button {
                                            selectedPopularDayKey = day.id
                                        } label: {
                                            Text(day.weekdayShort)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(isSelected ? .white : .primary)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .fill(isSelected ? AppColors.appPrimary : Color(uiColor: .tertiarySystemFill))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                                    }
                                }
                            }

                            if let dayId = resolvedPopularTimesDayId,
                               let column = model.column(forDayId: dayId) {
                                PopularTimesBarChart(slots: column.slots)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - About

    private func aboutSection(_ summary: String) -> some View {
        let showMoreToggle = aboutSummaryLikelyExceedsFiveLines(summary)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("About")

            Text(summary)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .lineLimit(showMoreToggle && !aboutSummaryExpanded ? 5 : nil)
                .fixedSize(horizontal: false, vertical: true)

            if showMoreToggle {
                Button {
                    aboutSummaryExpanded.toggle()
                } label: {
                    Text(aboutSummaryExpanded ? String(localized: "Less") : String(localized: "More"))
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    aboutSummaryExpanded
                    ? String(localized: "Show less about this place")
                    : String(localized: "Show more about this place")
                )
            }
        }
        .padding(.horizontal, 20)
        .onChange(of: summary) { _, _ in
            aboutSummaryExpanded = false
        }
    }

    /// Heuristic for body text at typical sheet width (~5 lines ≈ this many characters); avoids a “More” control when the copy is short.
    private func aboutSummaryLikelyExceedsFiveLines(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 240 { return true }
        let hardLines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        return hardLines > 5
    }

    // MARK: - Bullet Cards

    private func bulletCardSection(title: String, icon: String, color: Color, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)

            infoCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(color)
                                .frame(width: 6, height: 6)
                                .padding(.top, 7)

                            Text(bullet)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineSpacing(4)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Tags

    private func tagsSection(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Popular for")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Practical Info

    private var practicalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Practical info")

            infoCard {
                VStack(alignment: .leading, spacing: 16) {
                    if let address = place.address, !address.isEmpty {
                        detailRow(icon: "mappin.circle.fill", title: "Address", value: address, tint: AppColors.appPrimary)
                    }

                    if let hours = openingHoursDisplay, !hours.rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "clock")
                                    .font(.system(size: 16))
                                    .foregroundStyle(AppColors.appPrimary)
                                    .frame(width: 22)
                                Text("Hours")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(hours.rows) { row in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(row.dayLabel)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .frame(width: 96, alignment: .leading)

                                        Text(row.hoursText)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(.leading, 34)
                        }
                    }

                    if let website = effectiveWebsite, let url = URL(string: website) {
                        Link(destination: url) {
                            detailRow(
                                icon: "globe",
                                title: "Website",
                                value: website
                                    .replacingOccurrences(of: "https://", with: "")
                                    .replacingOccurrences(of: "http://", with: "")
                                    .replacingOccurrences(of: "www.", with: ""),
                                tint: AppColors.appPrimary
                            )
                        }
                    }

                    if let phone = effectivePhone {
                        detailRow(icon: "phone", title: "Phone", value: phone, tint: .secondary)
                    }

                    let hasHours = !(openingHoursDisplay?.rows.isEmpty ?? true)
                    let hasContact = effectiveWebsite != nil || effectivePhone != nil
                    let hasAddress = place.address?.isEmpty == false

                    if !hasHours && !hasContact && !hasAddress {
                        Text("No practical details available")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Notes

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("My notes")

            infoCard {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Booking Detail Body

    private var bookingDetailBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bookingHeroStrip
                    bookingContent
                }
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemBackground))
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
                placeDetailBottomToolbarItems
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var bookingHeroStrip: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill((place.bookingCategoryEnum?.color ?? AppColors.appPrimary).opacity(0.12))
                    .frame(width: 60, height: 60)

                Image(systemName: categorySymbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.system(size: 22, weight: .semibold))
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
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)

                    Text(conf)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
                }
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground))
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

        if let notes = place.notes, !notes.isEmpty {
            notesCard(notes)
        }
    }

    private func flightContent(_ f: FlightDetails) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            bookingInfoCard {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(f.departureAirport)
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                            if let t = f.departureTime {
                                Text(t.timeFormatted)
                                    .font(.title3.weight(.medium))
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
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                            if let t = f.arrivalTime {
                                Text(t.timeFormatted)
                                    .font(.title3.weight(.medium))
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
                if !f.gate.isEmpty { bookingRow(label: "Gate", value: f.gate) }
                if !f.seat.isEmpty { bookingRow(label: "Seat", value: f.seat) }
            }
        }
    }

    private func hotelContent(_ h: HotelDetails) -> some View {
        bookingInfoCard {
            if let checkIn = h.checkInDate {
                bookingRow(label: "Check-in", value: "\(checkIn.shortFormatted)\(h.checkInTime.map { " · \($0)" } ?? "")")
            }
            if let checkOut = h.checkOutDate {
                bookingRow(label: "Check-out", value: "\(checkOut.shortFormatted)\(h.checkOutTime.map { " · \($0)" } ?? "")")
            }
            if let nights = h.nights { bookingRow(label: "Nights", value: "\(nights)") }
            if !h.roomType.isEmpty { bookingRow(label: "Room", value: h.roomType) }
        }
    }

    private func restaurantContent(_ r: RestaurantDetails) -> some View {
        bookingInfoCard {
            if let t = r.reservationTime { bookingRow(label: "Time", value: t.timeFormatted) }
            if let p = r.partySize { bookingRow(label: "Party", value: "\(p) people") }
        }
    }

    private func carRentalContent(_ c: CarRentalDetails) -> some View {
        bookingInfoCard {
            bookingRow(label: "Pick-up", value: c.pickupLocation)
            bookingRow(label: "Drop-off", value: c.dropoffLocation)
            if let t = c.pickupTime { bookingRow(label: "Pick-up time", value: t.timeFormatted) }
            if let t = c.dropoffTime { bookingRow(label: "Drop-off time", value: t.timeFormatted) }
            if !c.carType.isEmpty { bookingRow(label: "Car", value: c.carType) }
        }
    }

    private func activityContent(_ a: ActivityDetails) -> some View {
        bookingInfoCard {
            if let d = a.duration, !d.isEmpty { bookingRow(label: "Duration", value: d) }
            if !a.provider.isEmpty { bookingRow(label: "Provider", value: a.provider) }
            if !a.ticketNumber.isEmpty { bookingRow(label: "Ticket", value: a.ticketNumber) }
        }
    }

    private func transportContent(_ t: TransportDetails) -> some View {
        bookingInfoCard {
            bookingRow(label: "From", value: t.departureStation)
            bookingRow(label: "To", value: t.arrivalStation)
            if let dep = t.departureTime { bookingRow(label: "Departs", value: dep.timeFormatted) }
            if let arr = t.arrivalTime { bookingRow(label: "Arrives", value: arr.timeFormatted) }
            if !t.serviceNumber.isEmpty { bookingRow(label: "Service", value: t.serviceNumber) }
            if !t.seat.isEmpty { bookingRow(label: "Seat", value: t.seat) }
        }
    }

    private func bookingInfoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

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

    // MARK: - Helpers

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(Capsule())
    }

    private func statusChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func statRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppColors.appPrimary)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func detailRow(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                Text(value)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private var aboutSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")
            VStack(alignment: .leading, spacing: 8) {
                SkeletonView(cornerRadius: 6, height: 14)
                SkeletonView(cornerRadius: 6, height: 14)
                SkeletonView(cornerRadius: 6, height: 14)
                    .padding(.trailing, 80)
            }
        }
        .padding(.horizontal, 20)
        .accessibilityHidden(true)
    }

    private func bulletSkeleton(title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            infoCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(color.opacity(0.4))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            SkeletonView(cornerRadius: 6, height: 14)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .accessibilityHidden(true)
    }

    private func resolveVenueTimeZone() async {
        guard hasCoordinates,
              let lat = place.lat, let lng = place.lng,
              !lat.isNaN, !lng.isNaN else {
            venueTimeZone = nil
            return
        }
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: lat, longitude: lng)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            venueTimeZone = marks.first?.timeZone
        } catch {
            venueTimeZone = nil
        }
    }

    private func updateMapCamera(animated: Bool) {
        guard let coordinate else { return }

        let distance: CLLocationDistance = mapPitchEnabled ? 900 : 1400
        let pitch: CGFloat = mapPitchEnabled ? 58 : 0

        let camera = MapCamera(
            centerCoordinate: coordinate,
            distance: distance,
            heading: 0,
            pitch: pitch
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                mapPosition = .camera(camera)
            }
        } else {
            mapPosition = .camera(camera)
        }
    }

    private func openInMaps() {
        guard let coordinate else { return }
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = place.name
        mapItem.openInMaps()
    }

    private func refetchEnrichment(requestRefresh: Bool) async {
        guard let placeId = place.googlePlaceId, !placeId.isEmpty else {
            enrichmentLoadAttempted = true
            return
        }

        let service = dataService

        if requestRefresh {
            Task.detached(priority: .utility) {
                await service.requestCityPlaceEnrichment(googlePlaceId: placeId)
            }

            Task.detached(priority: .background) {
                await service.refreshCityPlaceIfStale(
                    googlePlaceId: placeId,
                    priority: "background"
                )
            }
        }

        let row = await service.fetchCityPlaceEnrichment(googlePlaceId: placeId)
        liveEnrichment = row
        enrichmentLoadAttempted = true
    }

    private func attributionFooter(caption: String) -> some View {
        Text(caption)
            .font(.system(size: 11))
            .foregroundStyle(AppColors.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attribution: \(caption)")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func handleReport(reason: ReportPlaceSheet.Reason, googlePlaceId: String) {
        Task.detached(priority: .utility) { [dataService] in
            await dataService.reportCityPlace(
                googlePlaceId: googlePlaceId,
                reason: reason.rawValue
            )
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            reportToastVisible = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                reportToastVisible = false
            }
        }
    }
}

extension HaversineDistance.TravelMode: CaseIterable {
    public static var allCases: [HaversineDistance.TravelMode] { [.walking, .driving, .cycling, .transit] }
}

private struct ReportThankYouToast: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)

            Text("Thanks — we’ll take a look.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(AppColors.appPrimary.opacity(0.95))
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Report submitted, thank you.")
    }
}