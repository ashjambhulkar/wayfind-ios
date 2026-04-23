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
    static func searchPhotos(query: String, count: Int = 5) async -> [UnsplashPhoto] {
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
