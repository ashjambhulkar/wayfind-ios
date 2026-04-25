import MapKit
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
        // The whole bar is tappable — matches Apple Music's now-playing
        // bar, which is the only Apple-blessed pattern for this API
        // (`tabViewBottomAccessory` has no native drag-to-expand).
        // Day-pill `Button`s intercept their own taps because SwiftUI
        // hit-testing always prefers a child control over a background
        // gesture, so taps that land on empty bar space fall through
        // to `Color.clear` and trigger `onExpand()`.
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    HapticManager.light()
                    onExpand()
                }
                .accessibilityHidden(true)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        dockedDayTab(dayNum: 0, label: "All")
                        ForEach(1...max(trip.dayCount, 1), id: \.self) { dayNum in
                            dockedDayTab(dayNum: dayNum, label: "Day \(dayNum)")
                        }
                    }
                    .padding(.horizontal, 8)
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
        }
        .frame(height: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mappablePlaces.count) places on map. Double tap to expand.")
        .accessibilityAction(named: Text("Expand places")) {
            onExpand()
        }
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
            HStack(spacing: 6) {
                if dayNum != 0 {
                    Circle()
                        .fill(hasPlaces ? color : AppColors.textTertiary)
                        .frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? AppColors.appPrimary : AppColors.textPrimary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background {
                Capsule()
                    .fill(.regularMaterial)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? AppColors.appPrimary.opacity(0.48) : Color.primary.opacity(0.12),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
            .padding(.vertical, 8)
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

/// Day-list-only sheet shown above the tab bar when the user expands the
/// accessory. Search now lives in the floating `MapSearchPill` on top of
/// the map (Phase 3), so this sheet has only one job: list the places we
/// already added to each day.
struct TripMapPlacesExpandedSheet: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    let onSelectPlace: (Place) -> Void

    var body: some View {
        NavigationStack {
            TripMapPlacesDayListContent(
                trip: trip,
                selectedDayFilter: $selectedDayFilter,
                allPlacesForList: allPlacesForList,
                dayNumberByDayId: dayNumberByDayId,
                onSelectPlace: onSelectPlace
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
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

    private var dayCount: Int { max(trip.dayCount, 1) }

    private var dayFilterTabBinding: Binding<Int> {
        Binding(
            get: { selectedDayFilter ?? 0 },
            set: { newValue in selectedDayFilter = newValue == 0 ? nil : newValue }
        )
    }

    var body: some View {
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

    private var emptyDayState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash.circle")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No places yet").font(.headline).foregroundStyle(.primary)
            Text("Places you add with a location will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// =============================================================================
