import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct PlaceDetailSheet: View {
    let place: Place
    let previousPlace: Place?
    var tripId: UUID? = nil
    /// Trip destination timezone passed in by the parent (the timeline already
    /// knows it). When non-nil this is used directly for booking date/time
    /// rendering and the local geocode is skipped — avoids `CLGeocoder`
    /// throttling and a flash of device-TZ content while we re-resolve.
    var injectedDisplayTimeZone: TimeZone? = nil

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
    /// Trip destination timezone (resolved from the trip's lat/lng). Used so
    /// booking dates/times in the detail sheet read in the same clock as the
    /// timeline. Falls back to device TZ when no trip context is present
    /// (e.g. the standalone preview host).
    @State private var tripDisplayTimeZone: TimeZone?

    // Apple Maps style interactive stage
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapPitchEnabled: Bool = true
    @State private var showingExpandedMap = false
    @State private var aboutSummaryExpanded = false

    init(
        place: Place,
        previousPlace: Place?,
        tripId: UUID? = nil,
        injectedDisplayTimeZone: TimeZone? = nil,
        initialEnrichment: SupabaseManager.CityPlaceEnrichmentRow? = nil,
        onEdit: @escaping () -> Void = {},
        onMove: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) {
        self.place = place
        self.previousPlace = previousPlace
        self.tripId = tripId
        self.injectedDisplayTimeZone = injectedDisplayTimeZone
        self.onEdit = onEdit
        self.onMove = onMove
        self.onDelete = onDelete
        _liveEnrichment = State(initialValue: initialEnrichment)
        _enrichmentLoadAttempted = State(initialValue: false)
        _showingReportSheet = State(initialValue: false)
        _reportToastVisible = State(initialValue: false)
        _showingPhotosSheet = State(initialValue: false)
        _selectedPopularDayKey = State(initialValue: nil)
        _venueTimeZone = State(initialValue: nil)
        _tripDisplayTimeZone = State(initialValue: nil)
        _mapPosition = State(initialValue: .automatic)
        _mapPitchEnabled = State(initialValue: true)
        _showingExpandedMap = State(initialValue: false)
        _aboutSummaryExpanded = State(initialValue: false)
    }

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
        let lines = PlaceAttributionFormatter.lines(ai: liveEnrichment?.ai_source_attribution)
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
        let tz = bookingDisplayTimeZone
        switch (place.startTime, place.endTime) {
        case let (s?, e?): return "\(s.timeFormatted(timeZone: tz)) – \(e.timeFormatted(timeZone: tz))"
        case let (s?, nil): return s.timeFormatted(timeZone: tz)
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
        case .hotel(let h):
            let room = h.roomType.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = h.nights {
                if room.isEmpty { return "\(n) nights" }
                return "\(n) nights · \(room)"
            }
            if !room.isEmpty { return room }
            return "Hotel"
        case .restaurant(let r): return r.partySize.map { "Party of \($0)" } ?? "Reservation"
        case .carRental(let c):
            let pick = c.pickupLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            let drop = c.dropoffLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            if pick.isEmpty, drop.isEmpty { return String(localized: "Car rental") }
            if pick.isEmpty { return drop }
            if drop.isEmpty { return pick }
            return "\(pick) → \(drop)"
        case .activity(let a):
            let prov = a.provider.trimmingCharacters(in: .whitespacesAndNewlines)
            let dur = a.duration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !dur.isEmpty, !prov.isEmpty { return "\(dur) · \(prov)" }
            if !dur.isEmpty { return dur }
            if !prov.isEmpty { return prov }
            return String(localized: "Activity")
        case .transport(let t):
            let dep = t.departureStation.trimmingCharacters(in: .whitespacesAndNewlines)
            let arr = t.arrivalStation.trimmingCharacters(in: .whitespacesAndNewlines)
            if dep.isEmpty, arr.isEmpty { return String(localized: "Transport") }
            if dep.isEmpty { return arr }
            if arr.isEmpty { return dep }
            return "\(dep) → \(arr)"
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
                    .safeAreaPadding(.top, 8)
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

                        if let notes = place.notes, !notes.isEmpty {
                            notesCard(notes)
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
            .ignoresSafeArea(edges: .top)
            .placeDetailHideTopScrollEdgeEffect()
            .background(Color.clear)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                placeDetailDismissToolbarItem
                placeDetailBottomToolbarItems
            }
        }
        .background(PlaceDetailTransparentNavBarHook())
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
            if injectedDisplayTimeZone == nil {
                await resolveTripDisplayTimeZone()
            }
            updateMapCamera(animated: false)
        }
        .onChange(of: place.id) { _, _ in
            selectedPopularDayKey = nil
            venueTimeZone = nil
            tripDisplayTimeZone = nil
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
        Group {
            if hasCoordinates {
                mapStage
                    .frame(height: 300)
            } else {
                unavailableMapStage
                    .frame(height: 300)
            }
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
            .mapStyle(.standard(elevation: .realistic, emphasis: .automatic))
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
                            .font(.subheadline.weight(.medium))
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
                    .font(.title.weight(.medium))
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

    @ToolbarContentBuilder
    private var placeDetailDismissToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // Avoid a fixed-size frame on the label — it fights `UINavigationBar` layout
            // and makes the xmark glyph look off-center (“crooked”).
            Button(role: .cancel) {
                dismiss()
            } label: {
                Label(String(localized: "Close"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.appBody.weight(.medium))
                    // System primary keeps contrast over the map hero; booking sheet uses the same control.
                    .foregroundStyle(Color.primary)
            }
        }
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

            if !place.isBooking, tripId != nil {
                Button {
                    showingPhotosSheet = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .symbolRenderingMode(.monochrome)
                }
                .tint(Color.primary)
                .accessibilityLabel(String(localized: "Photos"))
            }

            if !place.isBooking {
                Button {
                    onMove()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .symbolRenderingMode(.monochrome)
                }
                .tint(Color.primary)
                .accessibilityLabel(String(localized: "Move"))
            }

            Menu {
                if place.isBooking {
                    if tripId != nil {
                        Button {
                            showingPhotosSheet = true
                        } label: {
                            Label(String(localized: "Photos"), systemImage: "photo.on.rectangle.angled")
                        }
                    }
                    Button {
                        onMove()
                        dismiss()
                    } label: {
                        Label(String(localized: "Move to Day"), systemImage: "arrow.right.circle")
                    }
                }
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
                        .font(.title.weight(.semibold))
                        .fontDesign(.rounded)
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
                            .font(.headline.weight(.medium))
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
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            if let scheduledTimeText {
                                visitMetricTile(
                                    title: String(localized: "Schedule"),
                                    value: scheduledTimeText,
                                    icon: "clock"
                                )
                            }

                            if let durationText {
                                visitMetricTile(
                                    title: String(localized: "Visit length"),
                                    value: durationText,
                                    icon: "timer"
                                )
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppColors.appPrimary)

                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(0.45)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Text(value)
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.85)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }

    private func travelModeEstimateTile(
        mode: HaversineDistance.TravelMode,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> some View {
        let mins = HaversineDistance.estimateTravelTime(from: from, to: to, mode: mode)
        return VStack(spacing: 6) {
            Image(systemName: mode.sfSymbol)
                .font(.headline.weight(.medium))
                .foregroundStyle(AppColors.appPrimary)

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
                                    .font(.callout)
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
                    if let hours = openingHoursDisplay, !hours.rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "clock")
                                    .font(.callout)
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

                    if !hasHours && !hasContact {
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

    /// When `false`, the scroll starts with `bookingContent` only — categories whose `*BookingDetailContent` includes its own identity header. Car rental still uses the hero strip.
    private var shouldShowBookingHeroStrip: Bool {
        guard let category = place.bookingCategoryEnum else { return true }
        switch category {
        case .flight, .restaurant, .activity, .transport, .hotel:
            return false
        case .carRental:
            return true
        }
    }

    private var bookingDetailBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    // Skip the generic hero when the category’s `*BookingDetailContent` already opens with its own identity header (same idea as flight).
                    if shouldShowBookingHeroStrip {
                        bookingHeroStrip
                    }
                    bookingContent
                }
                .padding(.bottom, AppSpacing.xl)
            }
            .background(AppColors.appBackground)
            .navigationTitle(categoryLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                placeDetailDismissToolbarItem
                placeDetailBottomToolbarItems
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var bookingHeroStrip: some View {
        HStack(spacing: AppSpacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill((place.bookingCategoryEnum?.color ?? AppColors.appPrimary).opacity(0.14))
                    .frame(width: 56, height: 56)

                Image(systemName: categorySymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(place.name)
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)

                if let provider = bookingProvider {
                    Text(provider)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                } else if place.bookingCategoryEnum == .flight
                    || place.bookingCategoryEnum == .hotel
                    || place.bookingCategoryEnum == .restaurant
                    || place.bookingCategoryEnum == .carRental
                    || place.bookingCategoryEnum == .transport
                    || place.bookingCategoryEnum == .activity,
                    let line = bookingDetailLine {
                    Text(line)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            Spacer(minLength: AppSpacing.sm)

            if let conf = place.confirmationNumber, !conf.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Confirmation")
                        .font(.appSmall.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)

                    Text(conf)
                        .font(.appCaption.weight(.semibold))
                        .monospaced()
                        .foregroundStyle(place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
                }
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
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

        if place.isBooking, let tripId {
            BookingDetailDocumentsSection(
                bookingId: place.id,
                tripId: tripId,
                bookingTitle: place.name
            )
        }
    }

    private func flightContent(_ f: FlightDetails) -> some View {
        FlightBookingDetailContent(
            details: f,
            timeZone: bookingDisplayTimeZone,
            confirmationNumber: place.confirmationNumber
        )
    }

    private func hotelContent(_ h: HotelDetails) -> some View {
        HotelBookingDetailContent(
            details: h,
            timeZone: bookingDisplayTimeZone,
            propertyName: place.name,
            confirmationNumber: place.confirmationNumber,
            address: place.address
        )
    }

    private func restaurantContent(_ r: RestaurantDetails) -> some View {
        RestaurantBookingDetailContent(
            details: r,
            timeZone: bookingDisplayTimeZone,
            address: place.address
        )
    }

    private func carRentalContent(_ c: CarRentalDetails) -> some View {
        CarRentalBookingDetailContent(
            details: c,
            timeZone: bookingDisplayTimeZone,
            address: place.address
        )
    }

    private func activityContent(_ a: ActivityDetails) -> some View {
        ActivityBookingDetailContent(
            details: a,
            timeZone: bookingDisplayTimeZone,
            startTime: place.startTime,
            address: place.address
        )
    }

    private func transportContent(_ t: TransportDetails) -> some View {
        TransportBookingDetailContent(
            details: t,
            timeZone: bookingDisplayTimeZone,
            address: place.address
        )
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
                .font(.callout)
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

    /// Resolves the trip's destination timezone by fetching the trip and
    /// reverse-geocoding its lat/lng. Mirrors `TripDetailView`/`BookingsScreenView`
    /// so all trip-scoped surfaces show times in the same destination clock.
    private func resolveTripDisplayTimeZone() async {
        guard let tripId else {
            tripDisplayTimeZone = nil
            return
        }
        let trips = await dataService.fetchTrips()
        guard let trip = trips.first(where: { $0.id == tripId }),
              let lat = trip.lat, let lng = trip.lng,
              !lat.isNaN, !lng.isNaN else {
            tripDisplayTimeZone = nil
            return
        }
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng))
            tripDisplayTimeZone = marks.first?.timeZone
        } catch {
            tripDisplayTimeZone = nil
        }
    }

    /// Trip TZ is preferred for booking dates/times so the detail sheet matches
    /// the timeline. Caller-injected value wins (avoids a redundant geocode
    /// and the inevitable race where the sheet renders before our local
    /// resolver finishes). Falls back to local geocode → device TZ.
    private var bookingDisplayTimeZone: TimeZone {
        injectedDisplayTimeZone ?? tripDisplayTimeZone ?? .current
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
            .font(.caption2)
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
            .font(.footnote.weight(.medium))
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

// MARK: - Transparent nav + scroll edge (remove light-mode top fade over map)

private extension View {
    @ViewBuilder
    func placeDetailHideTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

/// Strips the navigation bar’s scroll-edge blur/tint that reads as a white gradient over the map (pre–iOS 26).
private struct PlaceDetailTransparentNavBarHook: UIViewControllerRepresentable {
    final class Coordinator {
        var didInstall = false
        weak var navigationBar: UINavigationBar?
        var standard: UINavigationBarAppearance?
        var scrollEdge: UINavigationBarAppearance?
        var compact: UINavigationBarAppearance?
        var compactScroll: UINavigationBarAppearance?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if #available(iOS 26.0, *) {
            return
        }

        DispatchQueue.main.async {
            let coordinator = context.coordinator
            if coordinator.didInstall { return }

            guard let navigationController = placeDetailEnclosingNavigationController(from: uiViewController) else {
                return
            }

            let bar = navigationController.navigationBar
            coordinator.didInstall = true
            coordinator.navigationBar = bar
            coordinator.standard = bar.standardAppearance
            coordinator.scrollEdge = bar.scrollEdgeAppearance
            coordinator.compact = bar.compactAppearance
            coordinator.compactScroll = bar.compactScrollEdgeAppearance

            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.backgroundEffect = nil
            appearance.shadowColor = .clear
            appearance.shadowImage = UIImage()

            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactAppearance = appearance
            bar.compactScrollEdgeAppearance = appearance
            bar.isTranslucent = true
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        guard coordinator.didInstall, let bar = coordinator.navigationBar else { return }
        if let appearance = coordinator.standard {
            bar.standardAppearance = appearance
        }
        if let appearance = coordinator.scrollEdge {
            bar.scrollEdgeAppearance = appearance
        }
        if let appearance = coordinator.compact {
            bar.compactAppearance = appearance
        }
        if let appearance = coordinator.compactScroll {
            bar.compactScrollEdgeAppearance = appearance
        }
        coordinator.didInstall = false
        coordinator.navigationBar = nil
    }
}

private func placeDetailEnclosingNavigationController(from controller: UIViewController) -> UINavigationController? {
    var current: UIViewController? = controller
    while let visit = current {
        if let navigation = visit as? UINavigationController {
            return navigation
        }
        if let navigation = visit.navigationController {
            return navigation
        }
        current = visit.parent
    }
    return nil
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
                .font(.footnote.weight(.medium))
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

#if DEBUG
#Preview("Place detail — activity") {
    PlaceDetailSheetPreviewHost()
}

/// Canvas / Preview host with representative enrichment and visit + route sections.
private struct PlaceDetailSheetPreviewHost: View {
    @State private var dataService = DataService()

    var body: some View {
        PlaceDetailSheet(
            place: Self.previewPlace,
            previousPlace: Self.previewPreviousPlace,
            tripId: UUID(),
            initialEnrichment: SupabaseManager.CityPlaceEnrichmentRow(
                previewPlaceId: "ChIJp7MPT3HyGGARMRIJgeCSzM4",
                popular_times: .string(FrescoPopularTimesPreviewData.jsonString)
            ),
            onEdit: {},
            onMove: {},
            onDelete: {}
        )
        .environment(dataService)
    }

    private static let itineraryDayId = UUID()

    private static var previewPreviousPlace: Place {
        Place(
            id: UUID(),
            itineraryDayId: itineraryDayId,
            name: "Trafalgar Square",
            address: "Trafalgar Sq, London",
            lat: 51.5080,
            lng: -0.1281,
            category: "attraction",
            notes: nil,
            sortOrder: 0,
            startTime: nil,
            endTime: nil,
            isBooking: false,
            bookingType: nil,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: nil,
            bookingAmount: nil,
            bookingCurrencyCode: nil,
            heroImageUrl: nil,
            rating: nil,
            userRatingsTotal: nil,
            priceLevel: nil,
            website: nil,
            phoneNumber: nil,
            isOpenNow: nil,
            openingHoursText: nil,
            aiSummary: nil,
            aiShortSummary: nil,
            whyGo: nil,
            knowBeforeYouGo: nil,
            reviewsTags: nil,
            durationMinutes: nil,
            subtypes: nil,
            travelFromPreviousMinutes: nil,
            travelMode: nil
        )
    }

    private static var previewPlace: Place {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 10, minute: 30, second: 0, of: Date())!
        let end = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        return Place(
            id: UUID(),
            itineraryDayId: itineraryDayId,
            name: "British Museum",
            address: "Great Russell St, London WC1B 3DG, United Kingdom",
            lat: 51.5194,
            lng: -0.1269,
            category: "attraction",
            notes: "Bring headphones for the audio guide.",
            sortOrder: 1,
            startTime: start,
            endTime: end,
            isBooking: false,
            bookingType: nil,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: nil,
            bookingAmount: nil,
            bookingCurrencyCode: nil,
            heroImageUrl: nil,
            rating: 4.7,
            userRatingsTotal: 89_432,
            priceLevel: 0,
            website: "https://www.britishmuseum.org",
            phoneNumber: "+44 20 7323 8299",
            isOpenNow: true,
            openingHoursText: "Open · Closes 17:00",
            aiSummary: """
            The British Museum documents the story of human culture from its beginnings to the present. \
            Its collections, which number more than eight million objects, are amongst the largest and most comprehensive \
            in existence and originate from all continents, illustrating and documenting the story of human culture from \
            its beginning to the present. This preview paragraph is long enough to exercise the About “More” control.
            """,
            aiShortSummary: nil,
            whyGo: [
                "One of the world’s greatest museums",
                "Rosetta Stone and Egyptian mummies",
                "Free general admission",
            ],
            knowBeforeYouGo: [
                "Peak hours on weekends — arrive early or book a timed exhibition ticket.",
                "Backpacks over cabin size may need to be cloaked.",
            ],
            reviewsTags: ["museum", "history", "free"],
            durationMinutes: 150,
            subtypes: ["museum", "tourist_attraction"],
            travelFromPreviousMinutes: nil,
            travelMode: nil
        )
    }
}
#endif