import SwiftUI
import UIKit

// MARK: - Docked Accessory Bar (sits above tab bar via tabViewBottomAccessory)

/// Compact day filter bar placed above the tab bar using `tabViewBottomAccessory`.
struct MapDockedAccessoryBar: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    let mappablePlaces: [Place]
    let dayNumberByDayId: [UUID: Int]
    var onExpand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        dockedDayTab(dayNum: 0, label: "All")
                        ForEach(1...max(trip.dayCount, 1), id: \.self) { dayNum in
                            dockedDayTab(dayNum: dayNum, label: "Day \(dayNum)")
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: selectedDayFilter) { _, newFilter in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        proxy.scrollTo(newFilter ?? 0, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(selectedDayFilter ?? 0, anchor: .center)
                }
            }

            // Expand button
            Button {
                HapticManager.light()
                onExpand()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 36, height: 36)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mappablePlaces.count) places on map. Tap list to expand.")
    }

    private func dockedDayTab(dayNum: Int, label: String) -> some View {
        let isSelected = (selectedDayFilter ?? 0) == dayNum
        let color: Color = dayNum == 0 ? AppColors.appPrimary : AppColors.dayColor(for: dayNum)
        let hasPlaces = dayNum == 0
            ? !mappablePlaces.isEmpty
            : mappablePlaces.contains { dayNumberByDayId[$0.itineraryDayId] == dayNum }

        return Button {
            HapticManager.selection()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                selectedDayFilter = dayNum == 0 ? nil : dayNum
            }
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if dayNum != 0 {
                        Circle()
                            .fill(hasPlaces ? color : Color(UIColor.tertiaryLabel))
                            .frame(width: 5, height: 5)
                    }
                    Text(label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? color : Color(UIColor.secondaryLabel))
                        .fixedSize()
                }
                .padding(.horizontal, 12)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(isSelected ? color : Color.clear)
                    .frame(height: 2)
            }
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .id(dayNum)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(dayNum == 0
            ? "All days, \(mappablePlaces.count) places"
            : "Day \(dayNum)\(hasPlaces ? "" : ", no places planned")")
    }
}

// MARK: - Expanded Sheet (presented as .sheet when user expands)

/// Full places sheet with search bar, day tabs, and place list.
struct TripMapPlacesExpandedSheet: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    @Binding var activeCategoryFilter: String?
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    let onSelectPlace: (Place) -> Void
    var onSearchResultSelected: (String, Double, Double) -> Void = { _, _, _ in }
    @Binding var searchText: String

    var body: some View {
        NavigationStack {
            TripMapPlacesExpandedContent(
                trip: trip,
                selectedDayFilter: $selectedDayFilter,
                activeCategoryFilter: $activeCategoryFilter,
                allPlacesForList: allPlacesForList,
                dayNumberByDayId: dayNumberByDayId,
                onSelectPlace: onSelectPlace,
                onSearchResultSelected: onSearchResultSelected,
                searchText: $searchText
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search places on map"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.words)
    }
}

// MARK: - Expanded Content (search + browse)

private struct TripMapPlacesExpandedContent: View {
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    let trip: Trip
    @Binding var selectedDayFilter: Int?
    @Binding var activeCategoryFilter: String?
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    let onSelectPlace: (Place) -> Void
    var onSearchResultSelected: (String, Double, Double) -> Void = { _, _, _ in }
    @Binding var searchText: String

    @State private var placeSearch = PlaceSearchService()

    private var dayCount: Int { max(trip.dayCount, 1) }

    private var dayFilterTabBinding: Binding<Int> {
        Binding(
            get: { selectedDayFilter ?? 0 },
            set: { newValue in selectedDayFilter = newValue == 0 ? nil : newValue }
        )
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if isSearching {
                searchOverlay
            } else {
                browseContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: isSearching)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                categoryPillsBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: searchText) { _, newVal in
            let q = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                placeSearch.clearResults()
            } else {
                placeSearch.search(query: q, types: "establishment")
            }
        }
    }

    // MARK: – Category pills bar

    private var categoryPillsBar: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CategoryPill.all) { pill in
                        categoryPill(pill)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.regularMaterial)
        }
    }

    private func categoryPill(_ pill: CategoryPill) -> some View {
        let isActive = activeCategoryFilter == pill.id
        return Button {
            HapticManager.selection()
            if isActive {
                activeCategoryFilter = nil
                searchText = ""
                placeSearch.clearResults()
            } else {
                activeCategoryFilter = pill.id
                searchText = pill.label
                placeSearch.search(query: pill.label, types: "establishment")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pill.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(pill.label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isActive ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(isActive ? AppColors.appPrimary : Color(UIColor.secondarySystemFill))
            }
            .overlay {
                if !isActive {
                    Capsule()
                        .strokeBorder(Color(UIColor.separator).opacity(0.4), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: – Search overlay

    @ViewBuilder
    private var searchOverlay: some View {
        if query.isEmpty {
            List {
                if !allPlacesForList.isEmpty {
                    Section {
                        ForEach(allPlacesForList.prefix(8)) { place in
                            placeRow(place)
                        }
                    } header: { sectionLabel("On This Trip") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.clear)
        } else if placeSearch.isSearching {
            List {
                Section {
                    ForEach(0..<5, id: \.self) { _ in skeletonRow }
                } header: { sectionLabel("Places") }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.clear)
        } else if placeSearch.results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                Section {
                    ForEach(placeSearch.results) { result in
                        autocompleteRow(result)
                    }
                } header: { sectionLabel("Places") }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: – Browse content

    private var browseContent: some View {
        VStack(spacing: 0) {
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
            .background(Color(UIColor.systemBackground))

            Divider()

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
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .scrollDismissesKeyboard(.interactively)
    }

    private func placeRow(_ place: Place) -> some View {
        Button {
            HapticManager.light()
            onSelectPlace(place)
        } label: {
            HStack(spacing: 14) {
                let iconColor: Color = place.isBooking
                    ? (place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
                    : categoryColor(for: place)
                let iconName: String = place.isBooking
                    ? (place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill")
                    : place.categoryEnum.sfSymbol

                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if let addr = place.address, !addr.isEmpty {
                        Text(addr).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .padding(.vertical, 10)
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

    private func autocompleteRow(_ result: PlaceAutocompleteResult) -> some View {
        Button {
            HapticManager.light()
            dismissSearch()
            Task {
                if let detail = await placeSearch.getPlaceDetails(placeId: result.id) {
                    await MainActor.run {
                        onSearchResultSelected(detail.name, detail.lat, detail.lng)
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(UIColor.tertiarySystemFill)).frame(width: 38, height: 38)
                    Image(systemName: "mappin").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.mainText).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if !result.secondaryText.isEmpty {
                        Text(result.secondaryText).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.fullDescription)
    }

    private var skeletonRow: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(UIColor.tertiarySystemFill)).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color(UIColor.tertiarySystemFill)).frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(Color(UIColor.tertiarySystemFill)).frame(width: 100, height: 12)
            }
            Spacer()
        }
        .padding(.vertical, 10).listRowBackground(Color.clear).listRowSeparator(.hidden).redacted(reason: .placeholder)
    }

    private var emptyDayState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash.circle").font(.system(size: 40)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            Text("No places yet").font(.headline).foregroundStyle(.primary)
            Text("Places you add with a location will appear here.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.5)
    }
}

