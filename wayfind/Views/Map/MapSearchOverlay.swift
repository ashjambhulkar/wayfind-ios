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

    /// Called when the user picks a single result (autocomplete or
    /// recent). Hands the resolved preview back so the map can drop a
    /// pin and open the preview sheet.
    var onPickResult: (MapSearchPreview) -> Void

    /// Called when the user picks from the dedicated Suggested Places
    /// browser. The map can use this to restore that browser after the
    /// preview sheet is dismissed.
    var onPickSuggestedResult: (MapSearchPreview) -> Void

    /// Called when the user taps a category pill. Hands a list of
    /// blended Apple+DB previews back so the map can render
    /// SearchResultAnnotations.
    var onPickCategory: (CategoryPill, [MapSearchPreview]) -> Void

    /// Keyboard Search submit. Dismisses this full-screen search surface and
    /// hands all blended results back to the map, Apple Maps-style.
    var onSubmitSearch: (_ query: String, _ results: [MapSearchPreview]) -> Void

    /// Dismiss without picking.
    var onCancel: () -> Void

    // MARK: - Local state

    @State private var query: String
    @State private var apple = AppleMapSearchService()
    @State private var google = PlaceSearchService()
    @State private var ownedRows: [MapSearchPreview] = []
    @State private var ownedRowsTask: Task<Void, Never>?
    @State private var pendingResolve = false
    @FocusState private var isQueryFocused: Bool
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

    private var provider: FeatureFlagsService.MapSearchProvider {
        FeatureFlagsService.shared.mapSearchProvider(forCountry: country)
    }

    private let recentsCap = 6

    private var suggestedPlacesTaskKey: String {
        "\(cityProfileId?.uuidString ?? "_")|\(excludedPlaceIds.sorted().joined(separator: ","))"
    }

    private let searchChromeHeight: CGFloat = 126

    init(
        country: String?,
        initialQuery: String = "",
        cityProfileId: UUID?,
        region: MKCoordinateRegion,
        excludedPlaceIds: Set<String>,
        onPickResult: @escaping (MapSearchPreview) -> Void,
        onPickSuggestedResult: @escaping (MapSearchPreview) -> Void,
        onPickCategory: @escaping (CategoryPill, [MapSearchPreview]) -> Void,
        onSubmitSearch: @escaping (_ query: String, _ results: [MapSearchPreview]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.country = country
        self.initialQuery = initialQuery
        self.cityProfileId = cityProfileId
        self.region = region
        self.excludedPlaceIds = excludedPlaceIds
        self.onPickResult = onPickResult
        self.onPickSuggestedResult = onPickSuggestedResult
        self.onPickCategory = onPickCategory
        self.onSubmitSearch = onSubmitSearch
        self.onCancel = onCancel
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                resultsList

                searchChrome
            }
            .background(AppColors.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("")
        }
        .onAppear {
            isQueryFocused = true
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                refreshSuggestions(for: query)
            }
        }
        .task {
            isQueryFocused = true
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
        }
        .tint(AppColors.appPrimary)
    }

    private var searchChrome: some View {
        VStack(spacing: AppSpacing.sm) {
            searchHeader

            CategoryPillsRow { pill in
                HapticManager.selection()
                runCategorySearch(pill)
            }
            .padding(.bottom, AppSpacing.sm)
        }
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.regularMaterial)
                    .frame(height: searchChromeHeight - 22)

                LinearGradient(
                    colors: [
                        AppColors.appBackground.opacity(0.94),
                        AppColors.appBackground.opacity(0.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 22)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search places", text: $query)
                    .font(.body)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isQueryFocused)
                    .onSubmit(submitCurrentQueryToMap)

                if !query.isEmpty {
                    Button {
                        query = ""
                        isQueryFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(height: 46)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsList: some View {
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
                } else if cityProfileId == nil {
                    Text("Suggestions appear here once your destination loads.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if suggestedPlaces.isEmpty {
                    Text("No curated places yet for this city.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestedPlaces.prefix(4)) { preview in
                        suggestedPlaceRow(preview)
                    }
                }
            } header: {
                sectionHeader(
                    "Suggested Places",
                    trailing: suggestedPlaces.count > 4 ? "See all" : nil,
                    trailingAction: { showAllSuggested = true }
                )
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
        .scrollContentBackground(.hidden)
        .contentMargins(.top, searchChromeHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Section header that mimics Apple Maps' "Title chevron" pattern —
    /// a bold large-title with an optional trailing tappable label (e.g.
    /// "See all"). `.textCase(nil)` defeats the inset-grouped list's
    /// default uppercase/secondary treatment so the header reads like a
    /// real heading rather than a tiny caption.
    @ViewBuilder
    private func sectionHeader(
        _ title: String,
        trailing: String? = nil,
        trailingAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer(minLength: 0)
            if let trailing, let trailingAction {
                Button {
                    HapticManager.selection()
                    trailingAction()
                } label: {
                    HStack(spacing: 2) {
                        Text(trailing)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppColors.appPrimary)
                    .textCase(nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(trailing) \(title.lowercased())")
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Suggested-place row used in the empty state. Mirrors the Apple
    /// Maps card row — square thumbnail, title, category caption.
    @ViewBuilder
    private func suggestedPlaceRow(_ preview: MapSearchPreview) -> some View {
        Button {
            commit(preview)
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
            }

            if !ownedRows.isEmpty {
                Section {
                    ForEach(ownedRows) { preview in
                        ownedRowButton(preview)
                    }
                } header: {
                    Text("From this city's places")
                }
            }

            switch provider {
            case .apple, .chinaFallback:
                if !apple.suggestions.isEmpty {
                    Section {
                        ForEach(apple.suggestions) { suggestion in
                            appleRowButton(suggestion)
                        }
                    } header: {
                        Text("Suggestions")
                    }
                }
            case .google:
                if !google.results.isEmpty {
                    Section {
                        ForEach(google.results) { prediction in
                            googleRowButton(prediction)
                        }
                    } header: {
                        Text("Suggestions")
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
        .scrollContentBackground(.hidden)
        .contentMargins(.top, searchChromeHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
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
            HStack(spacing: 12) {
                rowLeadingIcon(
                    symbol: "magnifyingglass",
                    family: .generic
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Search Nearby")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
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
                .fill(family == .generic ? Color(uiColor: .systemGray4) : family.color)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private func googleRowButton(_ prediction: PlaceAutocompleteResult) -> some View {
        let icon = SearchRowIconHeuristic.icon(forTitle: prediction.mainText)
        return Button {
            resolveGoogleAndCommit(prediction)
        } label: {
            HStack(spacing: 12) {
                rowLeadingIcon(symbol: icon.symbol, family: icon.family)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prediction.mainText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !prediction.secondaryText.isEmpty {
                        Text(prediction.secondaryText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    rowLeadingIcon(symbol: icon.symbol, family: icon.family)
                    VStack(alignment: .leading, spacing: 2) {
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
                        Text("Saved in this city")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppColors.appPrimary)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityLabel("\(preview.name). Saved in this city.")
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
            HStack(spacing: 12) {
                rowLeadingIcon(symbol: icon.symbol, family: icon.family)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func commit(_ preview: MapSearchPreview) {
        rememberRecent(query)
        HapticManager.light()
        onPickResult(preview)
        dismiss()
    }

    private func commitSuggestedBrowserPick(_ preview: MapSearchPreview) {
        rememberRecent(query)
        HapticManager.light()
        onPickSuggestedResult(preview)
        dismiss()
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
                dismiss()
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
                dismiss()
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
            .padding(.vertical, 2) // breathing room for the shadow
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private extension View {
    @ViewBuilder
    func mapSearchCategoryGlassPill() -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .background(.thinMaterial, in: Capsule())
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

private enum SearchRowIconHeuristic {
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
