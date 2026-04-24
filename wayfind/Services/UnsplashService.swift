//
//  UnsplashService.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation

struct UnsplashPhoto: Identifiable {
    let id: String
    let url: String
    let authorName: String
    let authorUsername: String
    let downloadLocation: String

    var attributionText: String {
        "Photo by \(authorName) on Unsplash"
    }
}

enum UnsplashService {
    // Mock photos for Machine A — real Unsplash URLs that load without API key
    private static let mockPhotos: [UnsplashPhoto] = [
        UnsplashPhoto(id: "mock1", url: "https://images.unsplash.com/photo-1534430480872-3498386e7856?w=800&q=80", authorName: "Colton Duke", authorUsername: "coltonhdukefilm", downloadLocation: ""),
        UnsplashPhoto(id: "mock2", url: "https://images.unsplash.com/photo-1502602898657-3e91760cbb34?w=800&q=80", authorName: "Chris Karidis", authorUsername: "chriskaridis", downloadLocation: ""),
        UnsplashPhoto(id: "mock3", url: "https://images.unsplash.com/photo-1540959733332-eab4deabeeaf?w=800&q=80", authorName: "Jezael Melgoza", authorUsername: "jezael", downloadLocation: ""),
        UnsplashPhoto(id: "mock4", url: "https://images.unsplash.com/photo-1583422409516-2895a77efded?w=800&q=80", authorName: "Hala AlGhawormed", authorUsername: "hala", downloadLocation: ""),
        UnsplashPhoto(id: "mock5", url: "https://images.unsplash.com/photo-1496442226666-8d4d0e62e6e9?w=800&q=80", authorName: "Pedro Lastra", authorUsername: "peterlaster", downloadLocation: ""),
    ]

    static func searchPhotos(query: String, count: Int = 5) async -> [UnsplashPhoto] {
        guard AppConfig.useRealBackend else {
            // Machine A: return mock photos (real Unsplash image URLs, no API call)
            return Array(mockPhotos.prefix(count))
        }

        let accessKey = AppConfig.unsplashAccessKey
        guard !accessKey.contains("YOUR_") else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.unsplash.com/search/photos")!
        components.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "orientation", value: "landscape"),
            URLQueryItem(name: "per_page", value: String(count)),
        ]

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(UnsplashSearchResponse.self, from: data)
            return response.results.map { result in
                UnsplashPhoto(
                    id: result.id,
                    url: result.urls.regular,
                    authorName: result.user.name,
                    authorUsername: result.user.username,
                    downloadLocation: result.links.downloadLocation
                )
            }
        } catch {
            return []
        }
    }

    static func trackDownload(downloadLocation: String) async {
        guard AppConfig.useRealBackend else { return }  // Machine A: no-op
        let accessKey = AppConfig.unsplashAccessKey
        guard !accessKey.contains("YOUR_"), !downloadLocation.isEmpty else { return }

        guard var components = URLComponents(string: downloadLocation) else { return }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "client_id", value: accessKey)
        ]

        guard let url = components.url else { return }
        _ = try? await URLSession.shared.data(from: url)
    }
}

private struct UnsplashSearchResponse: Decodable {
    let results: [UnsplashResult]

    struct UnsplashResult: Decodable {
        let id: String
        let urls: Urls
        let user: User
        let links: Links

        struct Urls: Decodable {
            let regular: String
        }

        struct User: Decodable {
            let name: String
            let username: String
        }

        struct Links: Decodable {
            let downloadLocation: String

            enum CodingKeys: String, CodingKey {
                case downloadLocation = "download_location"
            }
        }
    }
}

// =============================================================================

