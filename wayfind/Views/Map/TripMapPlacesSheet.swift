import MapKit
import SwiftUI
import UIKit

// MARK: - Places Sheet

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
        VStack(spacing: 0) {
            expandedHeader

            Divider().opacity(0.45)

            TripMapPlacesDayListContent(
                trip: trip,
                selectedDayFilter: $selectedDayFilter,
                allPlacesForList: allPlacesForList,
                dayNumberByDayId: dayNumberByDayId,
                onSelectPlace: onSelectPlace,
                showsDayTabs: false
            )
        }
        .background(.regularMaterial)
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Places")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(expandedSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text("\(allPlacesForList.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 5)
                    .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                    .accessibilityLabel("\(allPlacesForList.count) places")
            }
            .padding(.horizontal, AppSpacing.lg)

            DayFilterChipsView(
                selectedDay: $selectedDayFilter,
                dayCount: max(trip.dayCount, 1),
                unselectedSystemFill: true
            )
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.top, AppSpacing.lg)
        .padding(.bottom, AppSpacing.md)
    }

    private var expandedSubtitle: String {
        if let selectedDayFilter {
            return "Showing Day \(selectedDayFilter)"
        }
        return "All days on this map"
    }
}

// MARK: - Minimized Accessory

struct MapPlacesMinimizedAccessory: View {
    let trip: Trip
    @Binding var selectedDayFilter: Int?
    let allPlacesForList: [Place]
    var onExpand: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            DayFilterChipsView(
                selectedDay: $selectedDayFilter,
                dayCount: max(trip.dayCount, 1),
                unselectedSystemFill: true
            )
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.top, AppSpacing.sm)

            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .frame(height: 60)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
        .padding(.horizontal, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
        .contentShape(Capsule())
        .onTapGesture {
            HapticManager.light()
            onExpand()
        }
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height < -10 {
                    HapticManager.light()
                    onExpand()
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(allPlacesForList.count) places on map. Double tap to expand.")
        .accessibilityAction(named: Text("Expand places")) {
            onExpand()
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
                .background(Color(UIColor.systemBackground))

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
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            .listRowBackground(AppColors.appSurface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: iconName)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let addr = place.address, !addr.isEmpty {
                        Text(addr)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(place.isBooking ? "Booking" : place.categoryEnum.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .padding(.vertical, AppSpacing.sm)
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
}

private enum TripMapPlacesSheet_Previews {}

#Preview("Places sheet — expanded") {
    @Previewable @State var dayFilter: Int? = nil
    TripMapPlacesExpandedSheet(
        trip: TripMapPlacesSheet_Previews.sampleTrip,
        selectedDayFilter: $dayFilter,
        allPlacesForList: TripMapPlacesSheet_Previews.samplePlaces,
        dayNumberByDayId: TripMapPlacesSheet_Previews.dayNumberByDayId,
        onSelectPlace: { _ in }
    )
}

#Preview("Places sheet — expanded, day 1 selected") {
    @Previewable @State var dayFilter: Int? = 1
    TripMapPlacesExpandedSheet(
        trip: TripMapPlacesSheet_Previews.sampleTrip,
        selectedDayFilter: $dayFilter,
        allPlacesForList: TripMapPlacesSheet_Previews.samplePlaces,
        dayNumberByDayId: TripMapPlacesSheet_Previews.dayNumberByDayId,
        onSelectPlace: { _ in }
    )
}

#Preview("Places sheet — minimized accessory") {
    @Previewable @State var dayFilter: Int? = nil
    ZStack(alignment: .bottom) {
        Color.gray.opacity(0.3).ignoresSafeArea()
        MapPlacesMinimizedAccessory(
            trip: TripMapPlacesSheet_Previews.sampleTrip,
            selectedDayFilter: $dayFilter,
            allPlacesForList: TripMapPlacesSheet_Previews.samplePlaces,
            onExpand: {}
        )
        .padding(.bottom, 20)
    }
}
#endif
