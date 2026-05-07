import MapKit
import SwiftUI

// MARK: - Sheet layout (detent ↔︎ coarse state)

/// Coarse places-sheet layout so we can hide search in the docked (minimized) detent.
enum PlacesSheetLayout: Equatable {
    case docked
    case half
    case full

    /// Grabber + exactly one compact chrome row. Keep this tight so the docked
    /// state reads as the search bar or day-capsule slider itself, not a larger
    /// mini sheet with extra vertical dead space.
    static let compactDetent = PresentationDetent.height(84)

    /// Proportional sheet stop so the half-open map sheet scales with screen height.
    static let halfOpenDetent = PresentationDetent.fraction(0.46)

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

/// Day filters + places list. Top chrome: grabber, search capsule, **Suggested Places** (map pin)
/// whenever the inline search UI is hidden. In the docked detent, active search text keeps the search
/// capsule visible with a close button; otherwise only the day filters remain.
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
    /// Opens the suggested-places sheet (pin control in docked / half / full chrome).
    let onOpenSuggestedPlaces: () -> Void
    /// Pins from the last map search (keyboard Search / category). Shown in the half sheet under the search capsule.
    var mapSearchResults: [MapSearchPreview] = []
    let onSelectMapSearchPreview: (MapSearchPreview) -> Void
    /// Clears map search pins + capsule text (same outcome as clearing the system search field).
    let onClearActiveMapSearch: () -> Void
    /// Builds map search UI; `activationDelayMs` is 0 when the places sheet is already at `.full`, otherwise a short delay while the detent animates.
    let mapSearchOverlay: (_ embedsInParentSheet: Bool, _ activationDelayMs: Int, _ endInlineSearch: @escaping () -> Void) -> MapSearchOverlay

    /// True when map search pins are shown and the camera has drifted from the search origin (see `TripMapView.shouldShowSearchThisArea`).
    var showSearchThisArea: Bool = false
    let onSearchThisArea: () -> Void

    @State private var isInlineMapSearchActive = false
    @State private var inlineSearchFieldActivationDelayMs = 0

    /// Committed (settled) structural layout.
    ///
    /// `presentationDetents(_:selection:)` writes to its selection binding
    /// *during* the drag gesture as the sheet crosses detent thresholds —
    /// not only when the user commits. If we gate structural view swaps
    /// directly on `placesSheetLayout`, a short downward pull from `.half`
    /// briefly sets the binding to `.docked`; the content collapses to
    /// capsule-only chrome, but the sheet springs back to `.half` when the
    /// gesture ends, leaving a half-height sheet showing docked-style
    /// content until the binding settles. Apple Maps keeps its sheet in
    /// sync by updating content structure only after the detent has
    /// actually settled. We replicate that by debouncing commits here.
    ///
    /// Default is `.docked` (the collapsed state) so the first frame never
    /// renders expanded content before `.onAppear` syncs to the live
    /// binding — matches the map shared state's own default.
    @State private var committedLayout: PlacesSheetLayout = .docked
    @State private var commitTask: Task<Void, Never>?

    /// Drives motion choice for chrome transitions so we honour Accessibility > Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Debounce window covering the sheet's own settle animation (~0.3s system
    /// spring). Transient detent crossings during an interactive drag are
    /// cancelled by the next change before they ever commit.
    private static let layoutCommitDebounceMs: UInt64 = 180
    /// Top scroll inset for the overlaid search row + day capsules so list rows
    /// begin below the floating controls instead of sitting underneath them.
    private static let searchAndDayChromeScrollTopMargin: CGFloat = AppSpacing.xxxl + AppSpacing.xxxl + AppSpacing.xl
    /// Top scroll inset for submitted search results, where only the search row
    /// is overlaid.
    private static let searchChromeScrollTopMargin: CGFloat = AppSpacing.xxxl + AppSpacing.xl
    /// Extra list scroll inset when the "Search this area" row is visible under the search bar.
    private static let searchThisAreaScrollTopInset: CGFloat = 52

    private var showsMapSearchResultsList: Bool {
        !mapSearchResults.isEmpty
    }

    private var hasActiveMapSearchText: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var dayListTopContentMargin: CGFloat {
        let base = Self.searchAndDayChromeScrollTopMargin
        return showSearchThisArea ? base + Self.searchThisAreaScrollTopInset : base
    }

    private var mapSearchListTopMargin: CGFloat {
        let base = Self.searchChromeScrollTopMargin
        return showSearchThisArea ? base + Self.searchThisAreaScrollTopInset : base
    }

    /// Composite key that collapses every driver of chrome layout into a single
    /// value so the body's `.animation(_, value:)` re-runs exactly once per change.
    private struct ChromeAnimationKey: Hashable {
        let layout: PlacesSheetLayout
        let hasSearchText: Bool
        let showSearchThisArea: Bool
    }

    private var chromeAnimationKey: ChromeAnimationKey {
        ChromeAnimationKey(
            layout: committedLayout,
            hasSearchText: hasActiveMapSearchText,
            showSearchThisArea: showSearchThisArea
        )
    }

    /// Flat ease that co-runs with the native sheet detent animation without
    /// overshoot. A spring with low damping reads as an additional "bounce" on
    /// top of the sheet's own critically damped spring, which is the artifact
    /// Apple Maps avoids. Reduce Motion falls back to a short linear fade.
    private var chromeAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.10)
            : .easeInOut(duration: 0.22)
    }

    /// Summarises the sheet's current state for VoiceOver (announced as a container label).
    private var sheetAccessibilityLabel: String {
        switch committedLayout {
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

    /// Settles a pending commit after the detent value has been stable for
    /// `layoutCommitDebounceMs`. Cancelling-then-rescheduling means transient
    /// mid-drag threshold crossings (e.g. `.half → .docked → .half` within
    /// ~300 ms) never commit — only a truly settled detent does.
    private func scheduleLayoutCommit(_ target: PlacesSheetLayout) {
        commitTask?.cancel()
        guard target != committedLayout else { return }
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.layoutCommitDebounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            guard placesSheetLayout == target, committedLayout != target else { return }
            committedLayout = target
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            expandedSheetDragGrabber

            if isInlineMapSearchActive {
                inlineMapSearchView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Native `.searchable` inside the embedded `NavigationStack`
                    // reserves its own top chrome. Pull the search surface back
                    // toward our custom sheet grabber so the two read as one unit.
                    .padding(.top, -AppSpacing.sm)
            } else {
                // Structural gates read `committedLayout` (settled detent),
                // not the transient selection binding. During an interactive
                // drag the system may write a mid-threshold detent into the
                // selection binding that the sheet never actually commits to;
                // ignoring those transients keeps the content in lockstep
                // with the sheet's real settle position.
                if committedLayout == .docked {
                    topChromeRow
                } else {
                    ZStack(alignment: .top) {
                        expandedContentArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .transition(.opacity)
                            .accessibilityHidden(committedLayout == .docked)

                        expandedChromeOverlay
                    }
                }
            }
        }
        .background {
            AppColors.appBackground.ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sheetAccessibilityLabel)
        .animation(chromeAnimation, value: chromeAnimationKey)
        .onAppear {
            committedLayout = placesSheetLayout
        }
        .onDisappear {
            commitTask?.cancel()
            commitTask = nil
        }
        .onChange(of: placesSheetLayout) { _, newLayout in
            scheduleLayoutCommit(newLayout)
            if newLayout == .docked {
                isSearchPresented = false
                isInlineMapSearchActive = false
            }
            // No detent-change haptic: Apple Maps does not add an app-level
            // haptic here, and doing so stacks on top of the subtle system
            // feedback already produced by the sheet's gesture recognizer.
        }
        .onChange(of: openInlineMapSearch) { _, shouldOpen in
            guard shouldOpen else { return }
            openInlineMapSearch = false
            inlineSearchFieldActivationDelayMs = (placesSheetLayout == .full) ? 0 : 260
            placesSheetLayout = .full
            isInlineMapSearchActive = true
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

    private var expandedChromeOverlay: some View {
        VStack(spacing: 0) {
            searchBarChromeRow

            if showSearchThisArea {
                Button {
                    HapticManager.light()
                    onSearchThisArea()
                } label: {
                    Label("Search this area", systemImage: "arrow.clockwise.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                        .foregroundStyle(AppColors.appPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, AppSpacing.md)
                .padding(.bottom, AppSpacing.xs)
                .accessibilityLabel("Search this area")
                .accessibilityHint("Re-runs the last search in the current map region")
            }

            if !showsMapSearchResultsList {
                dayCapsulesChromeRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }

    /// Single top row used at every detent.
    /// - Docked + empty → day capsules only (user's rule).
    /// - Docked + text → search bar with X.
    /// - Expanded  → always search bar (expanded content below hosts the capsules).
    ///
    /// Uses a conditional `Group` (not `ZStack`) so the row sizes to the active
    /// variant's natural height — avoids the ~22pt of dead space the ZStack max
    /// height introduced in docked+empty. The crossfade is driven by the body's
    /// single spring animation via `.transition(.opacity)`.
    @ViewBuilder
    private var topChromeRow: some View {
        if committedLayout == .docked && !hasActiveMapSearchText {
            dayCapsulesChromeRow
                .transition(.opacity)
        } else {
            searchBarChromeRow
                .transition(.opacity)
        }
    }

    /// Content below the top row. Always rendered so the system sheet simply
    /// clips during detent animations — avoids mid-drag empty panels.
    /// - Has results → results list.
    /// - Otherwise → (optional) day capsules as filter chrome + activities list.
    /// In docked+empty the top row is already the capsules, so we skip the filter row
    /// to avoid a duplicate capsule row appearing briefly as the sheet grows.
    @ViewBuilder
    private var expandedContentArea: some View {
        if showsMapSearchResultsList {
            mapSubmittedSearchResultsList
        } else {
            TripMapPlacesDayListContent(
                trip: trip,
                selectedDayFilter: $selectedDayFilter,
                allPlacesForList: allPlacesForList,
                dayNumberByDayId: dayNumberByDayId,
                onSelectPlace: onSelectPlace,
                showsDayTabs: false,
                topContentMargin: dayListTopContentMargin
            )
        }
    }

    private var searchBarChromeRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            mapSearchCapsuleButton
                .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing accessory mirrors the original behaviour:
            // - Active search text (or committed results) → clear (X) button.
            // - Otherwise → Suggested Places (pin) shortcut.
            if hasActiveMapSearchText || showsMapSearchResultsList {
                activeMapSearchClearButton
            } else {
                mapsStyleSuggestedPlacesButton
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.sm)
    }

    private var dayCapsulesChromeRow: some View {
        DayFilterCapsulesView(
            selectedDay: $selectedDayFilter,
            dayCount: max(trip.dayCount, 1),
            controlSize: .regular
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap is only hittable when the capsule row is the top chrome, which
            // only happens in the settled docked state.
            guard committedLayout == .docked else { return }
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
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xs)
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
        let badgeAccent = mapRowIconBadgeAccent(symbol: icon.symbol, family: icon.family)
        ZStack {
            Circle()
                .fill(AppColors.iconBadgeGradient(accent: badgeAccent))
            Image(systemName: icon.symbol)
                .font(.appCaption.weight(.semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppColors.iconOnColoredSurface)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func mapRowIconBadgeAccent(symbol: String, family: PlaceCategoryFamily) -> Color {
        symbol.hasPrefix("mappin") || family == .generic ? AppColors.appError : family.color
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

                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(preview.name)
                                    .font(.appBody.weight(.semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(2)
                                if !preview.subtitle.isEmpty {
                                    Text(preview.subtitle)
                                        .font(.appCaption)
                                        .foregroundStyle(AppColors.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, AppSpacing.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
                    .listRowBackground(AppColors.appSurface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, mapSearchListTopMargin, for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(AppColors.appBackground)
        .environment(\.defaultMinListRowHeight, 52)
    }

    /// Trailing **clear** control (filled X), same glyph family as the system search field dismiss.
    private var activeMapSearchClearButton: some View {
        MapChromeIconButton(
            systemName: "xmark.circle.fill",
            iconFont: .system(size: MapChromeIconMetrics.dismissGlyphPointSize, weight: .regular),
            symbolRenderingMode: .hierarchical,
            tint: AppColors.iconOnColoredSurface,
            accessibilityLabel: String(localized: "Close"),
            accessibilityHint: String(localized: "Clears the search and removes results from the map")
        ) {
            HapticManager.light()
            onClearActiveMapSearch()
        }
    }

    private var mapSearchCapsuleButton: some View {
        Button {
            HapticManager.light()
            isSearchPresented = false
            // No detent animation when already full — focus can run immediately (see `MapSearchOverlay.onOverlayAppear`).
            inlineSearchFieldActivationDelayMs = (placesSheetLayout == .full) ? 0 : 260
            placesSheetLayout = .full
            isInlineMapSearchActive = true
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(AppColors.iconOnColoredSurface)

                Group {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(String(localized: "Search places"))
                            .foregroundStyle(AppColors.textTertiary)
                    } else {
                        Text(searchText)
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                    }
                }
                .font(.appBody)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "mic.fill")
                    .font(.appCaption.weight(.medium))
                    .foregroundStyle(AppColors.iconOnColoredSurface)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .background(AppColors.appSurface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Search places"))
        .accessibilityHint(String(localized: "Expands search in this sheet"))
    }

    private var mapsStyleSuggestedPlacesButton: some View {
        MapChromeIconButton(
            systemName: "mappin.circle.fill",
            iconFont: .system(size: MapChromeIconMetrics.accessoryGlyphPointSize, weight: .semibold),
            symbolRenderingMode: .monochrome,
            monochromeForeground: .primary,
            legacyDiskFill: true,
            accessibilityLabel: String(localized: "Suggested Places"),
            accessibilityHint: String(localized: "Opens the list of suggested places for this trip")
        ) {
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
            .fill(AppColors.textTertiary.opacity(0.45))
            .frame(width: 52, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
            .accessibilityHidden(true)
    }

}

// MARK: - Day list content
//
// Search is gone — the floating capsule (Phase 3) takes that responsibility.
// This view hosts only day tabs, day pages, and place rows.

private struct TripMapPlacesDayListContent: View {
    private enum Metrics {
        static let leadingVisualSize: CGFloat = 44
    }

    let trip: Trip
    @Binding var selectedDayFilter: Int?
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    let onSelectPlace: (Place) -> Void
    var showsDayTabs: Bool = true
    var topContentMargin: CGFloat = AppSpacing.xs

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
                    .padding(.horizontal, AppSpacing.sm)
                }
                .frame(height: 44)
                .background(AppColors.appSurface)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppColors.appDivider)
                        .frame(height: 1)
                }
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
            withAnimation(AppSpring.snappy) {
                selectedDayFilter = dayNum == 0 ? nil : dayNum
            }
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: dayNum == 0 ? 0 : AppSpacing.xs) {
                    if dayNum != 0 {
                        Circle().fill(accentColor).frame(width: 6, height: 6)
                    }
                    Text(label)
                        .font(.appCaption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? accentColor : AppColors.textSecondary)
                        .fixedSize()
                }
                .padding(.horizontal, AppSpacing.md)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(isSelected ? accentColor : Color.clear)
                    .frame(height: 2)
            }
            .frame(height: 44)
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
                            .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
                            .listRowBackground(AppColors.appSurface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, topContentMargin, for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
        .listSectionSpacing(.compact)
        .listRowSpacing(AppSpacing.sm)
        .scrollContentBackground(.hidden)
        .background(AppColors.appBackground)
        .scrollDismissesKeyboard(.interactively)
    }

    private func placeRow(_ place: Place) -> some View {
        Button {
            HapticManager.light()
            onSelectPlace(place)
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                placeRowLeadingVisual(for: place)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(place.name)
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                    if let addr = place.address, !addr.isEmpty {
                        Text(addr)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text(place.isBooking ? "Booking" : place.categoryEnum.label)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, AppSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.name)
    }

    @ViewBuilder
    private func placeRowLeadingVisual(for place: Place) -> some View {
        let icon = placeRowIcon(for: place)
        if let url = Self.listImageURL(for: place) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeIconZStack(icon: icon, showsProgress: true)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeIconZStack(icon: icon, showsProgress: false)
                @unknown default:
                    placeIconZStack(icon: icon, showsProgress: false)
                }
            }
            .frame(width: Metrics.leadingVisualSize, height: Metrics.leadingVisualSize)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .accessibilityHidden(true)
        } else {
            placeIconZStack(icon: icon, showsProgress: false)
                .accessibilityHidden(true)
        }
    }

    private func placeIconZStack(icon: (symbol: String, badgeAccent: Color), showsProgress: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.iconBadgeGradient(accent: icon.badgeAccent))
                .frame(width: Metrics.leadingVisualSize, height: Metrics.leadingVisualSize)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppColors.iconOnColoredSurface)
            } else {
                Image(systemName: icon.symbol)
                    .font(.appBody.weight(.medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppColors.iconOnColoredSurface)
            }
        }
    }

    /// Prefer catalog `thumbnail_url`, then `hero_image_url` / city hero fallback from `Place.heroImageUrl`.
    private static func listImageURL(for place: Place) -> URL? {
        for raw in [place.thumbnailUrl, place.heroImageUrl] {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed) { return url }
        }
        return nil
    }

    private func placeRowIcon(for place: Place) -> (symbol: String, badgeAccent: Color) {
        if place.isBooking {
            guard let bookingCategory = place.bookingCategoryEnum else {
                return (symbol: "mappin", badgeAccent: AppColors.appError)
            }
            return (symbol: bookingCategory.sfSymbol, badgeAccent: bookingCategory.family.color)
        }

        let family = place.categoryEnum.family
        let symbol = family == .generic ? "mappin" : place.categoryEnum.sfSymbol
        return (symbol: symbol, badgeAccent: family == .generic ? AppColors.appError : family.color)
    }

    private var emptyDayState: some View {
        VStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(AppColors.iconBadgeGradient(accent: AppColors.appError))
                    .frame(width: 56, height: 56)
                Image(systemName: "mappin")
                    .font(.sectionHeader)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppColors.iconOnColoredSurface)
            }
            .accessibilityHidden(true)
            Text(String(localized: "No activities yet"))
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
            Text(String(localized: "Activities you add to your itinerary with a location will appear here."))
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
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

    /// Mirrors `TripMapView.suggestedPlacesBrowserSheet` so Canvas pin opens real UI.
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
        .presentationBackground(AppColors.appBackground)
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
        },
        showSearchThisArea: false,
        onSearchThisArea: {}
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
        },
        showSearchThisArea: false,
        onSearchThisArea: {}
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
                    },
                    showSearchThisArea: false,
                    onSearchThisArea: {}
                )
                .presentationDetents(
                    [PlacesSheetLayout.compactDetent, PlacesSheetLayout.halfOpenDetent, .large],
                    selection: Binding(
                        get: { sheetLayout.presentationDetent },
                        set: { sheetLayout = PlacesSheetLayout(resolving: $0) }
                    )
                )
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
                .sheet(isPresented: $showSuggestedPlacesBrowser) {
                    TripMapPlacesSheet_Previews.suggestedPlacesBrowserSheetPreview(isPresented: $showSuggestedPlacesBrowser)
                }
            }
    }
}

#endif
