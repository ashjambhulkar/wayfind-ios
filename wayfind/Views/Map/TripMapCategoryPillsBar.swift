import SwiftUI

/// Data model for a category quick-filter pill.
struct CategoryPill: Identifiable {
    let id: String      // used as searchText value
    let label: String   // displayed text
    let symbol: String  // SF Symbol name

    static let all: [CategoryPill] = [
        CategoryPill(id: "attractions",  label: "Attractions",  symbol: "building.columns"),
        CategoryPill(id: "restaurants",  label: "Restaurants",  symbol: "fork.knife"),
        CategoryPill(id: "cafes",        label: "Cafes",        symbol: "cup.and.saucer"),
        CategoryPill(id: "museums",      label: "Museums",      symbol: "paintpalette"),
        CategoryPill(id: "parks",        label: "Parks",        symbol: "leaf"),
        CategoryPill(id: "nightlife",    label: "Nightlife",    symbol: "moon.stars"),
        CategoryPill(id: "shopping",     label: "Shopping",     symbol: "bag"),
    ]
}

// =============================================================================

