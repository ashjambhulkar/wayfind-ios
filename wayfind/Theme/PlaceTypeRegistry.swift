//
//  PlaceTypeRegistry.swift
//  wayfind
//
//  Single source of truth for SF Symbols + colors used across activities,
//  bookings, map pins, and search rows. Inspired by the Expo `placeTypesToSFSymbol`
//  registry, extended with a curated 7-family color palette so the UI feels
//  cohesive instead of rainbow.
//

import SwiftUI

// MARK: - Color families

/// Curated palette: every place/booking icon collapses into one of seven families
/// so related items share a hue and the UI scans calmly.
///
/// Add a new case **only** when an entire new domain appears (e.g. "wellness"),
/// otherwise pick the closest existing family.
enum PlaceCategoryFamily: String, CaseIterable, Codable {
    case stay
    case transport
    case food
    case nature
    case culture
    case shopping
    case generic

    /// Family color in light + dark. Tuned for ~AA contrast on `appBackground`
    /// and on white pin backgrounds.
    var color: Color {
        switch self {
        case .stay:
            Color(light: Color(hexValue: 0x7C5BA8), dark: Color(hexValue: 0x9D7ECB))
        case .transport:
            Color(light: Color(hexValue: 0x3B6FA8), dark: Color(hexValue: 0x5E92CC))
        case .food:
            Color(light: Color(hexValue: 0xC26F4B), dark: Color(hexValue: 0xD4845F))
        case .nature:
            Color(light: Color(hexValue: 0x3F8A5C), dark: Color(hexValue: 0x5DAD7B))
        case .culture:
            Color(light: Color(hexValue: 0x5C5FA0), dark: Color(hexValue: 0x8285C2))
        case .shopping:
            Color(light: Color(hexValue: 0xB5853D), dark: Color(hexValue: 0xCFA161))
        case .generic:
            AppColors.textTertiary
        }
    }

    /// Subtle tinted background — for chips, pin halos, list-row leading bars.
    var tint: Color { color.opacity(0.14) }

    var label: String {
        switch self {
        case .stay: "Stay"
        case .transport: "Transport"
        case .food: "Food & Drink"
        case .nature: "Outdoors"
        case .culture: "Culture & Sights"
        case .shopping: "Shopping"
        case .generic: "Place"
        }
    }
}

/// Every entry in the Google-place-types table is `(symbol, family)`.
struct PlaceTypeIcon: Equatable {
    let symbol: String
    let family: PlaceCategoryFamily

    var color: Color { family.color }
}

// MARK: - Booking category → family + icon

extension BookingCategory {
    var family: PlaceCategoryFamily {
        switch self {
        case .flight: .transport
        case .hotel: .stay
        case .restaurant: .food
        case .carRental: .transport
        case .activity: .culture
        case .transport: .transport
        }
    }

    /// Family-aligned color so all transport-y bookings share the same hue, etc.
    var familyColor: Color { family.color }
}

// MARK: - Activity / place category → family + icon

extension PlaceCategory {
    var family: PlaceCategoryFamily {
        switch self {
        case .attraction: .culture
        case .restaurant: .food
        case .hotel: .stay
        case .transport: .transport
        case .shopping: .shopping
        case .nightlife: .food
        case .nature: .nature
        case .custom: .generic
        }
    }

    var color: Color { family.color }

    /// Compact map-pin variant — circle/filled glyphs that read at ~10pt.
    var mapBadgeSymbol: String {
        switch self {
        case .attraction: "star.fill"
        case .restaurant: "fork.knife"
        case .hotel: "bed.double.fill"
        case .transport: "tram.fill"
        case .shopping: "bag.fill"
        case .nightlife: "wineglass.fill"
        case .nature: "leaf.fill"
        case .custom: "mappin"
        }
    }
}

// MARK: - Activity form ordering

/// Stable order for the activity category chip strip on add/edit forms.
let ACTIVITY_FORM_CATEGORY_ORDER: [PlaceCategory] = [
    .attraction, .restaurant, .transport, .shopping, .nature, .nightlife, .custom,
]

// MARK: - Google `types[]` → SF Symbol + family
//
// Priority-ordered: scanned top → bottom, first match wins so specific types
// (e.g. `national_park`) beat generic ones (`park`). Keep `point_of_interest`
// LAST as the catch-all bucket; `placeTypesToDistinctSearchRowSymbol` relies on this.

private let placeTypeRegistry: [(keys: Set<String>, icon: PlaceTypeIcon)] = [
    // ── Accommodation ────────────────────────────────────────
    (["resort_hotel"],                                                 PlaceTypeIcon(symbol: "sun.horizon.fill",      family: .stay)),
    (["bed_and_breakfast", "guest_house"],                             PlaceTypeIcon(symbol: "house.fill",            family: .stay)),
    (["lodging", "hotel", "hostel", "motel"],                          PlaceTypeIcon(symbol: "bed.double.fill",       family: .stay)),

    // ── Transport ────────────────────────────────────────────
    (["airport", "international_airport"],                             PlaceTypeIcon(symbol: "airplane",              family: .transport)),
    (["train_station", "light_rail_station"],                          PlaceTypeIcon(symbol: "tram.fill",             family: .transport)),
    (["subway_station"],                                               PlaceTypeIcon(symbol: "tram.fill",             family: .transport)),
    (["bus_station", "bus_stop"],                                      PlaceTypeIcon(symbol: "bus.fill",              family: .transport)),
    (["ferry_terminal"],                                               PlaceTypeIcon(symbol: "ferry.fill",            family: .transport)),
    (["taxi_stand"],                                                   PlaceTypeIcon(symbol: "car.fill",              family: .transport)),
    (["parking"],                                                      PlaceTypeIcon(symbol: "parkingsign",           family: .transport)),
    (["transit_station"],                                              PlaceTypeIcon(symbol: "arrow.triangle.swap",   family: .transport)),

    // ── Nightlife (food family — drinks/eats are warm) ───────
    (["night_club"],                                                   PlaceTypeIcon(symbol: "music.note",            family: .food)),
    (["casino"],                                                       PlaceTypeIcon(symbol: "die.face.5.fill",       family: .culture)),
    (["bar", "cocktail_bar", "brewery", "sports_bar"],                 PlaceTypeIcon(symbol: "wineglass.fill",        family: .food)),

    // ── Food & drink ─────────────────────────────────────────
    (["cafe", "coffee_shop"],                                          PlaceTypeIcon(symbol: "cup.and.saucer.fill",   family: .food)),
    (["bakery", "dessert_shop", "ice_cream_shop"],                     PlaceTypeIcon(symbol: "birthday.cake.fill",    family: .food)),
    (["breakfast_restaurant", "brunch_restaurant"],                    PlaceTypeIcon(symbol: "cup.and.saucer.fill",   family: .food)),
    (["restaurant", "meal_takeaway", "meal_delivery",
      "fast_food_restaurant", "deli", "food"],                         PlaceTypeIcon(symbol: "fork.knife.circle.fill", family: .food)),

    // ── Entertainment (culture family) ───────────────────────
    (["performing_arts_theater", "opera_house", "comedy_club"],        PlaceTypeIcon(symbol: "theatermasks.fill",     family: .culture)),
    (["live_music_venue", "concert_hall"],                             PlaceTypeIcon(symbol: "music.microphone",      family: .culture)),
    (["movie_theater"],                                                PlaceTypeIcon(symbol: "film.fill",             family: .culture)),
    (["amusement_park", "water_park"],                                 PlaceTypeIcon(symbol: "ticket.fill",           family: .culture)),
    (["stadium"],                                                      PlaceTypeIcon(symbol: "sportscourt.fill",      family: .culture)),
    (["spa"],                                                          PlaceTypeIcon(symbol: "sparkles",              family: .culture)),

    // ── Shopping ─────────────────────────────────────────────
    (["book_store"],                                                   PlaceTypeIcon(symbol: "book.fill",             family: .shopping)),
    (["clothing_store"],                                               PlaceTypeIcon(symbol: "tshirt.fill",           family: .shopping)),
    (["souvenir_store", "gift_shop"],                                  PlaceTypeIcon(symbol: "gift.fill",             family: .shopping)),
    (["market", "grocery_or_supermarket", "supermarket"],              PlaceTypeIcon(symbol: "storefront.fill",       family: .shopping)),
    (["shopping_mall", "department_store"],                            PlaceTypeIcon(symbol: "bag.fill",              family: .shopping)),
    (["store", "convenience_store"],                                   PlaceTypeIcon(symbol: "storefront.fill",       family: .shopping)),

    // ── Nature & outdoor ─────────────────────────────────────
    (["aquarium"],                                                     PlaceTypeIcon(symbol: "water.waves",           family: .nature)),
    (["marina"],                                                       PlaceTypeIcon(symbol: "sailboat.fill",         family: .nature)),
    (["zoo", "wildlife_park", "wildlife_refuge"],                      PlaceTypeIcon(symbol: "pawprint.fill",         family: .nature)),
    (["botanical_garden", "garden"],                                   PlaceTypeIcon(symbol: "leaf.circle.fill",      family: .nature)),
    (["hiking_area", "campground"],                                    PlaceTypeIcon(symbol: "figure.hiking",         family: .nature)),
    (["beach"],                                                        PlaceTypeIcon(symbol: "sun.horizon.fill",      family: .nature)),
    (["national_park", "state_park"],                                  PlaceTypeIcon(symbol: "mountain.2.fill",       family: .nature)),
    (["park", "city_park", "natural_feature", "rv_park"],              PlaceTypeIcon(symbol: "tree.fill",             family: .nature)),

    // ── Sightseeing / culture ────────────────────────────────
    (["art_gallery"],                                                  PlaceTypeIcon(symbol: "photo.artframe",        family: .culture)),
    (["observation_deck"],                                             PlaceTypeIcon(symbol: "binoculars.fill",       family: .culture)),
    (["castle"],                                                       PlaceTypeIcon(symbol: "building.2.fill",       family: .culture)),
    (["museum", "historical_landmark", "cultural_landmark", "monument"], PlaceTypeIcon(symbol: "building.columns.fill", family: .culture)),
    (["place_of_worship", "church", "mosque", "synagogue", "hindu_temple"], PlaceTypeIcon(symbol: "building.columns.fill", family: .culture)),
    (["library"],                                                      PlaceTypeIcon(symbol: "books.vertical.fill",   family: .culture)),
    (["visitor_center"],                                               PlaceTypeIcon(symbol: "info.circle.fill",      family: .culture)),
    (["tourist_attraction", "landmark"],                               PlaceTypeIcon(symbol: "binoculars.fill",       family: .culture)),
    (["city_hall"],                                                    PlaceTypeIcon(symbol: "building.columns.fill", family: .culture)),
    (["university", "school"],                                         PlaceTypeIcon(symbol: "graduationcap.fill",    family: .culture)),
    (["plaza"],                                                        PlaceTypeIcon(symbol: "mappin.circle.fill",    family: .generic)),

    // ── Generic POI (must stay LAST) ─────────────────────────
    (["point_of_interest", "establishment"],                           PlaceTypeIcon(symbol: "star.fill",             family: .generic)),
]

// MARK: - Public helpers

enum PlaceTypeRegistry {
    /// Map a Google `types[]` array → most specific `(symbol, color)` icon.
    /// Returns `nil` when nothing matches so callers can fall back to a category icon.
    static func icon(for types: [String]?) -> PlaceTypeIcon? {
        guard let types, !types.isEmpty else { return nil }
        let typeSet = Set(types.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for entry in placeTypeRegistry where !entry.keys.isDisjoint(with: typeSet) {
            return entry.icon
        }
        return nil
    }

    /// Same as `icon(for:)` but excludes the catch-all `point_of_interest`/`establishment`
    /// entry — for search rows that should stay visually quiet on generic results.
    static func distinctSearchRowIcon(for types: [String]?) -> PlaceTypeIcon? {
        guard let types, !types.isEmpty else { return nil }
        let typeSet = Set(types.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        // Drop the trailing generic POI bucket.
        let entries = placeTypeRegistry.dropLast()
        for entry in entries where !entry.keys.isDisjoint(with: typeSet) {
            return entry.icon
        }
        return nil
    }
}

// MARK: - Internal hex helper
//
// `Color(hex:)` already exists in `AppColors.swift` but is declared `private`
// to that file. Mirror it locally so this file is self-contained.

private extension Color {
    init(hexValue: UInt32) {
        self.init(
            red: Double((hexValue >> 16) & 0xFF) / 255,
            green: Double((hexValue >> 8) & 0xFF) / 255,
            blue: Double(hexValue & 0xFF) / 255
        )
    }
}
