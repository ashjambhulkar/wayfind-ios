//
//  SuggestedPlacesAllSheet.swift
//  wayfind
//
//  Companion to MapSearchOverlay.swift — when the user taps "See all"
//  next to "Suggested Places", we hand the full curated city_places
//  list off to this dedicated sheet so the search overlay stays focused
//  on typing/recents.
//
//  Locked invariants:
//    • Read-only. All work is delegated to `CityPlacesSearchService`,
//      which is bbox-free in `topPicks` mode (the user is browsing a
//      destination, not their current viewport).
//    • Tapping a row yields a `MapSearchPreview` that the parent
//      overlay commits via the same code path as any other search
//      result — drops a pin and opens the preview sheet on the map.
//    • Category filter capsules stay client-side: we re-fetch with the
//      `topPicks(category:)` overload rather than filtering in-memory
//      so the cap stays meaningful per category.
//

import MapKit
import SwiftUI

struct SuggestedPlacesAllSheet: View {
    let cityProfileId: UUID?
    let excludedPlaceIds: Set<String>

    /// Caller commits the pick (drops pin, opens preview on map). The
    /// sheet itself doesn't dismiss — the parent decides whether to
    /// also tear down the underlying search overlay.
    var onPick: (MapSearchPreview) -> Void

    /// Plain dismiss — user tapped close without choosing anything.
    var onCancel: () -> Void

    @State private var rows: [MapSearchPreview] = []
    @State private var loading = false
    @State private var selectedFilter: PlaceCategory? = nil
    @State private var loadTask: Task<Void, Never>?

    private static let filterOverlayScrollTopMargin: CGFloat = 56

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                content

                filterStrip
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.xs)
            }
            .background {
                AppColors.appBackground.ignoresSafeArea()
            }
            .navigationTitle("Suggested Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.appBody.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .accessibilityLabel("Close suggested places")
                }
            }
        }
        .task(id: filterTaskKey) {
            await loadPicks()
        }
        .tint(AppColors.appPrimary)
    }

    /// `.task(id:)` only re-runs when this string changes. Combining
    /// the city + category here keeps the loader from racing when the
    /// user toggles filters.
    private var filterTaskKey: String {
        let excludedKey = excludedPlaceIds.sorted().joined(separator: ",")
        return "\(cityProfileId?.uuidString ?? "_")|\(selectedFilter?.rawValue ?? "all")|\(excludedKey)"
    }

    // MARK: - Filter strip

    /// Compact horizontal filter row mirroring the empty-state capsules
    /// strip on the search overlay — app surface capsule, family
    /// glyph, primary text. We only expose the categories that
    /// `city_places.wayfind_category` actually distinguishes.
    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                filterCapsule(
                    label: "All",
                    symbol: "square.grid.2x2.fill",
                    family: .generic,
                    isSelected: selectedFilter == nil
                ) {
                    selectedFilter = nil
                }
                ForEach(filterCategories, id: \.self) { cat in
                    filterCapsule(
                        label: cat.label,
                        symbol: cat.mapBadgeSymbol,
                        family: cat.family,
                        isSelected: selectedFilter == cat
                    ) {
                        selectedFilter = (selectedFilter == cat) ? nil : cat
                    }
                }
            }
        }
    }

    private var filterCategories: [PlaceCategory] {
        // Mirrors what city_places.wayfind_category understands. Hotel
        // and transport collapse to `custom` server-side so we omit
        // them from the capsules to avoid empty result sets.
        [.attraction, .restaurant, .nature, .shopping, .nightlife]
    }

    private func filterCapsule(
        label: String,
        symbol: String,
        family: PlaceCategoryFamily,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticManager.selection()
            action()
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: symbol)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(family.color)
                    .symbolRenderingMode(.hierarchical)
                Text(label)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, AppSpacing.sm)
            .padding(.horizontal, AppSpacing.md)
            .background(isSelected ? AppColors.appPrimaryLight : AppColors.appSurface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isSelected ? AppColors.appPrimary : AppColors.appDivider, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Content list

    @ViewBuilder
    private var content: some View {
        if loading && rows.isEmpty {
            VStack(spacing: AppSpacing.md) {
                Spacer()
                ProgressView()
                Text("Loading suggestions…")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            EmptyStateView(
                sfSymbol: "mappin.slash",
                title: "No suggestions",
                subtitle: selectedFilter == nil
                    ? "We don't have curated places for this city yet."
                    : "No \(selectedFilter?.label.lowercased() ?? "places") in our list yet — try another filter."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(rows) { preview in
                        Button {
                            HapticManager.light()
                            onPick(preview)
                        } label: {
                            SuggestedPlaceListRow(preview: preview)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
                        .listRowBackground(AppColors.appSurface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, Self.filterOverlayScrollTopMargin, for: .scrollContent)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - Loader

    private func loadPicks() async {
        guard cityProfileId != nil else {
            rows = []
            return
        }
        loading = true
        defer { loading = false }
        let picks = await CityPlacesSearchService.shared.topPicks(
            cityProfileId: cityProfileId,
            category: selectedFilter,
            excluding: excludedPlaceIds,
            limit: 60
        )
        rows = picks
    }
}

// MARK: - Row layouts

/// Two-line list row used inside the "See all" sheet — shares a
/// thumbnail style with the empty-state carousel so the visual
/// vocabulary stays consistent across both surfaces.
struct SuggestedPlaceListRow: View {
    let preview: MapSearchPreview

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            SuggestedThumbnail(preview: preview, size: 56)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(preview.name)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                if let cat = preview.category {
                    Text(cat.label)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                if !preview.subtitle.isEmpty {
                    Text(preview.subtitle)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

/// Square thumbnail tile shared by Suggested Places rows. When the
/// city_places row carries a `thumbnail_url` we render the photo;
/// otherwise we fall back to a tinted family-coloured glyph so the
/// row never collapses to a blank square.
struct SuggestedThumbnail: View {
    let preview: MapSearchPreview
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.iconBadgeGradient(accent: badgeAccent))

            if let url = preview.thumbnailURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .tint(family.color)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        glyph
                    @unknown default:
                        glyph
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            } else {
                glyph
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var family: PlaceCategoryFamily {
        preview.category?.family ?? .generic
    }

    private var badgeAccent: Color {
        family == .generic ? AppColors.appError : family.color
    }

    private var symbol: String {
        preview.category?.mapBadgeSymbol ?? "mappin"
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.sectionHeader.weight(.semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(AppColors.iconOnColoredSurface)
    }
}

// =============================================================================

#if DEBUG
#Preview("Suggested places — no city resolved") {
    SuggestedPlacesAllSheet(
        cityProfileId: nil,
        excludedPlaceIds: [],
        onPick: { _ in },
        onCancel: {}
    )
}

#Preview("Suggested places — city resolved (live fetch)") {
    SuggestedPlacesAllSheet(
        cityProfileId: UUID(),
        excludedPlaceIds: [],
        onPick: { _ in },
        onCancel: {}
    )
}

#Preview("Suggested place list row") {
    let preview = MapSearchPreview(
        id: "row-preview",
        origin: .cityPlaces,
        name: "Musée d'Orsay",
        subtitle: "1 Rue de la Légion d'Honneur, 75007 Paris",
        coordinate: .init(latitude: 48.8600, longitude: 2.3266),
        googlePlaceId: nil,
        phone: nil,
        website: nil,
        thumbnailURL: nil,
        category: .attraction
    )
    List {
        SuggestedPlaceListRow(preview: preview)
    }
    .listStyle(.plain)
}

#Preview("Suggested thumbnail — no image") {
    let preview = MapSearchPreview(
        id: "thumb-preview",
        origin: .cityPlaces,
        name: "Sacré-Cœur",
        subtitle: "Montmartre, Paris",
        coordinate: .init(latitude: 48.8867, longitude: 2.3431),
        googlePlaceId: nil,
        phone: nil,
        website: nil,
        thumbnailURL: nil,
        category: .attraction
    )
    HStack(spacing: AppSpacing.md) {
        SuggestedThumbnail(preview: preview, size: 52)
        SuggestedThumbnail(preview: preview, size: 72)
    }
    .padding()
}
#endif
