import SwiftUI

/// Horizontal category chips for the trip map search bar.
struct TripMapCategoryPillsBar: View {
    @Binding var activeCategoryFilter: String?
    @Binding var searchText: String

    private static let filterMeta: [String: (label: String, symbol: String)] = [
        "attractions": ("Attractions", "building.columns"),
        "restaurants": ("Restaurants", "fork.knife"),
        "nightlife": ("Nightlife", "moon.stars"),
        "museums": ("Museums", "paintpalette"),
        "cafes": ("Cafes", "cup.and.saucer"),
        "parks": ("Parks", "leaf"),
        "shopping": ("Shopping", "bag"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill("attractions")
                pill("restaurants")
                pill("nightlife")
                pill("museums")
                pill("cafes")
                pill("parks")
                pill("shopping")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func pill(_ id: String) -> some View {
        if let meta = Self.filterMeta[id] {
            let isActive = activeCategoryFilter == id
            Button {
                HapticManager.selection()
                if isActive {
                    activeCategoryFilter = nil
                    searchText = ""
                } else {
                    activeCategoryFilter = id
                    searchText = id
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: meta.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(meta.label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundStyle(isActive ? .white : AppColors.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    if isActive {
                        Capsule().fill(AppColors.appPrimary)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .overlay(
                    Capsule()
                        .strokeBorder(isActive ? Color.clear : AppColors.appDivider.opacity(0.5), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
