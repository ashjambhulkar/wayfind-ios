//
//  MapSearchOverlay.swift
//  wayfind
//
//  Phase 3-4 of the Map Screen Search Redesign.
//
//  Hybrid full-screen overlay invoked from `MapSearchPill`. Behaviour:
//
//   • Free-text typing — overlay stays up. Shows recents + Apple
//     suggestions + city_places quick-pick rows for the trip's city.
//     Selecting a row resolves to a `MapSearchPreview`, dismisses the
//     overlay, and hands the preview back to the map screen.
//
//   • Category pill tap — overlay dismisses *immediately* so the user
//     watches the SearchResultAnnotation cluster land on the map.
//     The map screen runs the parallel Apple+DB merge in the
//     background and replaces `searchResults`.
//
//   • The China region (or any feature-flagged region) routes the
//     free-text path through `PlaceSearchService` instead of
//     `AppleMapSearchService` — same `MapSearchPreview` shape, no
//     branching downstream.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapSearchOverlay: View {
    /// The trip's destination country in ISO 3166-1 alpha-2. Drives
    /// the autocomplete provider routing (China-fallback etc.).
    var country: String?
    var initialQuery: String = ""

    /// Optional resolved city profile id. When present we fan out to
    /// city_places for free-typing previews.
    var cityProfileId: UUID?

    /// Live region from the map screen — used to bias MapKit ranking
    /// and to bbox the city_places query.
    var region: MKCoordinateRegion

    /// Trip's currently scheduled-day place_ids; CityPlacesSearchService
    /// uses this to skip rows already on the itinerary.
    var excludedPlaceIds: Set<String>

    /// When true, this overlay lives inside the trip places sheet — use
    /// `onCollapseEmbedded` instead of `dismiss()` so the parent sheet stays open.
    var embedsInParentSheet: Bool = false

    /// Collapses the embedded search surface (e.g. return to day list). Ignored when not embedded.
    var onCollapseEmbedded: (() -> Void)?

    /// When true (full-screen overlay on the map, not a `.sheet`), never call `Environment.dismiss`.
    var suppressesEnvironmentDismiss: Bool = false

    /// When embedded: wait this long before presenting/focusing the nav search field so a
    /// parent sheet can finish a detent animation. Use `0` when the parent is already `.large`.
    var embeddedSearchFieldActivationDelayMs: Int = 0

    /// Called when the user picks a single result (autocomplete or
    /// recent). Hands the resolved preview back so the map can drop a
    /// pin and open the preview sheet.
    var onPickResult: (MapSearchPreview) -> Void

    /// Called when the user picks from the inline Suggested Places section.
    /// The map can restore this search sheet after the preview dismisses.
    var onPickSuggestedResult: (MapSearchPreview) -> Void

    /// Called when the user picks from the dedicated Suggested Places
    /// browser ("See all"). The map can restore that browser after preview.
    var onPickSuggestedBrowserResult: (MapSearchPreview) -> Void

    /// Called when the user taps a category pill. Hands a list of
    /// blended Apple+DB previews back so the map can render
    /// SearchResultAnnotations.
    var onPickCategory: (CategoryPill, [MapSearchPreview]) -> Void

    /// Keyboard Search submit. Dismisses this full-screen search surface and
    /// hands all blended results back to the map, Apple Maps-style.
    var onSubmitSearch: (_ query: String, _ results: [MapSearchPreview]) -> Void

    /// Dismiss without picking.
    var onCancel: () -> Void

    /// Embedded in the places sheet: opens the full suggested-places browser while search is idle (`!isSearching`).
    var onOpenSuggestedPlacesSheet: (() -> Void)?

    // MARK: - Local state

    @State private var query: String
    @State private var apple = AppleMapSearchService()
    @State private var google = PlaceSearchService()
    @State private var ownedRows: [MapSearchPreview] = []
    @State private var ownedRowsTask: Task<Void, Never>?
    @State private var pendingResolve = false
    /// Set when the user taps a suggestion whose resolved coordinate
    /// landed far outside the bias region (Apple's silent global
    /// fallback). Drives a non-blocking inline banner so the tap
    /// doesn't appear to do nothing.
    @State private var outOfRegionWarning: String?

    // Empty-state "Suggested Places" — top tier rows from the trip's
    // city. Loaded once on appear; we cap to a small carousel here and
    // hand the full list to a "See all" sheet.
    @State private var suggestedPlaces: [MapSearchPreview] = []
    @State private var loadingSuggested = false
    @State private var suggestedLoadedFor: String?
    @State private var showAllSuggested = false

    @AppStorage("mapSearchRecents") private var recentsRaw: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSearching) private var isSearching

    /// Embedded in the places sheet: system search must be presented + focused after the
    /// parent sheet finishes animating to `.large`, otherwise the field never becomes first responder.
    @State private var embeddedSearchPresentationExpanded = false
    @FocusState private var embeddedSearchFieldFocused: Bool
    /// After the first embedded activation pass (delay/yield + expand + focus), so the suggested shortcut
    /// does not flash on screen while `isPresented`/focus are still settling.
    @State private var embeddedSuggestedShortcutActivationReady = false

    private var provider: FeatureFlagsService.MapSearchProvider {
        FeatureFlagsService.shared.mapSearchProvider(forCountry: country)
    }

    private let recentsCap = 6

    private var suggestedPlacesTaskKey: String {
        "\(cityProfileId?.uuidString ?? "_")|\(excludedPlaceIds.sorted().joined(separator: ","))"
    }

    private var trimmedEmbeddedSearchQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsCategoryPills: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Focused or any typed text: hide the suggested-places shortcut (system search supplies Cancel / dismiss).
    private var embeddedSearchHidesSuggestedShortcut: Bool {
        guard embedsInParentSheet else { return false }
        if !trimmedEmbeddedSearchQuery.isEmpty { return true }
        if #available(iOS 18, *) {
            return embeddedSearchFieldFocused
        }
        return isSearching
    }

    /// Sparkles only in the idle embedded state (no focus, empty field), after activation settles.
    private var showsEmbeddedSuggestedPlacesShortcut: Bool {
        guard onOpenSuggestedPlacesSheet != nil, embeddedSuggestedShortcutActivationReady else { return false }
        return !embeddedSearchHidesSuggestedShortcut
    }

    init(
        country: String?,
        initialQuery: String = "",
        cityProfileId: UUID?,
        region: MKCoordinateRegion,
        excludedPlaceIds: Set<String>,
        embedsInParentSheet: Bool = false,
        onCollapseEmbedded: (() -> Void)? = nil,
        suppressesEnvironmentDismiss: Bool = false,
        embeddedSearchFieldActivationDelayMs: Int = 0,
        onPickResult: @escaping (MapSearchPreview) -> Void,
        onPickSuggestedResult: @escaping (MapSearchPreview) -> Void,
        onPickSuggestedBrowserResult: @escaping (MapSearchPreview) -> Void,
        onPickCategory: @escaping (CategoryPill, [MapSearchPreview]) -> Void,
        onSubmitSearch: @escaping (_ query: String, _ results: [MapSearchPreview]) -> Void,
        onCancel: @escaping () -> Void,
        onOpenSuggestedPlacesSheet: (() -> Void)? = nil
    ) {
        self.country = country
        self.initialQuery = initialQuery
        self.cityProfileId = cityProfileId
        self.region = region
        self.excludedPlaceIds = excludedPlaceIds
        self.embedsInParentSheet = embedsInParentSheet
        self.onCollapseEmbedded = onCollapseEmbedded
        self.suppressesEnvironmentDismiss = suppressesEnvironmentDismiss
        self.embeddedSearchFieldActivationDelayMs = embeddedSearchFieldActivationDelayMs
        self.onPickResult = onPickResult
        self.onPickSuggestedResult = onPickSuggestedResult
        self.onPickSuggestedBrowserResult = onPickSuggestedBrowserResult
        self.onPickCategory = onPickCategory
        self.onSubmitSearch = onSubmitSearch
        self.onCancel = onCancel
        self.onOpenSuggestedPlacesSheet = onOpenSuggestedPlacesSheet
        _query = State(initialValue: initialQuery)
        // Embedded: start with the search field expanded so the first frame matches full-screen search chrome
        // (async work below only defers first responder, not the visible search bar).
        _embeddedSearchPresentationExpanded = State(initialValue: embedsInParentSheet)
    }

    /// When embedded in the trip places sheet, stay visually one surface with the parent (no second opaque card).
    private var searchSurfaceBackground: Color {
        embedsInParentSheet ? Color.clear : AppColors.appBackground
    }

    var body: some View {
        Group {
            if embedsInParentSheet {
                NavigationStack {
                    mapSearchEmbeddedContent
                }
            } else {
                NavigationStack {
                    mapSearchStackHostedContent
                }
            }
        }
        .onAppear {
            onOverlayAppear()
        }
        .task(id: suggestedPlacesTaskKey) {
            await loadSuggestedIfNeeded()
        }
        .onChange(of: query) { _, q in
            // Any new keystroke invalidates a stale "out of region"
            // banner — the user is clearly trying a different term.
            outOfRegionWarning = nil
            refreshSuggestions(for: q)
        }
        .onDisappear {
            apple.clear()
            google.clearResults()
            ownedRowsTask?.cancel()
            resetEmbeddedSearchPresentationState()
        }
        .sheet(isPresented: $showAllSuggested) {
            SuggestedPlacesAllSheet(
                cityProfileId: cityProfileId,
                excludedPlaceIds: excludedPlaceIds
            ) { picked in
                showAllSuggested = false
                commitSuggestedBrowserPick(picked)
            } onCancel: {
                showAllSuggested = false
            }
            .presentationDetents([.large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
        }
        .tint(AppColors.appPrimary)
    }

    /// Full-screen map search only — needs `NavigationStack` for drawer-style `.searchable` + toolbar close.
    @ViewBuilder
    private var mapSearchStackHostedContent: some View {
        let shell = resultsListContainer
            .background(searchSurfaceBackground)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("")

        shell
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "Search...")
            )
            .onSubmit(of: .search) {
                submitCurrentQueryToMap()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        HapticManager.light()
                        onCancel()
                        if !suppressesEnvironmentDismiss {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(String(localized: "Close"))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsCategoryPills {
                    categoryPillsInset
                }
            }
    }

    /// Embedded in the trip places sheet: same drawer-style `.searchable` as full-screen search (needs a
    /// `NavigationStack` host). Optional suggested shortcut in `mapSearchEmbeddedTopInset`; dismiss via system search UI.
    @ViewBuilder
    private var mapSearchEmbeddedContent: some View {
        let shell = resultsListContainer
            .background(searchSurfaceBackground)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("")
            // Pulls the drawer search field up vs. an opaque bar — matches `TripMapView` map chrome.
            .toolbarBackground(.hidden, for: .navigationBar)

        Group {
            if #available(iOS 18, *) {
                shell
                    .searchable(
                        text: $query,
                        isPresented: $embeddedSearchPresentationExpanded,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "Search...")
                    )
                    .searchFocused($embeddedSearchFieldFocused)
            } else {
                shell
                    .searchable(
                        text: $query,
                        isPresented: $embeddedSearchPresentationExpanded,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "Search...")
                    )
            }
        }
        .onSubmit(of: .search) {
            submitCurrentQueryToMap()
        }
        .onChange(of: embeddedSearchPresentationExpanded) { _, expanded in
            if !expanded {
                onCollapseEmbedded?()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            mapSearchEmbeddedTopInset
        }
    }

    /// Trailing **Suggested** only when the field is idle; no extra Close (`.searchable` already provides one).
    private var mapSearchEmbeddedTopInset: some View {
        VStack(spacing: 0) {
            if let openSuggested = onOpenSuggestedPlacesSheet, showsEmbeddedSuggestedPlacesShortcut {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        HapticManager.light()
                        openSuggested()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(Color(UIColor.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .accessibilityLabel(String(localized: "Suggested Places"))
                    .accessibilityHint(String(localized: "Opens the list of suggested places for this trip"))
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.bottom, 2)
            }
            if showsCategoryPills {
                categoryPillsInsetEmbeddedUnderSearch
            }
        }
    }

    private func onOverlayAppear() {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refreshSuggestions(for: query)
        }
        guard embedsInParentSheet else { return }
        embeddedSuggestedShortcutActivationReady = false
        // Keep the search bar visible immediately; only delay grabbing first responder so a parent
        // sheet detent animation can finish (see `embeddedSearchFieldActivationDelayMs`).
        embeddedSearchPresentationExpanded = true
        if #available(iOS 18, *) {
            embeddedSearchFieldFocused = false
        }
        Task { @MainActor in
            if embeddedSearchFieldActivationDelayMs > 0 {
                try? await Task.sleep(for: .milliseconds(embeddedSearchFieldActivationDelayMs))
            } else {
                await Task.yield()
            }
            if #available(iOS 18, *) {
                embeddedSearchFieldFocused = true
            }
            embeddedSuggestedShortcutActivationReady = true
        }
    }

    private func resetEmbeddedSearchPresentationState() {
        guard embedsInParentSheet else { return }
        embeddedSuggestedShortcutActivationReady = false
        embeddedSearchPresentationExpanded = false
        if #available(iOS 18, *) {
            embeddedSearchFieldFocused = false
        }
    }

    private var categoryPillsInset: some View {
        CategoryPillsRow { pill in
            HapticManager.selection()
            runCategorySearch(pill)
        }
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(searchSurfaceBackground)
    }

    /// Tighter top padding than `categoryPillsInset` so the row sits closer to the embedded drawer search field.
    private var categoryPillsInsetEmbeddedUnderSearch: some View {
        CategoryPillsRow { pill in
            HapticManager.selection()
            runCategorySearch(pill)
        }
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(searchSurfaceBackground)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsListContainer: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            recentsAndDefaults
        } else {
            mergedSuggestions
        }
    }

    private var recentsAndDefaults: some View {
        // Apple Maps-style empty state: Suggested Places from this trip's
        // city, rendered with thumbnails so the user can recognise them
        // at a glance. "See all" hands the full list off to a dedicated sheet.
        List {
            suggestedPlacesHeaderRow
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // Suggested Places — always render the section so the user
            // sees the header even before `resolvedCityProfileId` lands.
            // The body adapts to loading / unresolved / empty / loaded
            // so the surface never goes silently blank.
            Section {
                if loadingSuggested && suggestedPlaces.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading suggestions…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .listRowBackground(AppColors.appSurface)
                } else if cityProfileId == nil {
                    Text("Suggestions appear here once your destination loads.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(AppColors.appSurface)
                } else if suggestedPlaces.isEmpty {
                    Text("No curated places yet for this city.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(AppColors.appSurface)
                } else {
                    ForEach(suggestedPlaces.prefix(4)) { preview in
                        suggestedPlaceRow(preview)
                    }
                }
            }

            if suggestedPlaces.isEmpty && !loadingSuggested && cityProfileId == nil {
                Section {
                    Text("Type a place, neighborhood, or category like \"coffee\".")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(AppSpacing.xs)
        .scrollContentBackground(.hidden)
        .modifier(MapSearchEmbeddedScrollHorizontalBalanceModifier(isEmbedded: embedsInParentSheet))
        .scrollDismissesKeyboard(.interactively)
    }

    /// Custom header row instead of a `Section` header because inset-grouped
    /// lists apply extra leading padding to section headers.
    private var suggestedPlacesHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Suggested Places")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer(minLength: 0)
            if suggestedPlaces.count > 4 {
                Button {
                    HapticManager.selection()
                    showAllSuggested = true
                } label: {
                    HStack(spacing: 2) {
                        Text("See all")
                            .font(.footnote.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(AppColors.appPrimary)
                    .textCase(nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all suggested places")
            }
        }
    }

    /// Suggested-place row used in the empty state. Mirrors the Apple
    /// Maps card row — square thumbnail, title, category caption.
    @ViewBuilder
    private func suggestedPlaceRow(_ preview: MapSearchPreview) -> some View {
        Button {
            commitInlineSuggestedPick(preview)
        } label: {
            HStack(spacing: 12) {
                SuggestedThumbnail(preview: preview)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let cat = preview.category {
                        Text(cat.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !preview.subtitle.isEmpty {
                        Text(preview.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
        .listRowBackground(AppColors.appSurface)
    }

    private var mergedSuggestions: some View {
        // We don't show "merge" results inline as multi-pin previews —
        // that's the category-pill flow. For free-typing we show:
        //   1. A "Search Nearby" pseudo-row that runs the typed query
        //      as a viewport-biased map search (Apple Maps parity).
        //   2. owned-row matches (with the "Saved in this city"
        //      caption so the user knows the data is already enriched),
        //   3. Provider suggestions (Apple MapKit OR Google Places
        //      Autocomplete depending on `provider`).
        //
        // Selecting any row resolves to a single `MapSearchPreview`
        // and dismisses to the map.
        List {
            if let outOfRegionWarning {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "mappin.slash")
                            .foregroundStyle(AppColors.appPrimary)
                        Text(outOfRegionWarning)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(AppColors.appPrimaryLight)
                    .accessibilityElement(children: .combine)
                }
            }

            Section {
                searchNearbyRow

                if !ownedRows.isEmpty {
                    ForEach(ownedRows) { preview in
                        ownedRowButton(preview)
                    }
                }

                switch provider {
                case .apple, .chinaFallback:
                    if !apple.suggestions.isEmpty {
                        ForEach(apple.suggestions) { suggestion in
                            appleRowButton(suggestion)
                        }
                    }
                case .google:
                    if !google.results.isEmpty {
                        ForEach(google.results) { prediction in
                            googleRowButton(prediction)
                        }
                    }
                }
            }

            if pendingResolve {
                Section {
                    HStack {
                        ProgressView()
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
            } else if shouldShowEmptyState {
                Section {
                    emptyStateRow
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, AppSpacing.xs, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .modifier(MapSearchEmbeddedScrollHorizontalBalanceModifier(isEmbedded: embedsInParentSheet))
        .scrollDismissesKeyboard(.interactively)
        .environment(\.defaultMinListRowHeight, 58)
    }

    /// True once we know we have nothing useful to show for the typed
    /// query — owned rows are empty AND the active provider returned
    /// no suggestions. Shown as a "No results in this area" hint so
    /// the user understands the search is region-scoped (we strip
    /// MapKit's silent global fallback in `AppleMapSearchService`).
    private var shouldShowEmptyState: Bool {
        guard ownedRows.isEmpty else { return false }
        switch provider {
        case .apple, .chinaFallback:
            return apple.suggestions.isEmpty
        case .google:
            return google.results.isEmpty
        }
    }

    /// Apple Maps-style top row: tap to run the typed query as a
    /// viewport-biased nearby search and surface results as map pins.
    private var searchNearbyRow: some View {
        Button {
            HapticManager.light()
            submitCurrentQueryToMap()
        } label: {
            HStack(spacing: AppSpacing.md) {
                rowLeadingIcon(
                    symbol: "magnifyingglass",
                    family: .generic
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Search nearby in this map area")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppColors.appPrimary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.lg, bottom: 8, trailing: AppSpacing.lg))
        .listRowBackground(AppColors.appSurface)
        .accessibilityLabel("Search nearby for \(query)")
        .accessibilityHint("Finds matching places in the visible map area")
    }

    @ViewBuilder
    private var emptyStateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No places found nearby", systemImage: "mappin.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Try a broader term or pan the map to a different area.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Coloured leading icon used by every row in the overlay. Mirrors
    /// Apple Maps' "tinted circle + glyph" treatment but uses our
    /// brand palette via `PlaceCategoryFamily` so the search surface
    /// feels native to the app.
    private func rowLeadingIcon(symbol: String, family: PlaceCategoryFamily) -> some View {
        ZStack {
            Circle()
                .fill(family == .generic ? Color(uiColor: .systemGray5) : family.tint)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(family == .generic ? .secondary : family.color)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func googleRowButton(_ prediction: PlaceAutocompleteResult) -> some View {
        let icon = SearchRowIconHeuristic.icon(forTitle: prediction.mainText)
        return Button {
            resolveGoogleAndCommit(prediction)
        } label: {
            HStack(spacing: AppSpacing.md) {
                rowLeadingIcon(symbol: icon.symbol, family: icon.family)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prediction.mainText)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !prediction.secondaryText.isEmpty {
                        Text(prediction.secondaryText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: AppSpacing.lg, bottom: 4, trailing: AppSpacing.lg))
        .listRowBackground(AppColors.appSurface)
    }

    private func ownedRowButton(_ preview: MapSearchPreview) -> some View {
        // city_places rows already carry a category, so prefer that
        // over a heuristic. Falls back to the title heuristic if a row
        // somehow lacks one.
        let icon: (symbol: String, family: PlaceCategoryFamily) = {
            if let cat = preview.category {
                return (cat.mapBadgeSymbol, cat.family)
            }
            return SearchRowIconHeuristic.icon(forTitle: preview.name)
        }()
        return Button {
            commit(preview)
        } label: {
            HStack(spacing: AppSpacing.md) {
                rowLeadingIcon(symbol: icon.symbol, family: icon.family)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !preview.subtitle.isEmpty {
                        Text(preview.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Label("Wayfind suggestion", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.appPrimary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: AppSpacing.lg, bottom: 4, trailing: AppSpacing.lg))
        .listRowBackground(AppColors.appSurface)
        .accessibilityLabel("\(preview.name). Wayfind suggestion.")
    }

    private func appleRowButton(_ suggestion: AppleMapSuggestion) -> some View {
        // MKLocalSearchCompletion doesn't expose a POI category until
        // we resolve via MKLocalSearch (one network round-trip per
        // row), so we run a lightweight title heuristic to keep typing
        // suggestions visually distinct without paying that cost.
        let icon = SearchRowIconHeuristic.icon(forTitle: suggestion.title)
        return Button {
            resolveAndCommit(suggestion)
        } label: {
            HStack(spacing: AppSpacing.md) {
                rowLeadingIcon(symbol: icon.symbol, family: icon.family)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: AppSpacing.lg, bottom: 4, trailing: AppSpacing.lg))
        .listRowBackground(AppColors.appSurface)
    }

    // MARK: - Actions

    private func dismissEmbeddedOrPresented() {
        if embedsInParentSheet {
            onCollapseEmbedded?()
        } else if suppressesEnvironmentDismiss {
            return
        } else {
            dismiss()
        }
    }

    private func commit(_ preview: MapSearchPreview) {
        rememberRecent(query)
        HapticManager.light()
        onPickResult(preview)
        dismissEmbeddedOrPresented()
    }

    private func commitSuggestedBrowserPick(_ preview: MapSearchPreview) {
        rememberRecent(query)
        HapticManager.light()
        onPickSuggestedBrowserResult(preview)
        dismissEmbeddedOrPresented()
    }

    private func commitInlineSuggestedPick(_ preview: MapSearchPreview) {
        rememberRecent(query)
        HapticManager.light()
        onPickSuggestedResult(preview)
        dismissEmbeddedOrPresented()
    }

    private func resolveAndCommit(_ suggestion: AppleMapSuggestion) {
        pendingResolve = true
        outOfRegionWarning = nil
        Task {
            let preview = await apple.resolveDetail(suggestion: suggestion, in: region)
            await MainActor.run {
                pendingResolve = false
                if let preview {
                    commit(preview)
                } else {
                    // Either MapKit found nothing or the resolved
                    // coordinate landed outside our bias region. We
                    // can't tell which without re-running, so the
                    // wording covers both — practically the latter is
                    // by far the common case for short queries that
                    // hit Apple's silent global fallback.
                    outOfRegionWarning = "“\(suggestion.title)” isn't near this trip area. Pan the map to that area to add it."
                }
            }
        }
    }

    /// China fallback: the prediction came from Google Autocomplete.
    /// We pay for one Place Details call per *selection* (never per
    /// pin render) to materialise coordinates + name and produce a
    /// `MapSearchPreview` tagged `.googleFallback`.
    private func resolveGoogleAndCommit(_ prediction: PlaceAutocompleteResult) {
        pendingResolve = true
        Task {
            let detail = await google._getPlaceDetailsForChinaFallback(placeId: prediction.id)
            await MainActor.run {
                pendingResolve = false
                guard let detail else { return }
                let preview = MapSearchPreview(
                    id: "google|\(detail.placeId)",
                    origin: .googleFallback,
                    name: detail.name,
                    subtitle: detail.address,
                    coordinate: CLLocationCoordinate2D(latitude: detail.lat, longitude: detail.lng),
                    googlePlaceId: detail.placeId,
                    phone: nil,
                    website: nil,
                    thumbnailURL: nil,
                    category: PlaceCategory.fromGoogleTypes(detail.types)
                )
                commit(preview)
            }
        }
    }

    private func runCategorySearch(_ pill: CategoryPill) {
        // Dismiss the overlay *before* the network call so the user
        // sees results land on the map. The map screen owns the merge
        // and will populate its `searchResults` on completion.
        let q = pill.id
        query = pill.label
        rememberRecent(pill.label)
        let category = pill.matchingPlaceCategory

        Task {
            async let appleResults = apple.searchNearbyPreviews(
                query: q,
                in: region,
                resultLimit: 18
            )
            async let dbResults = CityPlacesSearchService.shared.search(
                cityProfileId: cityProfileId,
                query: nil,
                category: category,
                region: region,
                excluding: excludedPlaceIds,
                limit: 18
            )

            let (a, d) = await (appleResults, dbResults)
            let merged = MapSearchResultMerger.merge(apple: a, db: d, limit: 24)

            await MainActor.run {
                onPickCategory(pill, merged)
                dismissEmbeddedOrPresented()
            }
        }
    }

    private func submitCurrentQueryToMap() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        pendingResolve = true
        rememberRecent(trimmed)

        Task {
            async let appleResults = apple.searchNearbyPreviews(
                query: trimmed,
                in: region,
                resultLimit: 18
            )
            async let dbResults = CityPlacesSearchService.shared.search(
                cityProfileId: cityProfileId,
                query: trimmed,
                category: nil,
                region: region,
                excluding: excludedPlaceIds,
                limit: 18
            )

            let (a, d) = await (appleResults, dbResults)
            let merged = MapSearchResultMerger.merge(apple: a, db: d, limit: 24)

            await MainActor.run {
                pendingResolve = false
                HapticManager.light()
                onSubmitSearch(trimmed, merged)
                dismissEmbeddedOrPresented()
            }
        }
    }

    private func refreshSuggestions(for rawQuery: String) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apple.clear()
            google.clearResults()
        } else {
            switch provider {
            case .apple, .chinaFallback:
                apple.update(query: rawQuery, region: region)
            case .google:
                google.search(query: rawQuery, types: "establishment")
            }
        }
        kickOwnedRows(query: rawQuery)
    }

    /// Load curated `city_places` rows for the trip's city to populate
    /// the empty-state Suggested Places carousel. Re-runs only when the
    /// city changes (driven by `.task(id: cityProfileId)`).
    private func loadSuggestedIfNeeded() async {
        guard let cityProfileId else {
            suggestedPlaces = []
            suggestedLoadedFor = nil
            return
        }
        // Already loaded for this city — leave the carousel intact.
        if suggestedLoadedFor == suggestedPlacesTaskKey, !suggestedPlaces.isEmpty {
            return
        }
        loadingSuggested = true
        defer { loadingSuggested = false }
        let rows = await CityPlacesSearchService.shared.topPicks(
            cityProfileId: cityProfileId,
            category: nil,
            excluding: excludedPlaceIds,
            limit: 30
        )
        suggestedPlaces = rows
        suggestedLoadedFor = suggestedPlacesTaskKey
    }

    private func kickOwnedRows(query q: String) {
        ownedRowsTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            ownedRows = []
            return
        }
        ownedRowsTask = Task { [region, excludedPlaceIds, cityProfileId] in
            // tiny debounce so we don't fire on every keystroke
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let rows = await CityPlacesSearchService.shared.search(
                cityProfileId: cityProfileId,
                query: trimmed,
                category: nil,
                region: region,
                excluding: excludedPlaceIds,
                limit: 8
            )
            await MainActor.run {
                guard !Task.isCancelled else { return }
                ownedRows = rows
            }
        }
    }

    // MARK: - Search history persistence

    private func rememberRecent(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = decodeRecents()
        items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        items.insert(trimmed, at: 0)
        if items.count > recentsCap { items.removeLast(items.count - recentsCap) }
        recentsRaw = items.joined(separator: "|")
    }

    private func decodeRecents() -> [String] {
        recentsRaw
            .split(separator: "|", omittingEmptySubsequences: true)
            .map(String.init)
    }

}

/// Embedded places-sheet search: adds symmetric horizontal scroll insets so inset-grouped results
/// don’t read flush against the sheet edge (negative margins were pulling content toward the bezel).
private struct MapSearchEmbeddedScrollHorizontalBalanceModifier: ViewModifier {
    var isEmbedded: Bool

    func body(content: Content) -> some View {
        if isEmbedded {
            content
                .contentMargins(.horizontal, Self.horizontalGutter, for: .scrollContent)
        } else {
            content
        }
    }

    /// Matches the app’s standard readable margin (`AppSpacing.lg`) so focused search feels consistent with the pill row.
    private static let horizontalGutter: CGFloat = AppSpacing.lg
}

// MARK: - Category pills row

/// Apple Maps-style horizontal pill strip — neutral material capsule,
/// family-coloured glyph, primary text. Each pill gets its own hue from
/// the same `PlaceCategoryFamily` palette used by the rest of the app
/// so a "Restaurants" pill matches a restaurant pin's tint.
private struct CategoryPillsRow: View {
    var onTap: (CategoryPill) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CategoryPill.all) { pill in
                    Button {
                        onTap(pill)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pill.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(pill.family.color)
                                .symbolRenderingMode(.hierarchical)
                            Text(pill.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 14)
                        .mapSearchCategoryGlassPill()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search \(pill.label.lowercased())")
                }
            }
            .padding(.horizontal, AppSpacing.lg)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private extension View {
    @ViewBuilder
    func mapSearchCategoryGlassPill() -> some View {
        self
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
    }
}

private extension CategoryPill {
    /// Map the pill (UI-facing) onto `PlaceCategory` for city_places
    /// `wayfind_category` filtering.
    var matchingPlaceCategory: PlaceCategory? {
        switch id {
        case "attractions", "museums": return .attraction
        case "restaurants", "cafes":   return .restaurant
        case "parks":                  return .nature
        case "shopping":               return .shopping
        case "nightlife":              return .nightlife
        default:                       return nil
        }
    }
}

// MARK: - Title-based icon heuristic for autocomplete rows
//
// `MKLocalSearchCompletion` and `PlaceAutocompleteResult` don't carry a
// POI category — getting one requires a per-row resolve call we don't
// want to pay during typing. Instead, we keyword-match the title
// against well-known brands and generic POI words to surface a coloured
// glyph that matches Apple Maps' visual treatment without the
// per-keystroke cost.
//
// Order matters: brand-specific entries beat generic words. Add new
// well-known global brands as they come up in user reports.

enum SearchRowIconHeuristic {
    typealias Match = (symbol: String, family: PlaceCategoryFamily)

    static func icon(forTitle rawTitle: String) -> Match {
        let title = rawTitle.lowercased()
        for entry in entries where entry.matches.contains(where: { title.contains($0) }) {
            return (entry.symbol, entry.family)
        }
        // Generic point-of-interest fallback. The neutral grey circle
        // (rendered by `rowLeadingIcon` when family is `.generic`) is
        // intentional — it tells the user "we can't tell what kind of
        // place this is yet" without forcing a wrong colour.
        return ("mappin", .generic)
    }

    private struct Entry {
        let matches: [String]
        let symbol: String
        let family: PlaceCategoryFamily
    }

    private static let entries: [Entry] = [
        // Cafes & coffee — biggest source of "Apple Maps shows a cup" in
        // real screenshots, so kept first.
        Entry(matches: ["starbucks", "costa coffee", "tim hortons",
                        "dunkin", "blue bottle", "peet's", "café",
                        "cafe", "coffee", "espresso", "kopi"],
              symbol: "cup.and.saucer.fill", family: .food),
        // Bakeries / desserts
        Entry(matches: ["bakery", "patisserie", "boulangerie",
                        "ice cream", "gelato", "dessert"],
              symbol: "birthday.cake.fill", family: .food),
        // Fast food + restaurants — keep after cafes so "café restaurant"
        // still picks the cafe entry.
        Entry(matches: ["mcdonald", "burger king", "kfc", "chipotle",
                        "subway", "domino", "pizza hut", "taco bell",
                        "wendy"],
              symbol: "fork.knife.circle.fill", family: .food),
        Entry(matches: ["restaurant", "warung", "trattoria", "bistro",
                        "ristorante", "diner", "kitchen", "grill",
                        "noodle", "ramen", "sushi", "steakhouse"],
              symbol: "fork.knife", family: .food),
        // Bars / nightlife
        Entry(matches: ["bar", "pub", "lounge", "cocktail", "brewery",
                        "winery", "wine", "club"],
              symbol: "wineglass.fill", family: .food),
        // Lodging
        Entry(matches: ["hotel", "resort", "hostel", "inn", "motel",
                        "guesthouse", "guest house", "villa", "lodge",
                        "bnb", "b&b"],
              symbol: "bed.double.fill", family: .stay),
        // Transport
        Entry(matches: ["airport", "international airport"],
              symbol: "airplane", family: .transport),
        Entry(matches: ["train station", "railway", "metro", "subway",
                        "tram", "bts", "mrt"],
              symbol: "tram.fill", family: .transport),
        Entry(matches: ["bus station", "bus stop", "bus terminal"],
              symbol: "bus.fill", family: .transport),
        Entry(matches: ["ferry", "harbour", "harbor", "port"],
              symbol: "ferry.fill", family: .transport),
        Entry(matches: ["taxi", "uber", "grab"],
              symbol: "car.fill", family: .transport),
        Entry(matches: ["parking", "garage"],
              symbol: "parkingsign", family: .transport),
        // Shopping
        Entry(matches: ["mall", "department store", "shopping center",
                        "shopping centre"],
              symbol: "bag.fill", family: .shopping),
        Entry(matches: ["market", "supermarket", "grocery"],
              symbol: "storefront.fill", family: .shopping),
        Entry(matches: ["bookstore", "book store", "library"],
              symbol: "books.vertical.fill", family: .culture),
        Entry(matches: ["store", "shop", "boutique"],
              symbol: "storefront.fill", family: .shopping),
        // Nature / outdoor
        Entry(matches: ["national park", "state park"],
              symbol: "mountain.2.fill", family: .nature),
        Entry(matches: ["park", "garden", "botanical"],
              symbol: "tree.fill", family: .nature),
        Entry(matches: ["beach", "pantai"],
              symbol: "sun.horizon.fill", family: .nature),
        Entry(matches: ["zoo", "wildlife"],
              symbol: "pawprint.fill", family: .nature),
        Entry(matches: ["aquarium"],
              symbol: "water.waves", family: .nature),
        Entry(matches: ["hiking", "trail", "campground"],
              symbol: "figure.hiking", family: .nature),
        // Culture / sights
        Entry(matches: ["museum", "gallery"],
              symbol: "building.columns.fill", family: .culture),
        Entry(matches: ["temple", "church", "mosque", "synagogue",
                        "shrine", "cathedral", "monastery", "pura"],
              symbol: "building.columns.fill", family: .culture),
        Entry(matches: ["theater", "theatre", "opera", "cinema",
                        "movie"],
              symbol: "theatermasks.fill", family: .culture),
        Entry(matches: ["stadium", "arena"],
              symbol: "sportscourt.fill", family: .culture),
        Entry(matches: ["castle", "palace", "fort"],
              symbol: "building.2.fill", family: .culture),
        Entry(matches: ["spa", "massage", "wellness"],
              symbol: "sparkles", family: .culture),
        Entry(matches: ["university", "college", "school"],
              symbol: "graduationcap.fill", family: .culture),
        Entry(matches: ["plaza", "square"],
              symbol: "mappin.circle.fill", family: .generic),
    ]
}

// =============================================================================

#if DEBUG
#Preview("Search overlay — empty state") {
    MapSearchOverlay(
        country: "FR",
        initialQuery: "",
        cityProfileId: nil,
        region: .init(
            center: .init(latitude: 48.8566, longitude: 2.3522),
            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ),
        excludedPlaceIds: [],
        onPickResult: { _ in },
        onPickSuggestedResult: { _ in },
        onPickSuggestedBrowserResult: { _ in },
        onPickCategory: { _, _ in },
        onSubmitSearch: { _, _ in },
        onCancel: {}
    )
}

#Preview("Search overlay — prefilled query") {
    MapSearchOverlay(
        country: "FR",
        initialQuery: "Eiffel",
        cityProfileId: nil,
        region: .init(
            center: .init(latitude: 48.8566, longitude: 2.3522),
            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ),
        excludedPlaceIds: [],
        onPickResult: { _ in },
        onPickSuggestedResult: { _ in },
        onPickSuggestedBrowserResult: { _ in },
        onPickCategory: { _, _ in },
        onSubmitSearch: { _, _ in },
        onCancel: {}
    )
}

/// Sheet presentation chrome for Canvas previews (legacy map uses a full-screen overlay instead).
#Preview("Search overlay — in sheet (Canvas)") {
    @Previewable @State var showSheet = true
    Color.clear
        .sheet(isPresented: $showSheet) {
            MapSearchOverlay(
                country: "FR",
                initialQuery: "",
                cityProfileId: nil,
                region: .init(
                    center: .init(latitude: 48.8566, longitude: 2.3522),
                    span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ),
                excludedPlaceIds: [],
                onPickResult: { _ in },
                onPickSuggestedResult: { _ in },
                onPickSuggestedBrowserResult: { _ in },
                onPickCategory: { _, _ in },
                onSubmitSearch: { _, _ in },
                onCancel: {}
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(.regularMaterial)
        }
}
#endif
