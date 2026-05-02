import SwiftUI

/// Activity row in the trip-detail timeline. Same chassis as
/// `TimelineBookingCardView` (see `timelineCardChassis`). Leading visual:
/// user activity photos (stack) if any, else `city_places` thumbnail when
/// present, else the category icon.
struct TimelinePlaceCardView: View {
    let place: Place
    let dayNumber: Int
    /// Wall-clock context for scheduled times (trip destination / day IANA zone).
    var timelineDisplayTimeZone: TimeZone = .current

    var onEdit: () -> Void = {}
    var onMoveToDay: () -> Void = {}
    var onMoveToIdeas: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Opens place detail from spine or title/flash; omitted on the photo stack so gallery / swipe keep taps.
    var onSelectRow: (() -> Void)? = nil

    /// Signed thumbnail URLs for `trip_activity_attachments` (same ids as `place.id`).
    var activityPhotoStack: [ActivityFeedPhotoStackItem] = []
    /// Editors get swipe-to-photos; viewers only see stacks when non-empty.
    var canEditActivityPhotos: Bool = false
    /// Tap on the stacked thumbnails — paged gallery only.
    var onOpenActivityPhotoGallery: (() -> Void)? = nil
    /// Context menu vs swipe: swipe passes `.openSystemPickerOnAppear` for direct add.
    var onOpenActivityPhotoManage: ((ActivityPhotosManageEntry) -> Void)? = nil

    /// Phase 3 — pulled from the environment so cards in the wishlist
    /// section pick up flashes too, not just cards in scheduled days.
    /// Optional in mock-mode where the realtime layer never fires.
    @Environment(TripCollaborationUiStore.self) private var collaborationUi

    private var familyColor: Color {
        place.categoryEnum.color
    }

    private var inlineIcon: String {
        activityTypeIcon(for: activityTypeLabel) ?? place.categoryEnum.sfSymbol
    }

    private var flash: TripCollaborationUiStore.ChangeFlash? {
        collaborationUi.flash(for: place.id)
    }

    /// Timeline activity rows for restaurants use a compact layout (name + reservation date/time only).
    private var isRestaurantActivityLayout: Bool {
        place.categoryEnum == .restaurant
    }

    private var rowCore: some View {
        HStack(alignment: .top, spacing: TimelineSpineMetrics.pinColumnToCardSpacing) {
            TimelineSpineTimeColumn(
                startTime: place.startTime,
                accentColor: familyColor,
                timeZone: timelineDisplayTimeZone,
                accessibilityLabel: spineAccessibilityLabel
            )
            .contentShape(Rectangle())
            .timelineRowSelect(onSelectRow)

            cardSurface
                .cardPulse(flashID: flash?.id)
        }
    }

    private var spineAccessibilityLabel: String {
        if let start = place.startTime {
            return "Starts \(start.timeFormatted(timeZone: timelineDisplayTimeZone))"
        }
        return String(localized: "Flexible time")
    }

    var body: some View {
        Group {
            if let manage = onOpenActivityPhotoManage, canEditActivityPhotos {
                TimelineSwipeRevealPhotosRow(onPhotos: { manage(.openSystemPickerOnAppear) }) {
                    rowCore
                }
            } else {
                rowCore
            }
        }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Move to Day", action: onMoveToDay)
            if dayNumber != 0 {
                Button("Move to Ideas", action: onMoveToIdeas)
            }
            if canEditActivityPhotos, let manage = onOpenActivityPhotoManage {
                Button {
                    manage(.browse)
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }
            } else if let gallery = onOpenActivityPhotoGallery, !activityPhotoStack.isEmpty {
                Button {
                    gallery()
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// User activity photos when present, else catalog thumbnail, else category icon.
    @ViewBuilder
    private var activityLeadingVisual: some View {
        if !activityPhotoStack.isEmpty {
            ActivityFeedPhotoStackView(
                items: activityPhotoStack,
                tileSize: TimelineCardLeadingIconMetrics.solidSquareSideLength,
                tileCornerRadius: AppCornerRadius.medium,
                arrangement: .timelineLeading,
                onTap: { onOpenActivityPhotoGallery?() }
            )
        } else if let thumbURL = timelineCatalogThumbnailURL {
            TimelineLeadingCatalogThumbnail(
                url: thumbURL,
                symbol: inlineIcon,
                accent: familyColor,
                accessibilityLabel: activityTypeLabel
            )
            .contentShape(Rectangle())
            .timelineRowSelect(onSelectRow)
        } else {
            TimelineCardLeadingIconMetrics.categoryBadge(
                symbol: inlineIcon,
                accent: familyColor,
                accessibilityLabel: activityTypeLabel
            )
            .contentShape(Rectangle())
            .timelineRowSelect(onSelectRow)
        }
    }

    private var timelineCatalogThumbnailURL: URL? {
        let trimmed = place.thumbnailUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }

    // MARK: - Card surface

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                activityLeadingVisual

                titleColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .timelineRowSelect(onSelectRow)
            }

            // Phase 3 — only renders when a recent realtime change has landed
            // for this card. Layout-stable: the row collapses back to nothing
            // once the flash expires.
            if let flash {
                CollaborativeAttributionPill(
                    actorDisplayName: flash.displayActor,
                    actorUserId: flash.actorUserId,
                    kind: flash.kind
                )
                .contentShape(Rectangle())
                .timelineRowSelect(onSelectRow)
            }
        }
        .timelineCardChassis(
            stripeColor: familyColor,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentVerticalPadding
        )
    }

    @ViewBuilder
    private var titleColumn: some View {
        if isRestaurantActivityLayout {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(TimelinePlaceDisplayName.timelineDisplay(place.name))
                    .font(.timelineRowTitle)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                Text(restaurantReservationScheduleLine)
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(TimelinePlaceDisplayName.timelineDisplay(place.name))
                    .font(.timelineRowTitle)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                Text(activitySummaryParts.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// One line: short date in the trip timeline zone, then reservation time (or start–end when both exist).
    private var restaurantReservationScheduleLine: String {
        guard let start = place.startTime else {
            return String(localized: "Flexible time")
        }
        let datePart = start.shortFormatted(timeZone: timelineDisplayTimeZone)
        if let end = place.endTime, end > start {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timelineDisplayTimeZone
            if cal.isDate(start, inSameDayAs: end) {
                return "\(datePart) · \(start.timeFormatted(timeZone: timelineDisplayTimeZone)) – \(end.timeFormatted(timeZone: timelineDisplayTimeZone))"
            }
        }
        return "\(datePart) · \(start.timeFormatted(timeZone: timelineDisplayTimeZone))"
    }

    // MARK: - Type-aware subtitle
    //
    // We compose a 1-line "tag string" tuned per category so each card carries
    // the metadata most useful for that kind of place. The activity type leads
    // the row so users can scan "Restaurant", "Museum", "Attraction", etc.
    // before reading rating, price, or duration.

    private var activitySummaryParts: [String] {
        var parts = [activityTypeLabel]
        parts.append(contentsOf: detailParts)
        return parts
    }

    private var detailParts: [String] {
        var parts: [String] = []

        if let r = place.rating {
            parts.append(String(format: "%.1f ★", r))
        }

        switch place.categoryEnum {
        case .restaurant, .nightlife, .shopping:
            if let price = priceString(place.priceLevel) {
                parts.append(price)
            }
        case .attraction, .nature, .hotel, .transport, .custom:
            if let dur = primaryDurationString {
                parts.append(dur)
            }
        }

        return parts
    }

    private var activityTypeLabel: String {
        place.placeKindLabel ?? place.categoryEnum.label
    }

    /// Prefer the actual scheduled duration (start→end) since that reflects
    /// the user's plan; fall back to the editorial `durationMinutes` when the
    /// place has no fixed slot.
    private var primaryDurationString: String? {
        if let dur = durationLabel(start: place.startTime, end: place.endTime) {
            return dur
        }
        return durationFromMinutes(place.durationMinutes)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        if isRestaurantActivityLayout {
            return "\(place.categoryEnum.label): \(place.name), \(restaurantReservationScheduleLine)"
        }
        var pieces = ["\(place.categoryEnum.label): \(place.name)"]
        if let start = place.startTime {
            if let end = place.endTime {
                pieces.append("\(start.timeFormatted(timeZone: timelineDisplayTimeZone)) to \(end.timeFormatted(timeZone: timelineDisplayTimeZone))")
            } else {
                pieces.append(start.timeFormatted(timeZone: timelineDisplayTimeZone))
            }
        }
        if let r = place.rating {
            pieces.append(String(format: "rated %.1f", r))
        }
        if let area = neighborhood(from: place.address) {
            pieces.append("in \(area)")
        }
        return pieces.joined(separator: ", ")
    }
}

// MARK: - Helpers

/// Compact `$`/`$$`/`$$$`/`$$$$` glyph for Google `priceLevel` 1–4.
/// Returns `nil` for missing or out-of-range values so callers can drop the
/// chip cleanly.
private func priceString(_ level: Int?) -> String? {
    guard let level, (1...4).contains(level) else { return nil }
    return String(repeating: "$", count: level)
}

/// Human duration string built from a raw minute count: "1h 30m" / "45m" / "2h".
private func durationFromMinutes(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

/// Human duration string from start/end. Returns `nil` when no `start` is
/// known. When `end` is missing, defaults to a 60-minute window so the row
/// still carries shape for unsized stops.
private func durationLabel(start: Date?, end: Date?) -> String? {
    guard let start else { return nil }
    let endResolved = end ?? start.addingTimeInterval(60 * 60)
    let minutes = max(0, Int(endResolved.timeIntervalSince(start) / 60))
    if minutes == 0 { return nil }
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

/// Best-effort neighborhood extraction from a free-form address. Splits on
/// `,` and `-`, drops trailing country names, dedupes consecutive identical
/// segments (so `"Dubai - Dubai - UAE"` doesn't render `"Dubai"` twice), and
/// returns the most-specific *non-city* segment when one exists.
///
/// Examples:
/// - `"1 Sheikh Mohammed Bin Rashid Blvd, Downtown Dubai, Dubai, UAE"` → `"Downtown Dubai"`
/// - `"Burj Khalifa - Downtown Dubai - Dubai - United Arab Emirates"` → `"Downtown Dubai"`
/// - `"Tokyo"` → `nil`
func neighborhood(from address: String?) -> String? {
    guard let address, !address.isEmpty else { return nil }

    var parts = address
        .components(separatedBy: CharacterSet(charactersIn: ",-"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // 1. Drop trailing country / region segments. Tightly scoped to the names
    //    that actually show up in our trip data so we don't accidentally
    //    swallow legitimate city/neighborhood names.
    let countryNames: Set<String> = [
        "uae", "united arab emirates",
        "usa", "u.s.a.", "u.s.", "united states", "united states of america",
        "uk", "u.k.", "united kingdom",
        "france", "italy", "spain", "japan", "germany", "portugal",
        "netherlands", "the netherlands", "belgium", "switzerland", "austria",
        "greece", "turkey", "thailand", "indonesia", "vietnam", "singapore",
        "australia", "new zealand", "canada", "mexico", "brazil", "argentina",
        "china", "south korea", "korea", "india", "egypt", "morocco",
    ]
    while let last = parts.last, countryNames.contains(last.lowercased()) {
        parts.removeLast()
    }

    // 2. Collapse consecutive duplicates ("Dubai - Dubai" → "Dubai").
    var deduped: [String] = []
    for segment in parts {
        if deduped.last?.caseInsensitiveCompare(segment) != .orderedSame {
            deduped.append(segment)
        }
    }

    guard deduped.count >= 2 else { return nil }

    // 3. The last segment is the city — return the second-to-last as the
    //    neighborhood, but only when it actually differs from the city.
    let city = deduped.last!
    let candidate = deduped[deduped.count - 2]
    if candidate.caseInsensitiveCompare(city) == .orderedSame { return nil }
    return candidate
}

/// Catalog `thumbnail_url` tile on the timeline; matches leading icon size. Falls back to the category badge if the image fails.
private struct TimelineLeadingCatalogThumbnail: View {
    let url: URL
    let symbol: String
    let accent: Color
    let accessibilityLabel: String

    private var side: CGFloat { TimelineCardLeadingIconMetrics.solidSquareSideLength }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(AppColors.appSurface)
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                TimelineCardLeadingIconMetrics.categoryBadge(
                    symbol: symbol,
                    accent: accent,
                    accessibilityLabel: accessibilityLabel
                )
            @unknown default:
                TimelineCardLeadingIconMetrics.categoryBadge(
                    symbol: symbol,
                    accent: accent,
                    accessibilityLabel: accessibilityLabel
                )
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .accessibilityHidden(true)
    }
}

private func activityTypeIcon(for label: String) -> String? {
    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }

    let mappings: [(keywords: [String], symbol: String)] = [
        (["wildlife", "zoo", "animal", "safari", "aquarium"], "pawprint.fill"),
        (["buddhist temple", "temple", "shrine", "church", "cathedral", "mosque", "synagogue"], "building.columns.fill"),
        (["scenic", "viewpoint", "lookout", "observation", "photo spot"], "camera.viewfinder"),
        (["museum", "gallery", "exhibit", "art"], "paintpalette.fill"),
        (["historic", "monument", "landmark", "castle", "palace", "ruins"], "building.columns.fill"),
        (["park", "garden", "botanical"], "tree.fill"),
        (["trail", "hike", "hiking", "mountain"], "figure.hiking"),
        (["beach", "island"], "beach.umbrella.fill"),
        (["lake", "river", "waterfall", "spring"], "water.waves"),
        (["restaurant", "dining", "food", "bistro", "brasserie"], "fork.knife"),
        (["cafe", "coffee", "tea", "bakery"], "cup.and.saucer.fill"),
        (["bar", "pub", "wine", "cocktail"], "wineglass.fill"),
        (["market", "shopping", "mall", "store", "boutique"], "bag.fill"),
        (["show", "theater", "theatre", "cinema", "performance"], "theatermasks.fill"),
        (["music", "concert", "festival"], "music.note"),
        (["stadium", "arena", "sport"], "sportscourt.fill"),
        (["tour", "ticket", "experience"], "ticket.fill"),
        (["spa", "wellness", "onsen", "hot spring"], "sparkles"),
        (["hotel", "resort", "hostel"], "bed.double.fill"),
        (["train", "rail", "station"], "tram.fill"),
        (["bus", "coach"], "bus.fill"),
        (["boat", "ferry", "cruise"], "ferry.fill"),
        (["airport", "flight"], "airplane"),
        (["attraction"], "star.fill")
    ]

    return mappings.first { mapping in
        mapping.keywords.contains { normalized.contains($0) }
    }?.symbol
}

// MARK: - Row selection (exclude leading photo hit target)

private extension View {
    /// Applies a tap only when the host wires selection (e.g. trip timeline); `nil` leaves hit testing unchanged.
    @ViewBuilder
    func timelineRowSelect(_ action: (() -> Void)?) -> some View {
        if let action {
            self.onTapGesture { action() }
        } else {
            self
        }
    }
}


// =============================================================================

#if DEBUG
#Preview("Activity cards") {
    ScrollView {
        VStack(spacing: 0) {
            TimelinePlaceCardView(place: .previewAttraction, dayNumber: 1)
            TimelinePlaceCardView(place: .previewRestaurant, dayNumber: 1)
            TimelinePlaceCardView(place: .previewHotel, dayNumber: 1)
        }
        .padding()
    }
    .background(AppColors.appBackground)
    .environment(TripCollaborationUiStore())
}
#endif
