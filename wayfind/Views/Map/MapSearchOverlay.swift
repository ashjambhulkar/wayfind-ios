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

    @State private var query: String = ""
    @State private var apple = AppleMapSearchService()
    @State private var google = PlaceSearchService()
    @State private var ownedRows: [MapSearchPreview] = []
    @State private var ownedRowsTask: Task<Void, Never>?
    @State private var pendingResolve = false
    @State private var isSearchPresented = true

    @AppStorage("mapSearchRecents") private var recentsRaw: String = ""
    @Environment(\.dismiss) private var dismiss

    private var provider: FeatureFlagsService.MapSearchProvider {
        FeatureFlagsService.shared.mapSearchProvider(forCountry: country)
    }

    private let recentsCap = 6

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                resultsList

                CategoryPillsRow { pill in
                    HapticManager.selection()
                    runCategorySearch(pill)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .background(AppColors.appBackground)
            .searchable(
                text: $query,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search places"
            )
            .onSubmit(of: .search) {
                submitCurrentQueryToMap()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("")
            .toolbarBackground(.regularMaterial, for: .navigationBar)
        }
        .onAppear { isSearchPresented = true }
        .onChange(of: query) { _, q in
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                apple.clear()
                google.clearResults()
            } else {
                switch provider {
                case .apple, .chinaFallback:
                    apple.update(query: q, region: region)
                case .google:
                    google.search(query: q, types: "establishment")
                }
            }
            kickOwnedRows(query: q)
        }
        .onDisappear {
            apple.clear()
            google.clearResults()
            ownedRowsTask?.cancel()
        }
        .tint(AppColors.appPrimary)
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
        List {
            let recents = decodeRecents()
            if !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.self) { recent in
                        Button {
                            query = recent
                            HapticManager.selection()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(recent).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                    .onDelete(perform: deleteRecent)
                } header: {
                    Text("Recent searches")
                }
            } else {
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
    }

    private var mergedSuggestions: some View {
        // We don't show "merge" results inline as multi-pin previews —
        // that's the category-pill flow. For free-typing we show:
        //   1. owned-row matches (top, with the "Saved in this city"
        //      caption so the user knows the data is already enriched),
        //   2. Provider suggestions (Apple MapKit OR Google Places
        //      Autocomplete depending on `provider`).
        //
        // Selecting any row resolves to a single `MapSearchPreview`
        // and dismisses to the map.
        List {
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
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func googleRowButton(_ prediction: PlaceAutocompleteResult) -> some View {
        Button {
            resolveGoogleAndCommit(prediction)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
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
        Button {
            commit(preview)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: preview.category?.mapBadgeSymbol ?? "mappin.circle.fill")
                        .foregroundStyle(AppColors.appPrimary)
                        .frame(width: 22)
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
        Button {
            resolveAndCommit(suggestion)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
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

    private func resolveAndCommit(_ suggestion: AppleMapSuggestion) {
        pendingResolve = true
        Task {
            let preview = await apple.resolveDetail(suggestion: suggestion, in: region)
            await MainActor.run {
                pendingResolve = false
                if let preview {
                    commit(preview)
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

    // MARK: - Recents

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

    private func deleteRecent(at offsets: IndexSet) {
        var items = decodeRecents()
        items.remove(atOffsets: offsets)
        recentsRaw = items.joined(separator: "|")
    }
}

// MARK: - Category pills row

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
                                .font(.system(size: 13, weight: .semibold))
                            Text(pill.label)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .foregroundStyle(AppColors.appPrimary)
                        .background(
                            Capsule()
                                .fill(AppColors.appPrimaryLight)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(AppColors.appPrimary.opacity(0.18), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search \(pill.label.lowercased())")
                }
            }
            .padding(.horizontal, 4)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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

// =============================================================================
