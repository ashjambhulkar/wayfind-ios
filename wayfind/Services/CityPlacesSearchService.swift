//
//  CityPlacesSearchService.swift
//  wayfind
//
//  Phase 4 of the Map Screen Search Redesign plan.
//
//  Search the existing `city_places` table for a trip's city. Free —
//  the table is public-read (RLS) and every row represents money we
//  already spent enriching that city. The map search overlay fans out
//  in parallel to MapKit *and* this service; results are merged with
//  the dedupe rules in `MapSearchOverlay`.
//
//  Locked invariants:
//    • Pure read. No writes, no enrichment fan-out, no Place Details
//      hops. The whole point is zero outbound network beyond a single
//      PostgREST round-trip.
//    • Bbox-bounded. We never scan the whole table — region filter is
//      mandatory. Caller is responsible for passing a sane region (the
//      live MKMapView viewport is fine).
//    • Excludes any `place_id` already on a scheduled day in the
//      current trip. Wishlist places are NOT excluded so the user can
//      still re-add and reschedule.
//

import Auth
import CoreLocation
import Foundation
import MapKit
import Supabase

@MainActor
final class CityPlacesSearchService {

    static let shared = CityPlacesSearchService()

    private init() {}

    // MARK: - Public API

    /// Search city_places for a trip city.
    ///
    /// - Parameters:
    ///   - cityProfileId: The trip's resolved city profile id. Pass
    ///     `nil` to short-circuit (returns empty without hitting
    ///     Postgres) — useful when the trip has no resolved city.
    ///   - query: Optional free-text. When non-nil and ≥ 2 chars, an
    ///     `ilike` filter on `name` runs server-side; otherwise the
    ///     query is purely category + bbox.
    ///   - category: Optional family filter (mapped to
    ///     `wayfind_category` on the row).
    ///   - region: Map viewport. Used to compute a bbox so we cap the
    ///     return set to what the user is actually looking at.
    ///   - excluding: Set of Google `place_id`s to drop client-side
    ///     (places already on a scheduled day of the current trip).
    ///   - limit: Hard cap. Defaults to 25 — anything more and the
    ///     cluster math gets sluggish.
    /// - Returns: Already-merged `MapSearchPreview` values tagged with
    ///   `.cityPlaces` origin. Empty array on miss / short-circuit /
    ///   error (we never fail the merge — Apple results are still
    ///   useful on their own).
    func search(
        cityProfileId: UUID?,
        query: String?,
        category: PlaceCategory?,
        region: MKCoordinateRegion,
        excluding: Set<String>,
        limit: Int = 25
    ) async -> [MapSearchPreview] {
        guard let cityProfileId else { return [] }
        guard let client = AuthSessionService.shared.client else { return [] }

        // Bbox from region. Padded slightly so the user doesn't see a
        // hard edge as they pan inside the original viewport.
        let lat = region.center.latitude
        let lng = region.center.longitude
        let latDelta = region.span.latitudeDelta * 0.6
        let lngDelta = region.span.longitudeDelta * 0.6
        let minLat = lat - latDelta
        let maxLat = lat + latDelta
        let minLng = lng - lngDelta
        let maxLng = lng + lngDelta

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let useTextFilter = (trimmedQuery?.count ?? 0) >= 2

        do {
            // PostgREST builder — we have to reassign at each step
            // because the type changes between filter and final.
            var builder = client
                .from("city_places")
                .select(
                    """
                    place_id,name,lat,lng,formatted_address,wayfind_category,\
                    thumbnail_url,formatted_phone_number,website,tier,dist_from_center_km
                    """
                )
                .eq("city_profile_id", value: cityProfileId.uuidString.lowercased())
                .eq("status", value: "active")
                .gte("lat", value: minLat)
                .lte("lat", value: maxLat)
                .gte("lng", value: minLng)
                .lte("lng", value: maxLng)

            if let category {
                builder = builder.eq(
                    "wayfind_category",
                    value: category.cityPlacesCategoryString
                )
            }

            if useTextFilter, let q = trimmedQuery {
                // PostgREST `ilike` with wildcards — cheap pre-filter,
                // exact ranking happens client-side.
                builder = builder.ilike("name", pattern: "%\(q)%")
            }

            // Tier ASC = curated rows first; rows nearest the city
            // centre tend to be more search-worthy.
            let rows: [Row] = try await builder
                .order("tier", ascending: true)
                .order("dist_from_center_km", ascending: true, nullsFirst: false)
                .limit(limit * 2)  // over-fetch so client-side exclude doesn't starve us
                .execute()
                .value

            // Client-side filter: drop scheduled-day places, then cap
            // to `limit`.
            var out: [MapSearchPreview] = []
            out.reserveCapacity(min(limit, rows.count))
            for row in rows {
                if excluding.contains(row.place_id) { continue }
                out.append(row.toPreview)
                if out.count == limit { break }
            }
            return out
        } catch is CancellationError {
            return []
        } catch {
            #if DEBUG
            print("[CityPlacesSearchService] search failed: \(error)")
            #endif
            return []
        }
    }

    // MARK: - Suggested places (empty state)

    /// Pull the highest-tier rows for a city, ignoring viewport. Used to
    /// populate the "Suggested Places" carousel when the search bar is
    /// empty — we want the best curated rows for the destination, not
    /// just whatever happens to fall inside the user's current zoom.
    ///
    /// - Parameters:
    ///   - cityProfileId: Trip's resolved city. Returns empty without
    ///     hitting Postgres when nil.
    ///   - category: Optional family filter (e.g. only restaurants).
    ///   - excluding: Place ids already on a scheduled day to skip.
    ///   - limit: Hard cap. Defaults to 30 — enough to fill an "all
    ///     suggestions" sheet without choking the JSON decode.
    /// - Returns: Curated rows ordered by `tier` ASC then
    ///   `dist_from_center_km` ASC. Tagged `.cityPlaces`. Empty array on
    ///   any failure — search fan-out should never fail because of us.
    func topPicks(
        cityProfileId: UUID?,
        category: PlaceCategory? = nil,
        excluding: Set<String> = [],
        limit: Int = 30
    ) async -> [MapSearchPreview] {
        guard let cityProfileId else { return [] }
        guard let client = AuthSessionService.shared.client else { return [] }

        do {
            var builder = client
                .from("city_places")
                .select(
                    """
                    place_id,name,lat,lng,formatted_address,wayfind_category,\
                    thumbnail_url,formatted_phone_number,website,tier,dist_from_center_km
                    """
                )
                .eq("city_profile_id", value: cityProfileId.uuidString.lowercased())
                .eq("status", value: "active")

            if let category {
                builder = builder.eq(
                    "wayfind_category",
                    value: category.cityPlacesCategoryString
                )
            }

            let rows: [Row] = try await builder
                .order("tier", ascending: true)
                .order("dist_from_center_km", ascending: true, nullsFirst: false)
                .limit(limit * 2)
                .execute()
                .value

            var out: [MapSearchPreview] = []
            out.reserveCapacity(min(limit, rows.count))
            for row in rows {
                if excluding.contains(row.place_id) { continue }
                out.append(row.toPreview)
                if out.count == limit { break }
            }
            return out
        } catch is CancellationError {
            return []
        } catch {
            #if DEBUG
            print("[CityPlacesSearchService] topPicks failed: \(error)")
            #endif
            return []
        }
    }

    // MARK: - Wire format

    private struct Row: Decodable, Sendable {
        let place_id: String
        let name: String
        let lat: Double
        let lng: Double
        let formatted_address: String?
        let wayfind_category: String?
        let thumbnail_url: String?
        let formatted_phone_number: String?
        let website: String?
        let tier: Int?
        let dist_from_center_km: Double?

        var toPreview: MapSearchPreview {
            MapSearchPreview(
                id: "city_places|\(place_id)",
                origin: .cityPlaces,
                name: name,
                subtitle: formatted_address ?? "",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                googlePlaceId: place_id,
                phone: formatted_phone_number,
                website: website.flatMap { URL(string: $0) },
                thumbnailURL: thumbnail_url.flatMap { URL(string: $0) },
                category: PlaceCategory.fromCityPlacesCategoryString(wayfind_category)
            )
        }
    }
}

// MARK: - PlaceCategory ↔ city_places.wayfind_category

extension PlaceCategory {
    /// Maps onto the `city_places.wayfind_category` CHECK constraint:
    /// `attraction | restaurant | nature | shopping | nightlife | custom`.
    /// Hotel and transport collapse to `custom` because city_places
    /// doesn't seed them.
    var cityPlacesCategoryString: String {
        switch self {
        case .attraction: return "attraction"
        case .restaurant: return "restaurant"
        case .nature:     return "nature"
        case .shopping:   return "shopping"
        case .nightlife:  return "nightlife"
        case .hotel, .transport, .custom: return "custom"
        }
    }

    static func fromCityPlacesCategoryString(_ raw: String?) -> PlaceCategory? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "attraction": return .attraction
        case "restaurant": return .restaurant
        case "nature":     return .nature
        case "shopping":   return .shopping
        case "nightlife":  return .nightlife
        case "custom":     return .custom
        default:           return nil
        }
    }

    /// Best-effort `PlaceCategory` from Google `types[]`. Used by the
    /// China-fallback path so the preview sheet renders a sensible
    /// leading icon without us spending a separate enrichment call.
    static func fromGoogleTypes(_ types: [String]) -> PlaceCategory? {
        guard !types.isEmpty else { return nil }
        let set = Set(types)
        if !set.intersection(["restaurant", "cafe", "bakery", "bar", "meal_takeaway", "meal_delivery"]).isEmpty {
            return .restaurant
        }
        if !set.intersection(["lodging"]).isEmpty {
            return .hotel
        }
        if !set.intersection(["museum", "art_gallery", "tourist_attraction", "place_of_worship", "stadium"]).isEmpty {
            return .attraction
        }
        if !set.intersection(["park", "natural_feature", "campground"]).isEmpty {
            return .nature
        }
        if !set.intersection(["shopping_mall", "store", "clothing_store"]).isEmpty {
            return .shopping
        }
        if !set.intersection(["night_club"]).isEmpty {
            return .nightlife
        }
        if !set.intersection(["airport", "train_station", "transit_station", "bus_station", "subway_station"]).isEmpty {
            return .transport
        }
        return .attraction
    }
}

// =============================================================================
