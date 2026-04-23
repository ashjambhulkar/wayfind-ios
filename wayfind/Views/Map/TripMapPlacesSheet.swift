import SwiftUI
import UIKit

/// Map bottom `sheet` content: short strip, half-height, or large — detents are owned by the parent `sheet` modifier.
struct TripMapPlacesSheet: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    @Binding var activeCategoryFilter: String?

    let mappablePlaces: [Place]
    /// "All" tab: day + search–filtered, sorted.
    let allPlacesForList: [Place]
    let dayNumberByDayId: [UUID: Int]
    @Binding var sheetDetent: PresentationDetent
    let minSheetDetent: PresentationDetent
    let onSelectPlace: (Place) -> Void
    @Binding var searchText: String

    private var isMinimized: Bool {
        sheetDetent == minSheetDetent
    }

    private var dayCount: Int {
        max(trip.dayCount, 1)
    }

    private var dayFilterTabBinding: Binding<Int> {
        Binding(
            get: { selectedDayFilter ?? 0 },
            set: { newValue in selectedDayFilter = newValue == 0 ? nil : newValue }
        )
    }

    var body: some View {
        Group {
            if isMinimized {
                placesDockedBar
            } else {
                NavigationStack {
                    placesContent
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .searchable(
                            text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search places..."
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isMinimized
            ? (mappablePlaces.count == 1 ? "Places, 1 on map, tap to expand" : "Places, \(mappablePlaces.count) on map, tap to expand")
            : "Places, swipe to change day"
        )
    }

    /// Shown at the minimum detent — clean compact strip; tap to grow to `.medium`.
    private var placesDockedBar: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                sheetDetent = .medium
            }
        } label: {
            VStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 42, height: 5)
                    .accessibilityHidden(true)

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Places")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(mappablePlaces.count == 1 ? "1 on map" : "\(mappablePlaces.count) on map")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placesContent: some View {
        VStack(spacing: 0) {
            TripMapCategoryPillsBar(
                activeCategoryFilter: $activeCategoryFilter,
                searchText: $searchText
            )
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)

            DayFilterChipsView(
                selectedDay: $selectedDayFilter,
                dayCount: dayCount,
                unselectedSystemFill: true
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            TabView(selection: dayFilterTabBinding) {
                dayPage(
                    title: "All",
                    places: allPlacesForList
                )
                .tag(0 as Int)

                ForEach(1...dayCount, id: \.self) { dayNum in
                    let dayPlaces = allPlacesForList
                        .filter { dayNumberByDayId[$0.itineraryDayId] == dayNum }
                        .sorted { $0.sortOrder < $1.sortOrder }

                    dayPage(
                        title: "Day \(dayNum)",
                        places: dayPlaces
                    )
                    .tag(dayNum)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.appBackground)
    }

    @ViewBuilder
    private func dayPage(title: String, places: [Place]) -> some View {
        List {
            Section {
                if places.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(places) { place in
                        placeRow(place)
                    }
                }
            } header: {
                sectionHeader(title)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyStateRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)

            Text("No stops")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Add places with map locations to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func placeRow(_ place: Place) -> some View {
        Button {
            HapticManager.light()
            onSelectPlace(place)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: place.isBooking
                      ? (place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill")
                      : "mappin.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(place.isBooking
                                     ? (place.bookingCategoryEnum?.color ?? AppColors.appPrimary)
                                     : AppColors.appPrimary)
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(UIColor.tertiarySystemFill))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    if let a = place.address, !a.isEmpty {
                        Text(a)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(place.name)")
    }
}