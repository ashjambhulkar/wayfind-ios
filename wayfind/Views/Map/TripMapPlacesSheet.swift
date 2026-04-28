import MapKit
import SwiftUI
import UIKit

// MARK: - Sheet layout (detent ↔︎ coarse state)

/// Coarse places-sheet layout so we can hide search in the docked (minimized) detent.
enum PlacesSheetLayout: Equatable {
    case docked
    case half
    case full

    /// Grabber + exactly one compact chrome row. Keep this tight so the docked
    /// state reads as the search bar or day-pill slider itself, not a larger
    /// mini sheet with extra vertical dead space.
    static let compactDetent = PresentationDetent.height(84)

    /// Shorter than system `.medium` so more of the map stays visible.
    static let halfOpenDetent = PresentationDetent.height(285)

    var presentationDetent: PresentationDetent {
        switch self {
        case .docked: Self.compactDetent
        case .half: Self.halfOpenDetent
        case .full: .large
        }
    }

    init(resolving detent: PresentationDetent) {
        if detent == Self.compactDetent {
            self = .docked
        } else if detent == .large {
            self = .full
        } else {
            self = .half
        }
    }
}

// MARK: - Places Sheet

/// Day filters + places list. Top chrome: grabber, search pill, **Suggested Places** (sparkles)
/// whenever the inline search UI is hidden. In the docked detent, active search text keeps the search
/// pill visible with a close button; otherwise only the day filters remain.
/// Dock the sheet by dragging to the compact detent.
struct TripMapPlacesExpandedSheet: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    let onSelectPlace: (Place) -> Void

    /// Current coarse detent; updates as the user drags the sheet.
    @Binding var placesSheetLayout: PlacesSheetLayout
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool
    /// TripMapView sets to true to present search inline (e.g. return-from-preview) without a second sheet.
    @Binding var openInlineMapSearch: Bool
    /// Opens the suggested-places sheet (sparkles control in docked / half / full chrome).
    let onOpenSuggestedPlaces: () -> Void
    /// Pins from the last map search (keyboard Search / category). Shown in the half sheet under the search pill.
    var mapSearchResults: [MapSearchPreview] = []
    let onSelectMapSearchPreview: (MapSearchPreview) -> Void
    /// Clears map search pins + pill text (same outcome as clearing the system search field).
    let onClearActiveMapSearch: () -> Void
    /// Builds map search UI; `activationDelayMs` is 0 when the places sheet is already at `.full`, otherwise a short delay while the detent animates.
    let mapSearchOverlay: (_ embedsInParentSheet: Bool, _ activationDelayMs: Int, _ endInlineSearch: @escaping () -> Void) -> MapSearchOverlay

    @State private var isInlineMapSearchActive = false
    @State private var inlineSearchFieldActivationDelayMs = 0

    /// Settled layout used for content-structure decisions. iOS's
    /// `.presentationDetents(_:selection:)` binding can emit transient values
    /// during a quick flick when the sheet briefly crosses a detent threshold
    /// before the physics decide to bounce back. Gating content structure on
    /// the raw binding causes docked content to appear inside a half-size
    /// sheet. We debounce commits here so only stable detents flip content.
    @State private var committedLayout: PlacesSheetLayout?
    @State private var layoutCommitTask: Task<Void, Never>?

    /// Drives motion choice for chrome transitions so we honour Accessibility > Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsMapSearchResultsList: Bool {
        !mapSearchResults.isEmpty
    }

    private var hasActiveMapSearchText: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Settled layout the content decisions read. Falls back to the raw
    /// binding only until the first committed value is known (initial render).
    private var effectiveLayout: PlacesSheetLayout {
        committedLayout ?? placesSheetLayout
    }

    /// Composite key that collapses every driver of chrome layout into a single
    /// value, so the body's `.animation(_, value:)` re-runs exactly once per
    /// state change. Prevents the previous mismatch where two independent
    /// `.animation` modifiers could disagree mid flick-release.
    private struct ChromeAnimationKey: Hashable {
        let layout: PlacesSheetLayout
        let hasSearchText: Bool
    }

    private var chromeAnimationKey: ChromeAnimationKey {
        ChromeAnimationKey(layout: effectiveLayout, hasSearchText: hasActiveMapSearchText)
    }

    /// Spring matched to iOS sheet detent animation (response ~0.35, damping ~0.82).
    /// Collapses to a short linear cross-fade when Reduce Motion is on — matches HIG.
    private var chromeAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.12)
            : .spring(response: 0.35, dampingFraction: 0.82)
    }

    /// Summarises the sheet's current state for VoiceOver (announced as a container label).
    private var sheetAccessibilityLabel: String {
        switch effectiveLayout {
        case .docked:
            if hasActiveMapSearchText {
                return String(localized: "Minimized. Search: \(searchText).")
            }
            return String(localized: "Minimized. Day filters.")
        case .half:
            return hasActiveMapSearchText
                ? String(localized: "Places. Search: \(searchText).")
                : String(localized: "Places. Day filters and activities.")
        case .full:
            return hasActiveMapSearchText
                ? String(localized: "Places expanded. Search: \(searchText).")
                : String(localized: "Places expanded. Day filters and activities.")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            expandedSheetDragGrabber

            if isInlineMapSearchActive {
                inlineMapSearchView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                // Docked: top row only (pills OR search bar). Expanded content is
                // removed from the hierarchy entirely so VoiceOver cannot reach it
                // and no offscreen list rows are laid out.
                // Half / Full: top row + divider + expanded content. The removal
                // uses opacity + move so the transition feels "of the sheet"
                // during a flick-release, co-timed with the sheet height animation.
                // NOTE: gated on `effectiveLayout`, not the raw binding, so
                // transient flick-induced .docked updates don't thrash the tree.
                topChromeRow

                if effectiveLayout != .docked {
                    Divider()

                    expandedContentArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity.combined(with: .move(edge: .bottom))
                            )
                        )
                        .accessibilityHidden(effectiveLayout == .docked)
                }
            }
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sheetAccessibilityLabel)
        .animation(chromeAnimation, value: chromeAnimationKey)
        .onAppear {
            // Sync the committed layout to whatever the sheet opened at, so the
            // first drag starts from a known stable value (not nil).
            committedLayout = placesSheetLayout
        }
        .onDisappear {
            layoutCommitTask?.cancel()
            layoutCommitTask = nil
        }
        .onChange(of: placesSheetLayout) { _, newLayout in
            scheduleLayoutCommit(newLayout)
        }
        .onChange(of: openInlineMapSearch) { _, shouldOpen in
            guard shouldOpen else { return }
            openInlineMapSearch = false
            inlineSearchFieldActivationDelayMs = (placesSheetLayout == .full) ? 0 : 260
            placesSheetLayout = .full
            isInlineMapSearchActive = true
        }
    }

    /// Debounce content-layer commits by ~120ms to filter out iOS's transient
    /// mid-gesture detent binding updates. A rapid flick that briefly crosses a
    /// detent threshold before snapping back cancels the pending commit, so the
    /// body never structurally rebuilds around a phantom intermediate state.
    private func scheduleLayoutCommit(_ newLayout: PlacesSheetLayout) {
        layoutCommitTask?.cancel()
        layoutCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            commitLayout(newLayout)
        }
    }

    /// Commit a settled detent: update content state, reset search overlays
    /// when docking, and fire a detent-change haptic only on real transitions.
    private func commitLayout(_ newLayout: PlacesSheetLayout) {
        let previous = committedLayout
        committedLayout = newLayout
        if newLayout == .docked {
            isSearchPresented = false
            isInlineMapSearchActive = false
        }
        if let previous, previous != newLayout {
            HapticManager.selection()
        }
    }

    private func endInlineMapSearch() {
        guard isInlineMapSearchActive else { return }
        isInlineMapSearchActive = false
        // Inline search always opens at `.full`; exiting returns to half so the itinerary or map results list is visible.
        if placesSheetLayout != .docked {
            placesSheetLayout = .half
        }
    }

    private var inlineMapSearchView: some View {
        mapSearchOverlay(true, inlineSearchFieldActivationDelayMs, endInlineMapSearch)
    }

    /// Single top row used at every detent.
    /// - Docked + empty → day pills only (user's rule).
    /// - Docked + text → search bar with X.
    /// - Expanded  → always search bar (expanded content below hosts the pills).
    ///
    /// Uses a conditional `Group` (not `ZStack`) so the row sizes to the active
    /// variant's natural height — avoids the ~22pt of dead space the ZStack max
    /// height introduced in docked+empty. The crossfade is driven by the body's
    /// single spring animation via `.transition(.opacity)`.
    @ViewBuilder
    private var topChromeRow: some View {
        if effectiveLayout == .docked && !hasActiveMapSearchText {
            dayPillsChromeRow
                .transition(.opacity)
        } else {
            searchBarChromeRow
                .transition(.opacity)
        }
    }

    /// Content below the top row. Always rendered so the system sheet simply
    /// clips during detent animations — avoids mid-drag empty panels.
    /// - Has results → results list.
    /// - Otherwise → (optional) day pills as filter chrome + activities list.
    /// In docked+empty the top row is already the pills, so we skip the filter row
    /// to avoid a duplicate pill row appearing briefly as the sheet grows.
    @ViewBuilder
    private var expandedContentArea: some View {
        if showsMapSearchResultsList {
            mapSubmittedSearchResultsList
        } else {
            VStack(spacing: 0) {
                let topIsPills = effectiveLayout == .docked && !hasActiveMapSearchText
                if !topIsPills {
                    dayPillsChromeRow
                    Divider()
                }
                TripMapPlacesDayListContent(
                    trip: trip,
                    selectedDayFilter: $selectedDayFilter,
                    allPlacesForList: allPlacesForList,
                    dayNumberByDayId: dayNumberByDayId,
                    onSelectPlace: onSelectPlace,
                    showsDayTabs: false
                )
            }
        }
    }

    private var searchBarChromeRow: some View {
        HStack(alignment: .center, spacing: 10) {
            mapsStyleSearchPillButton
                .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing accessory mirrors the original behaviour:
            // - Active search text (or committed results) → clear (X) button.
            // - Otherwise → Suggested Places (sparkles) shortcut.
            if hasActiveMapSearchText || showsMapSearchResultsList {
                activeMapSearchClearButton
            } else {
                mapsStyleSuggestedPlacesButton
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, 2)
        .padding(.bottom, AppSpacing.sm)
    }

    private var dayPillsChromeRow: some View {
        DayFilterChipsView(
            selectedDay: $selectedDayFilter,
            dayCount: max(trip.dayCount, 1),
            controlSize: .regular
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            guard effectiveLayout == .docked else { return }
            HapticManager.light()
            placesSheetLayout = .half
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(localized: "\(allPlacesForList.count) activities on map. Tap to expand the list.")
        )
        .accessibilityAction(named: Text(String(localized: "Expand places list"))) {
            placesSheetLayout = .half
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func mapSubmittedSearchRowSymbolAndFamily(for preview: MapSearchPreview) -> (
        symbol: String,
        family: PlaceCategoryFamily
    ) {
        if let cat = preview.category {
            return (cat.mapBadgeSymbol, cat.family)
        }
        return SearchRowIconHeuristic.icon(forTitle: preview.name)
    }

    @ViewBuilder
    private func mapSubmittedSearchRowLeadingIcon(preview: MapSearchPreview) -> some View {
        let icon = mapSubmittedSearchRowSymbolAndFamily(for: preview)
        ZStack {
            Circle()
                .fill(icon.family == .generic ? Color(uiColor: .systemGray5) : icon.family.tint)
            Image(systemName: icon.symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(icon.family == .generic ? .secondary : icon.family.color)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    /// After keyboard Search: same pins as the map, in a scannable list (half detent).
    private var mapSubmittedSearchResultsList: some View {
        List {
            Section {
                ForEach(mapSearchResults) { preview in
                    Button {
                        HapticManager.light()
                        onSelectMapSearchPreview(preview)
                    } label: {
                        HStack(alignment: .center, spacing: AppSpacing.md) {
                            mapSubmittedSearchRowLeadingIcon(preview: preview)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(preview.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if !preview.subtitle.isEmpty {
                                    Text(preview.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if preview.isOwnedRow {
                                    Label("Wayfind suggestion", systemImage: "checkmark.seal.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AppColors.appPrimary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: AppSpacing.lg, bottom: 4, trailing: AppSpacing.lg))
                    .listRowBackground(AppColors.appSurface)
                }
            } header: {
                Text(
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "Results on map")
                        : searchText
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 52)
    }

    /// Trailing **clear** control (filled X), same glyph family as the system search field dismiss.
    private var activeMapSearchClearButton: some View {
        MapChromeIconButton.mapSearchDismiss(
            accessibilityHint: String(localized: "Clears the search and removes results from the map")
        ) {
            HapticManager.light()
            onClearActiveMapSearch()
        }
    }

    private var mapsStyleSearchPillButton: some View {
        Button {
            HapticManager.light()
            isSearchPresented = false
            // No detent animation when already full — focus can run immediately (see `MapSearchOverlay.onOverlayAppear`).
            inlineSearchFieldActivationDelayMs = (placesSheetLayout == .full) ? 0 : 260
            placesSheetLayout = .full
            isInlineMapSearchActive = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)

                Group {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(String(localized: "Search places"))
                            .foregroundStyle(Color(UIColor.placeholderText))
                    } else {
                        Text(searchText)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Search places"))
        .accessibilityHint(String(localized: "Expands search in this sheet"))
    }

    private var mapsStyleSuggestedPlacesButton: some View {
        MapChromeIconButton.suggestedPlaces {
            HapticManager.light()
            onOpenSuggestedPlaces()
        }
    }

    /// Wider than the system sheet grabber (`presentationDragIndicator` has no public width API).
    /// Tighter vertical padding while inline map search is up so the nav search field sits closer to the dragger.
    private var expandedSheetDragGrabber: some View {
        let topPad: CGFloat = isInlineMapSearchActive ? 4 : 8
        let bottomPad: CGFloat = isInlineMapSearchActive ? 0 : 4
        return Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 52, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
            .accessibilityHidden(true)
    }

}

// MARK: - Day list content
//
// Search is gone — the floating pill (Phase 3) takes that responsibility.
// This view hosts only day tabs, day pages, and place rows.

private struct TripMapPlacesDayListContent: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    let onSelectPlace: (Place) -> Void
    var showsDayTabs: Bool = true

    private var dayCount: Int { max(trip.dayCount, 1) }

    private var dayFilterTabBinding: Binding<Int> {
        Binding(
            get: { selectedDayFilter ?? 0 },
            set: { newValue in selectedDayFilter = newValue == 0 ? nil : newValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDayTabs {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        dayTab(dayNum: 0, label: "All")
                        ForEach(1...dayCount, id: \.self) { dayNum in
                            dayTab(dayNum: dayNum, label: "Day \(dayNum)")
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 42)
                .background(.regularMaterial)

                Divider()
            }

            TabView(selection: dayFilterTabBinding) {
                dayPage(label: "All", places: allPlacesForList).tag(0 as Int)
                ForEach(1...dayCount, id: \.self) { dayNum in
                    let dayPlaces = allPlacesForList
                        .filter { dayNumberByDayId[$0.itineraryDayId] == dayNum }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    dayPage(label: "Day \(dayNum)", places: dayPlaces).tag(dayNum)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func dayTab(dayNum: Int, label: String) -> some View {
        let isSelected = (selectedDayFilter ?? 0) == dayNum
        let accentColor: Color = dayNum == 0 ? AppColors.appPrimary : AppColors.dayColor(for: dayNum)

        return Button {
            HapticManager.selection()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                selectedDayFilter = dayNum == 0 ? nil : dayNum
            }
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: dayNum == 0 ? 0 : 5) {
                    if dayNum != 0 {
                        Circle().fill(accentColor).frame(width: 6, height: 6)
                    }
                    Text(label)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? accentColor : Color(UIColor.secondaryLabel))
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(isSelected ? accentColor : Color.clear)
                    .frame(height: 2)
            }
            .frame(height: 42)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func dayPage(label: String, places: [Place]) -> some View {
        List {
            if places.isEmpty {
                Section { emptyDayState }
            } else {
                Section {
                    ForEach(places) { place in
                        placeRow(place)
                            .listRowInsets(EdgeInsets(top: 10, leading: AppSpacing.lg, bottom: 10, trailing: AppSpacing.lg))
                            .listRowBackground(AppColors.appSurface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .listRowSpacing(6)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .scrollDismissesKeyboard(.interactively)
    }

    private func placeRow(_ place: Place) -> some View {
        Button {
            HapticManager.light()
            onSelectPlace(place)
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                let iconColor: Color = place.isBooking
                    ? (place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
                    : categoryColor(for: place)
                let iconName: String = place.isBooking
                    ? (place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill")
                    : place.categoryEnum.sfSymbol

                ZStack {
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(iconColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let addr = place.address, !addr.isEmpty {
                        Text(addr)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(place.isBooking ? "Booking" : place.categoryEnum.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: AppSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.name)
    }

    private func categoryColor(for place: Place) -> Color {
        switch place.categoryEnum {
        case .attraction: return .blue
        case .restaurant: return AppColors.appPrimary
        case .hotel: return .purple
        case .transport: return .teal
        case .shopping: return .pink
        case .nightlife: return .indigo
        case .nature: return .green
        case .custom: return .secondary
        }
    }

    private var emptyDayState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(String(localized: "No activities yet"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(String(localized: "Activities you add to your itinerary with a location will appear here."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// =============================================================================

#if DEBUG
private extension TripMapPlacesSheet_Previews {
    static let tripId = UUID()
    static let day1Id = UUID()
    static let day2Id = UUID()

    static var sampleTrip: Trip {
        Trip(
            id: tripId,
            userId: UUID(),
            title: "Paris 2026",
            destination: "Paris, France",
            lat: 48.8566,
            lng: 2.3522,
            startDate: Date(),
            endDate: Date().addingTimeInterval(86_400 * 6),
            coverImageUrl: nil,
            notes: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    static var samplePlaces: [Place] {
        [
            Place(id: UUID(), itineraryDayId: day1Id, name: "Eiffel Tower", address: "Champ de Mars, 75007 Paris", lat: 48.8584, lng: 2.2945, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(), itineraryDayId: day1Id, name: "Louvre Museum", address: "Rue de Rivoli, 75001 Paris", lat: 48.8606, lng: 2.3376, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(), itineraryDayId: day2Id, name: "Sacré-Cœur Basilica", address: "35 Rue du Chevalier, 75018 Paris", lat: 48.8867, lng: 2.3431, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]
    }

    static var dayNumberByDayId: [UUID: Int] {
        [day1Id: 1, day2Id: 2]
    }

    static func previewMapSearchOverlay(
        embeds: Bool,
        activationDelayMs: Int = 0,
        endInline: @escaping () -> Void
    ) -> MapSearchOverlay {
        MapSearchOverlay(
            country: "FR",
            initialQuery: "",
            cityProfileId: nil,
            region: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 48.86, longitude: 2.35),
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            ),
            excludedPlaceIds: [],
            embedsInParentSheet: embeds,
            onCollapseEmbedded: embeds ? endInline : nil,
            embeddedSearchFieldActivationDelayMs: activationDelayMs,
            onPickResult: { _ in endInline() },
            onPickSuggestedResult: { _ in endInline() },
            onPickSuggestedBrowserResult: { _ in endInline() },
            onPickCategory: { _, _ in endInline() },
            onSubmitSearch: { _, _ in endInline() },
            onCancel: { endInline() }
        )
    }

    /// Mirrors `TripMapView.suggestedPlacesBrowserSheet` so Canvas sparkles opens real UI.
    @ViewBuilder
    static func suggestedPlacesBrowserSheetPreview(isPresented: Binding<Bool>) -> some View {
        SuggestedPlacesAllSheet(
            cityProfileId: nil,
            excludedPlaceIds: []
        ) { _ in
            isPresented.wrappedValue = false
        } onCancel: {
            isPresented.wrappedValue = false
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .presentationBackground(.regularMaterial)
    }
}

private enum TripMapPlacesSheet_Previews {}

#Preview("Places sheet — expanded") {
    @Previewable @State var dayFilter: Int? = nil
    @Previewable @State var sheetLayout: PlacesSheetLayout = .half
    @Previewable @State var searchText = ""
    @Previewable @State var searchPresented = false
    @Previewable @State var showSuggestedPlacesBrowser = false
    TripMapPlacesExpandedSheet(
        trip: TripMapPlacesSheet_Previews.sampleTrip,
        selectedDayFilter: $dayFilter,
        allPlacesForList: TripMapPlacesSheet_Previews.samplePlaces,
        dayNumberByDayId: TripMapPlacesSheet_Previews.dayNumberByDayId,
        onSelectPlace: { _ in },
        placesSheetLayout: $sheetLayout,
        searchText: $searchText,
        isSearchPresented: $searchPresented,
        openInlineMapSearch: .constant(false),
        onOpenSuggestedPlaces: { showSuggestedPlacesBrowser = true },
        mapSearchResults: [],
        onSelectMapSearchPreview: { _ in },
        onClearActiveMapSearch: {},
        mapSearchOverlay: { embeds, delay, end in
            TripMapPlacesSheet_Previews.previewMapSearchOverlay(embeds: embeds, activationDelayMs: delay, endInline: end)
        }
    )
    .sheet(isPresented: $showSuggestedPlacesBrowser) {
        TripMapPlacesSheet_Previews.suggestedPlacesBrowserSheetPreview(isPresented: $showSuggestedPlacesBrowser)
    }
}

#Preview("Places sheet — expanded, day 1 selected") {
    @Previewable @State var dayFilter: Int? = 1
    @Previewable @State var sheetLayout: PlacesSheetLayout = .half
    @Previewable @State var searchText = ""
    @Previewable @State var searchPresented = false
    @Previewable @State var showSuggestedPlacesBrowser = false
    TripMapPlacesExpandedSheet(
        trip: TripMapPlacesSheet_Previews.sampleTrip,
        selectedDayFilter: $dayFilter,
        allPlacesForList: TripMapPlacesSheet_Previews.samplePlaces,
        dayNumberByDayId: TripMapPlacesSheet_Previews.dayNumberByDayId,
        onSelectPlace: { _ in },
        placesSheetLayout: $sheetLayout,
        searchText: $searchText,
        isSearchPresented: $searchPresented,
        openInlineMapSearch: .constant(false),
        onOpenSuggestedPlaces: { showSuggestedPlacesBrowser = true },
        mapSearchResults: [],
        onSelectMapSearchPreview: { _ in },
        onClearActiveMapSearch: {},
        mapSearchOverlay: { embeds, delay, end in
            TripMapPlacesSheet_Previews.previewMapSearchOverlay(embeds: embeds, activationDelayMs: delay, endInline: end)
        }
    )
    .sheet(isPresented: $showSuggestedPlacesBrowser) {
        TripMapPlacesSheet_Previews.suggestedPlacesBrowserSheetPreview(isPresented: $showSuggestedPlacesBrowser)
    }
}

/// Presents the expanded places UI in a `.sheet` with detents — closest to the map tab experience for Xcode Canvas.
#Preview("Places sheet — in sheet (Canvas)") {
    TripMapPlacesExpandedSheetPreviewHost()
}

private struct TripMapPlacesExpandedSheetPreviewHost: View {
    @State private var showSheet = true
    @State private var dayFilter: Int? = nil
    @State private var sheetLayout: PlacesSheetLayout = .half
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var openInlineSearch = false
    @State private var showSuggestedPlacesBrowser = false

    var body: some View {
        Color.clear
            .sheet(isPresented: $showSheet) {
                TripMapPlacesExpandedSheet(
                    trip: TripMapPlacesSheet_Previews.sampleTrip,
                    selectedDayFilter: $dayFilter,
                    allPlacesForList: TripMapPlacesSheet_Previews.samplePlaces,
                    dayNumberByDayId: TripMapPlacesSheet_Previews.dayNumberByDayId,
                    onSelectPlace: { _ in },
                    placesSheetLayout: $sheetLayout,
                    searchText: $searchText,
                    isSearchPresented: $searchPresented,
                    openInlineMapSearch: $openInlineSearch,
                    onOpenSuggestedPlaces: { showSuggestedPlacesBrowser = true },
                    mapSearchResults: [],
                    onSelectMapSearchPreview: { _ in },
                    onClearActiveMapSearch: {},
                    mapSearchOverlay: { embeds, delay, end in
                        TripMapPlacesSheet_Previews.previewMapSearchOverlay(embeds: embeds, activationDelayMs: delay, endInline: end)
                    }
                )
                .presentationDetents(
                    [PlacesSheetLayout.compactDetent, PlacesSheetLayout.halfOpenDetent, .large],
                    selection: Binding(
                        get: { sheetLayout.presentationDetent },
                        set: { sheetLayout = PlacesSheetLayout(resolving: $0) }
                    )
                )
                .presentationDragIndicator(.hidden)
                .sheet(isPresented: $showSuggestedPlacesBrowser) {
                    TripMapPlacesSheet_Previews.suggestedPlacesBrowserSheetPreview(isPresented: $showSuggestedPlacesBrowser)
                }
            }
    }
}

#endif
