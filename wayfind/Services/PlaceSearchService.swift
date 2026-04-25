//
//  PlaceSearchService.swift
//  wayfind
//
//  Google Places autocomplete for the iOS app. After the Phase A migration
//  (places-cost-and-owned-data plan), this service is consulted by:
//    1. `AIStayAreaPickerSheet` — needs a Google `place_id` for the AI day
//       planner contract.
//    2. `TripMapPlacesSheet` — only when the trip is inside mainland China,
//       where MapKit returns sparse results.
//
//  Two implementation paths exist and are toggled at build time via
//  `AppConfig.useNewPlacesAPIForAutocomplete`:
//    • Places API (New) — `places.googleapis.com/v1/places:autocomplete` with
//      a strict `X-Goog-FieldMask` (default).
//    • Legacy Places API — `maps.googleapis.com/maps/api/place/autocomplete/json`.
//
//  Session tokens were removed in Phase B: they only matter when an
//  Autocomplete request is followed by a Place Details request inside the same
//  session. We dropped Place Details everywhere except the China fallback row,
//  so emitting a session token is dead weight that can confuse Google's
//  billing classification.
//

import Foundation
import Observation

struct PlaceAutocompleteResult: Identifiable, Hashable {
    let id: String
    let mainText: String
    let secondaryText: String
    let fullDescription: String
}

struct PlaceDetail {
    let placeId: String
    let name: String
    let address: String
    let lat: Double
    let lng: Double
    let types: [String]
}

@Observable
final class PlaceSearchService {
    var results: [PlaceAutocompleteResult] = []
    var isSearching = false
    private var searchTask: Task<Void, Never>?

    /// Min length 2 + 300ms debounce. Cuts ~60% of Autocomplete requests vs
    /// "fire on every keystroke" without harming perceived responsiveness.
    private let minQueryLength = 2
    private let debounceMillis = 300

    func search(query: String, types: String = "(cities)") {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minQueryLength else {
            results = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(debounceMillis))
            guard !Task.isCancelled else { return }

            guard AppConfig.useRealBackend else {
                await loadMockResults(query: trimmed)
                return
            }

            let apiKey = AppConfig.googlePlacesAPIKey
            guard !apiKey.contains("YOUR_") else {
                await loadMockResults(query: trimmed)
                return
            }

            isSearching = true
            defer { isSearching = false }

            do {
                // Phase G.2 — runtime flag picks the endpoint. The
                // service's default is `.new`, so a brand-new install
                // (or an offline launch where the flag table hasn't
                // synced yet) keeps the existing behaviour. The
                // build-time `AppConfig.useNewPlacesAPIForAutocomplete`
                // is no longer consulted here; the flag is now the
                // single source of truth, and the dashboard can flip
                // back to legacy without a binary release.
                let useNew = await MainActor.run {
                    FeatureFlagsService.shared.stayAreaAutocompleteAPI == .new
                }
                let predictions: [PlaceAutocompleteResult]
                if useNew {
                    predictions = try await fetchAutocompleteNew(query: trimmed, types: types, apiKey: apiKey)
                } else {
                    predictions = try await fetchAutocompleteLegacy(query: trimmed, types: types, apiKey: apiKey)
                }
                results = predictions
            } catch {
                await loadMockResults(query: trimmed)
            }
        }
    }

    /// Fetches a Place Details record. **Deprecated** — every call site that
    /// needed coordinates has been migrated to either MapKit (free) or to
    /// using the Autocomplete prediction's `place_id` directly. The only
    /// remaining caller is the China fallback in `TripMapPlacesSheet`, which
    /// uses `_getPlaceDetailsForChinaFallback` (see below) to opt into the
    /// cost without tripping the deprecation warning.
    ///
    /// Place Details is the most expensive Places SKU at this writing
    /// ($17–25/1k after the free tier). Adding new callers should require a
    /// PR comment explaining why MapKit can't serve.
    @available(*, deprecated, message: "Prefer Autocomplete-only flows. Place Details is the most expensive Places SKU.")
    func getPlaceDetails(placeId: String) async -> PlaceDetail? {
        await _placeDetails(placeId: placeId)
    }

    /// Sanctioned escape hatch for the China fallback in `TripMapPlacesSheet`.
    /// MapKit returns sparse data inside mainland China, so we accept the
    /// Place Details cost there. Do **not** call this from anywhere else.
    func _getPlaceDetailsForChinaFallback(placeId: String) async -> PlaceDetail? {
        await _placeDetails(placeId: placeId)
    }

    private func _placeDetails(placeId: String) async -> PlaceDetail? {
        guard AppConfig.useRealBackend else {
            return PlaceDetail(placeId: placeId, name: "Mock Place", address: "123 Main St", lat: 48.8566, lng: 2.3522, types: ["point_of_interest"])
        }
        let apiKey = AppConfig.googlePlacesAPIKey
        guard !apiKey.contains("YOUR_") else { return nil }

        let signpost = PlatformUsageTelemetry.begin(.googlePlaceDetails)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.googlePlaceDetails, id: signpost, status: outcome) }

        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/details/json")!
        components.queryItems = [
            URLQueryItem(name: "place_id", value: placeId),
            URLQueryItem(name: "fields", value: "name,formatted_address,geometry,types"),
            URLQueryItem(name: "key", value: apiKey),
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(PlaceDetailsResponse.self, from: data)
            guard let result = response.result else { return nil }
            outcome = .ok
            return PlaceDetail(
                placeId: placeId,
                name: result.name,
                address: result.formattedAddress ?? "",
                lat: result.geometry.location.lat,
                lng: result.geometry.location.lng,
                types: result.types ?? []
            )
        } catch {
            return nil
        }
    }

    func clearResults() {
        results = []
        searchTask?.cancel()
    }

    // MARK: - Autocomplete (New)

    /// `places.googleapis.com/v1/places:autocomplete` with a strict field mask
    /// so we never pull anything more than `placeId + text`. Same SKU pricing
    /// as Legacy but on Google's supported long-term endpoint.
    private func fetchAutocompleteNew(query: String, types: String, apiKey: String) async throws -> [PlaceAutocompleteResult] {
        let signpost = PlatformUsageTelemetry.begin(.googleAutocomplete)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.googleAutocomplete, id: signpost, status: outcome) }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:autocomplete")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "suggestions.placePrediction.placeId,suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )

        let body = AutocompleteNewRequest(
            input: query,
            includedPrimaryTypes: mapLegacyTypesToNewIncludedTypes(types)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(AutocompleteNewResponse.self, from: data)
        let mapped: [PlaceAutocompleteResult] = (decoded.suggestions ?? []).compactMap { suggestion -> PlaceAutocompleteResult? in
            guard let p = suggestion.placePrediction else { return nil }
            let main = p.structuredFormat?.mainText?.text ?? p.text?.text ?? ""
            let secondary = p.structuredFormat?.secondaryText?.text ?? ""
            let full = p.text?.text ?? main
            return PlaceAutocompleteResult(
                id: p.placeId,
                mainText: main,
                secondaryText: secondary,
                fullDescription: full
            )
        }
        outcome = mapped.isEmpty ? .empty : .ok
        return mapped
    }

    /// Translates the Legacy `types=` parameter into the New API's
    /// `includedPrimaryTypes`. Returns nil for `(cities)` since the New API
    /// doesn't expose a single equivalent and the empty include list yields
    /// the broadest results (which is what Legacy's `(cities)` approximates).
    private func mapLegacyTypesToNewIncludedTypes(_ legacy: String) -> [String]? {
        switch legacy {
        case "(cities)": return ["locality", "administrative_area_level_3"]
        case "geocode": return ["geocode"]
        case "establishment": return ["establishment"]
        case "address": return ["street_address"]
        default: return nil
        }
    }

    // MARK: - Autocomplete (Legacy)

    private func fetchAutocompleteLegacy(query: String, types: String, apiKey: String) async throws -> [PlaceAutocompleteResult] {
        let signpost = PlatformUsageTelemetry.begin(.googleAutocomplete)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.googleAutocomplete, id: signpost, status: outcome) }

        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/autocomplete/json")!
        components.queryItems = [
            URLQueryItem(name: "input", value: query),
            URLQueryItem(name: "types", value: types),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(AutocompleteLegacyResponse.self, from: data)
        let mapped = response.predictions.map { prediction in
            PlaceAutocompleteResult(
                id: prediction.placeId,
                mainText: prediction.structuredFormatting.mainText,
                secondaryText: prediction.structuredFormatting.secondaryText ?? "",
                fullDescription: prediction.description
            )
        }
        outcome = mapped.isEmpty ? .empty : .ok
        return mapped
    }

    // MARK: - Mock fallback

    private func loadMockResults(query: String) async {
        let mockCities: [(String, String)] = [
            ("Paris", "France"),
            ("Tokyo", "Japan"),
            ("London", "United Kingdom"),
            ("New York", "United States"),
            ("Barcelona", "Spain"),
            ("Rome", "Italy"),
            ("Sydney", "Australia"),
            ("Dubai", "United Arab Emirates"),
        ]
        let q = query.lowercased()
        results = mockCities
            .filter { $0.0.lowercased().contains(q) || $0.1.lowercased().contains(q) }
            .prefix(5)
            .map { PlaceAutocompleteResult(id: UUID().uuidString, mainText: $0.0, secondaryText: $0.1, fullDescription: "\($0.0), \($0.1)") }
    }
}

// MARK: - Legacy response shape

private struct AutocompleteLegacyResponse: Decodable {
    let predictions: [Prediction]

    struct Prediction: Decodable {
        let placeId: String
        let description: String
        let structuredFormatting: StructuredFormatting

        enum CodingKeys: String, CodingKey {
            case placeId = "place_id"
            case description
            case structuredFormatting = "structured_formatting"
        }
    }

    struct StructuredFormatting: Decodable {
        let mainText: String
        let secondaryText: String?

        enum CodingKeys: String, CodingKey {
            case mainText = "main_text"
            case secondaryText = "secondary_text"
        }
    }
}

// MARK: - New API request / response shape

private struct AutocompleteNewRequest: Encodable {
    let input: String
    let includedPrimaryTypes: [String]?
}

private struct AutocompleteNewResponse: Decodable {
    let suggestions: [Suggestion]?

    struct Suggestion: Decodable {
        let placePrediction: PlacePrediction?
    }

    struct PlacePrediction: Decodable {
        let placeId: String
        let text: TextSpan?
        let structuredFormat: StructuredFormat?
    }

    struct StructuredFormat: Decodable {
        let mainText: TextSpan?
        let secondaryText: TextSpan?
    }

    struct TextSpan: Decodable {
        let text: String?
    }
}

// MARK: - Place Details (Legacy) response — only used by China fallback

private struct PlaceDetailsResponse: Decodable {
    let result: PlaceResult?

    struct PlaceResult: Decodable {
        let name: String
        let formattedAddress: String?
        let geometry: Geometry
        let types: [String]?

        enum CodingKeys: String, CodingKey {
            case name
            case formattedAddress = "formatted_address"
            case geometry
            case types
        }
    }

    struct Geometry: Decodable {
        let location: Location
    }

    struct Location: Decodable {
        let lat: Double
        let lng: Double
    }
}


// =============================================================================
