//
//  PlaceIdBridgeService.swift
//  wayfind
//
//  Phase C.3 of the Places cost-reduction & owned-data plan.
//
//  Bridges Apple MapKit hits (name + lat/lng with NO place_id) to a Google
//  place_id by calling the `lookup-place-id` Edge Function. Invoked only on
//  *commit-intent* (e.g. user taps "Add to trip" on a MapKit search result),
//  never on hover/selection — every call we make has a Google quota cost
//  budgeted against it (cheapest case is free; worst case is one Text Search
//  Essentials request).
//
//  UX contract:
//    • No spinner. Returning a `Resolution` is fast (median ~150ms tier 1/2,
//      ~700ms tier 3). Caller can show a tiny inline shimmer if it wants.
//    • `Resolution.ambiguous` → caller presents a half-sheet chooser.
//    • `Resolution.miss`      → caller falls back to "save as Apple-only" UX
//      (the row keeps its Apple coordinate but no Google enrichment).
//

import Auth
import Foundation
import Supabase

@MainActor
@Observable
final class PlaceIdBridgeService {

    // MARK: - Public API

    /// Single, ambiguous, or miss outcome for an Apple→Google resolution.
    enum Resolution: Equatable {
        case single(Candidate)
        case ambiguous([Candidate])
        case miss
    }

    /// One resolved candidate returned from the bridge function. Confidence
    /// is on a 0–1 scale; a `.single` is anything ≥ 0.85, `.ambiguous`
    /// returns the top 1–3 with confidence in [0.5, 0.85).
    struct Candidate: Identifiable, Hashable {
        let placeId: String
        let name: String
        let lat: Double
        let lng: Double
        let confidence: Double
        let source: Source

        var id: String { placeId }
    }

    enum Source: String, Codable, Hashable {
        case cityPlaces = "city_places"
        case bridge = "place_id_bridge"
        case googleTextSearch = "google_text_search"

        var displayLabel: String {
            switch self {
            case .cityPlaces: return "Wayfind"
            case .bridge: return "Wayfind cache"
            case .googleTextSearch: return "Google"
            }
        }
    }

    enum BridgeError: LocalizedError {
        case noSession
        case rateLimited(retryAfterMs: Int)
        case server(String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .noSession: return "Not signed in"
            case .rateLimited: return "Too many lookups — try again in a minute"
            case .server(let m): return m
            case .transport(let e): return e.localizedDescription
            }
        }
    }

    /// Resolve a MapKit hit to a Google `place_id`.
    ///
    /// - Parameters:
    ///   - name: Display title of the MapKit suggestion (we send this to the
    ///     bridge for fuzzy match — Apple often spells things differently
    ///     from Google so this MUST be the user-visible title, not a
    ///     lowercased slug).
    ///   - lat / lng: Apple's coordinate (10–50m off Google is normal; the
    ///     server uses 75m radius for "single" and 250m for "ambiguous").
    ///   - cityProfileId: Optional scope hint. When known, the server prefers
    ///     same-city candidates over distant homonyms (e.g. multiple "Joe's
    ///     Coffee" worldwide).
    func resolve(
        name: String,
        lat: Double,
        lng: Double,
        cityProfileId: UUID? = nil
    ) async throws -> Resolution {
        guard let token = await bearerToken() else { throw BridgeError.noSession }

        let signpost = PlatformUsageTelemetry.begin(.lookupPlaceIdEdge)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.lookupPlaceIdEdge, id: signpost, status: outcome) }

        let url = URL(string: "\(AppConfig.supabaseURL)/functions/v1/lookup-place-id")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.timeoutInterval = 8

        let body = RequestBody(
            name: name,
            lat: lat,
            lng: lng,
            city_profile_id: cityProfileId?.uuidString.lowercased()
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw BridgeError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.server("Invalid response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw BridgeError.noSession
        case 429:
            outcome = .rateLimited
            let retry = (try? JSONDecoder().decode(RateLimitedResponse.self, from: data))?
                .retry_after_ms ?? 60_000
            throw BridgeError.rateLimited(retryAfterMs: retry)
        default:
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                ?? "lookup-place-id failed (\(http.statusCode))"
            throw BridgeError.server(msg)
        }

        let payload = try JSONDecoder().decode(ResponseBody.self, from: data)
        let candidates = payload.candidates.map(\.toCandidate)
        switch payload.resolution {
        case "single":
            outcome = .ok
            if let first = candidates.first { return .single(first) }
            return .miss
        case "ambiguous":
            outcome = candidates.isEmpty ? .empty : .ok
            return candidates.isEmpty ? .miss : .ambiguous(candidates)
        default:
            outcome = .empty
            return .miss
        }
    }

    // MARK: - Private

    private func bearerToken() async -> String? {
        guard let client = AuthSessionService.shared.client else { return nil }
        return try? await client.auth.session.accessToken
    }

    // MARK: - Wire format

    private struct RequestBody: Encodable {
        let name: String
        let lat: Double
        let lng: Double
        let city_profile_id: String?
    }

    private struct ResponseBody: Decodable {
        let resolution: String
        let candidates: [APICandidate]
    }

    private struct APICandidate: Decodable {
        let place_id: String
        let name: String
        let lat: Double
        let lng: Double
        let confidence: Double
        let source: String

        var toCandidate: Candidate {
            Candidate(
                placeId: place_id,
                name: name,
                lat: lat,
                lng: lng,
                confidence: confidence,
                source: Source(rawValue: source) ?? .googleTextSearch
            )
        }
    }

    private struct RateLimitedResponse: Decodable {
        let retry_after_ms: Int
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }
}
