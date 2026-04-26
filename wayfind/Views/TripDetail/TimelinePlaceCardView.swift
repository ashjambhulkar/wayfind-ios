import SwiftUI

/// Activity row in the trip-detail timeline. Same chassis as
/// `TimelineBookingCardView` (see `TimelineCardChassis`) — what makes each
/// card recognisable at a glance is the inline category icon next to the
/// title and the type-aware subtitle (rating · price · duration · area).
struct TimelinePlaceCardView: View {
    let place: Place
    let dayNumber: Int

    var onEdit: () -> Void = {}
    var onMoveToDay: () -> Void = {}
    var onMoveToIdeas: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Phase 3 — pulled from the environment so cards in the wishlist
    /// section pick up flashes too, not just cards in scheduled days.
    /// Optional in mock-mode where the realtime layer never fires.
    @Environment(TripCollaborationUiStore.self) private var collaborationUi

    private var familyColor: Color {
        place.categoryEnum.color
    }

    private var inlineIcon: String {
        if place.categoryEnum == .attraction {
            return "binoculars.fill"
        }
        return place.categoryEnum.sfSymbol
    }

    private var flash: TripCollaborationUiStore.ChangeFlash? {
        collaborationUi.flash(for: place.id)
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            leadingMarker
            cardSurface
                .cardPulse(flashID: flash?.id)
        }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Move to Day", action: onMoveToDay)
            if dayNumber != 0 {
                Button("Move to Ideas", action: onMoveToIdeas)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Leading marker

    @ViewBuilder
    private var leadingMarker: some View {
        if let start = place.startTime {
            TimePinView(time: start, tint: familyColor)
        } else {
            UnscheduledMarkerView(tint: familyColor)
        }
    }

    // MARK: - Card surface

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Image(systemName: inlineIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(familyColor)
                    .frame(width: 16, alignment: .center)

                // Use `Color.primary` (true system-black in light, true white
                // in dark) for the strongest, Apple-correct title contrast.
                // `AppColors.textPrimary` reads slightly washed at 0x1A1A1A.
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

            // Phase 3 — only renders when a recent realtime change has
            // landed for this card. Layout-stable: the row collapses
            // back to nothing once the flash expires (no border, no
            // sized placeholder) so neighbours don't shift.
            if let flash {
                CollaborativeAttributionPill(
                    actorDisplayName: flash.displayActor,
                    actorUserId: flash.actorUserId,
                    kind: flash.kind
                )
            }
        }
        .timelineCardChassis(stripeColor: familyColor)
    }

    // MARK: - Type-aware subtitle
    //
    // We compose a 1-line "tag string" tuned per category so each card carries
    // the metadata most useful for that kind of place. Order is: identifying
    // signal first (rating / price), shape signal next (duration), then a quiet
    // place anchor (neighborhood or category label) so the row always ends
    // with where-or-what-it-is.

    private var subtitleParts: [String] {
        var parts: [String] = []

        if let r = place.rating {
            parts.append(String(format: "★ %.1f", r))
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

        // Trailing tag: prefer the most specific Google subtype (e.g.
        // "Shopping mall", "Cocktail bar") over the broad category label so
        // every card carries a sharper "what is this" signal. Otherwise fall
        // back to neighborhood, then to the category label.
        if let kind = place.placeKindLabel {
            parts.append(kind)
        } else if let area = neighborhood(from: place.address) {
            parts.append(area)
        } else {
            parts.append(place.categoryEnum.label)
        }

        return parts
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
        var pieces = ["\(place.categoryEnum.label): \(place.name)"]
        if let start = place.startTime {
            if let end = place.endTime {
                pieces.append("\(start.timeFormatted) to \(end.timeFormatted)")
            } else {
                pieces.append(start.timeFormatted)
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
