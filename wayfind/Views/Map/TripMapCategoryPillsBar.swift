import SwiftUI

/// Data model for a category quick-filter pill.
///
/// Each pill carries its own `family` so the search overlay can render
/// it with a category-coloured glyph (matching the Apple Maps look —
/// orange fork & knife for food, blue gas pump for transport, etc.).
/// The default `MapSearchOverlay` pill row pairs a tinted icon with a
/// neutral material capsule so the strip stays calm even with seven
/// pills lined up.
struct CategoryPill: Identifiable {
    let id: String      // used as searchText value
    let label: String   // displayed text
    let symbol: String  // SF Symbol name
    let family: PlaceCategoryFamily

    static let all: [CategoryPill] = [
        CategoryPill(id: "attractions",
                     label: "Attractions",
                     symbol: "building.columns.fill",
                     family: .culture),
        CategoryPill(id: "restaurants",
                     label: "Restaurants",
                     symbol: "fork.knife",
                     family: .food),
        CategoryPill(id: "cafes",
                     label: "Cafes",
                     symbol: "cup.and.saucer.fill",
                     family: .food),
        CategoryPill(id: "museums",
                     label: "Museums",
                     symbol: "building.columns.fill",
                     family: .culture),
        CategoryPill(id: "parks",
                     label: "Parks",
                     symbol: "leaf.fill",
                     family: .nature),
        CategoryPill(id: "nightlife",
                     label: "Nightlife",
                     symbol: "wineglass.fill",
                     family: .food),
        CategoryPill(id: "shopping",
                     label: "Shopping",
                     symbol: "bag.fill",
                     family: .shopping),
    ]
}

// =============================================================================
