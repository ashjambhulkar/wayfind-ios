//
//  PlaceSearchService.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
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
    private var sessionToken = UUID().uuidString

    func search(query: String, types: String = "(cities)") {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let apiKey = AppConfig.googlePlacesAPIKey
            guard !apiKey.contains("YOUR_") else {
                await loadMockResults(query: trimmed)
                return
            }

            isSearching = true
            defer { isSearching = false }

            var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/autocomplete/json")!
            components.queryItems = [
                URLQueryItem(name: "input", value: trimmed),
                URLQueryItem(name: "types", value: types),
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "sessiontoken", value: sessionToken),
            ]

            guard let url = components.url else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let response = try JSONDecoder().decode(AutocompleteResponse.self, from: data)
                results = response.predictions.map { prediction in
                    PlaceAutocompleteResult(
                        id: prediction.placeId,
                        mainText: prediction.structuredFormatting.mainText,
                        secondaryText: prediction.structuredFormatting.secondaryText ?? "",
                        fullDescription: prediction.description
                    )
                }
            } catch {
                await loadMockResults(query: trimmed)
            }
        }
    }

    func getPlaceDetails(placeId: String) async -> PlaceDetail? {
        let apiKey = AppConfig.googlePlacesAPIKey
        guard !apiKey.contains("YOUR_") else { return nil }

        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/details/json")!
        components.queryItems = [
            URLQueryItem(name: "place_id", value: placeId),
            URLQueryItem(name: "fields", value: "name,formatted_address,geometry,types"),
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "sessiontoken", value: sessionToken),
        ]

        sessionToken = UUID().uuidString

        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(PlaceDetailsResponse.self, from: data)
            guard let result = response.result else { return nil }
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

private struct AutocompleteResponse: Decodable {
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

