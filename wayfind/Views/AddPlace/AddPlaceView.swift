import SwiftUI

struct AddPlaceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedDayNumber: Int

    let days: [ItineraryDay]
    let wishlistPlaces: [Place]
    var onAddPlace: (String, Int) -> Void

    init(
        selectedDayNumber: Int,
        days: [ItineraryDay],
        wishlistPlaces: [Place],
        onAddPlace: @escaping (String, Int) -> Void
    ) {
        _selectedDayNumber = State(initialValue: selectedDayNumber)
        self.days = days
        self.wishlistPlaces = wishlistPlaces
        self.onAddPlace = onAddPlace
    }

    private func dayLabel(for dayNumber: Int) -> String {
        guard let day = days.first(where: { $0.dayNumber == dayNumber }),
              let date = day.date else {
            return "Day \(dayNumber)"
        }
        return "Day \(dayNumber) — \(date.shortFormatted)"
    }

    private var filteredWishlist: [Place] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return wishlistPlaces.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.address ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var searchResultTuples: [(name: String, address: String, category: String)] {
        if !filteredWishlist.isEmpty {
            return filteredWishlist.map { place in
                (
                    name: place.name,
                    address: place.address ?? "",
                    category: place.category ?? PlaceCategory.custom.rawValue
                )
            }
        }
        return MockPlaceSearchSamples.results(matching: searchText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                HStack {
                    Text("Add to \(dayLabel(for: selectedDayNumber))")
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer(minLength: 0)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }

                if !days.isEmpty {
                    Picker("Day", selection: $selectedDayNumber) {
                        ForEach(days.filter { !$0.isWishlist }) { day in
                            Text(dayLabel(for: day.dayNumber))
                                .tag(day.dayNumber)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppColors.appPrimary)
                }

                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppColors.textSecondary)
                    TextField("Search places", text: $searchText)
                        .font(.appBody)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 48)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

                if searchText.isEmpty {
                    if wishlistPlaces.isEmpty {
                        Text("Search for a place to add")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.xxl)
                    } else {
                        sectionHeader("Your Ideas")
                        WishlistSectionView(places: wishlistPlaces) { place in
                            onAddPlace(place.name, selectedDayNumber)
                        }
                    }
                } else {
                    sectionHeader("Search Results")
                    PlaceSearchResultsView(results: searchResultTuples) { name, _, _ in
                        onAddPlace(name, selectedDayNumber)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppColors.appBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appSmall)
            .foregroundStyle(AppColors.textTertiary)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

private enum MockPlaceSearchSamples {
    static func results(matching query: String) -> [(name: String, address: String, category: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let all: [(name: String, address: String, category: String)] = [
            ("Golden Gate Park", "501 Stanyan St, San Francisco", PlaceCategory.nature.rawValue),
            ("Ferry Building Marketplace", "1 Ferry Building, San Francisco", PlaceCategory.shopping.rawValue),
            ("Coit Tower", "1 Telegraph Hill Blvd, San Francisco", PlaceCategory.attraction.rawValue),
            ("Mission Dolores Park", "Dolores St & 18th St, San Francisco", PlaceCategory.nature.rawValue),
            ("Palace of Fine Arts", "3601 Lyon St, San Francisco", PlaceCategory.attraction.rawValue)
        ]

        return all.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.address.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
        }
    }
}