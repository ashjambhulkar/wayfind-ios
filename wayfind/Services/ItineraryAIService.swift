import Foundation
import Supabase

/// Network service for the `itinerary-ai` Supabase Edge Function.
///
/// Two-step flow:
/// 1. `planDay(tripId:params:)` — generates a preview with `preview_only: true`.
/// 2. `applyOps(tripId:ops:)` — commits the preview ops via `apply_plan_day_ops`.
struct ItineraryAIService {

    private static let functionName = "itinerary-ai"

    // MARK: - Plan Day (preview)

    func planDay(tripId: UUID, params: PlanDayParams) async throws -> PlanDayPreviewResponse {
        // IMPORTANT: Use the same formatter the SupabaseManager used to parse
        // `trip_days.date` so the round-trip is symmetric. The edge function
        // does a strict YYYY-MM-DD string match against `trip_days.date`,
        // so any TZ drift here surfaces as
        // "plan_day: day_id or date does not match a trip day in range".
        let dateString = SupabaseModelMapping.calendarDateOnlyString(from: params.date)
        // Edge function does a strict `d.id === body.day_id` JS string compare
        // against rows from Postgres. Postgres returns UUIDs lowercase, but
        // Swift's `UUID.uuidString` is uppercase, so we MUST lowercase here
        // or every comparison fails as
        // "plan_day: day_id or date does not match a trip day in range".
        let tripIdString = tripId.uuidString.lowercased()
        let dayIdString = params.dayId.uuidString.lowercased()

        #if DEBUG
        print("[itinerary-ai] plan_day → trip_id=\(tripIdString) day_id=\(dayIdString) date=\(dateString)")
        #endif

        let body = PlanDayRequestBody(
            trip_id: tripIdString,
            day_id: dayIdString,
            date: dateString,
            destination: params.destination,
            interests: params.interests,
            pace: params.pace.rawValue,
            stop_count_min: params.stopCountMin,
            stop_count_max: params.stopCountMax,
            time_start: params.timeStart,
            time_end: params.timeEnd,
            include_meals: params.includeMeals,
            stay_area_label: params.stayAreaLabel,
            stay_area_place_id: params.stayAreaPlaceId,
            exploration_scope: params.explorationScope.rawValue,
            travel_style: params.travelStyle,
            preview_only: true,
            exclude_places: params.excludePlaces
        )

        let data = try await invoke(body: body)
        return try decodeOrThrow(data)
    }

    // MARK: - Apply Ops

    func applyOps(tripId: UUID, ops: [ItineraryOp]) async throws {
        // Lowercase to match Postgres UUID casing — see planDay comment.
        let body = ApplyPlanDayOpsRequestBody(
            trip_id: tripId.uuidString.lowercased(),
            itinerary_ops: ops
        )
        let data = try await invoke(body: body)

        // Check for error field in the response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorMsg = json["error"] as? String {
            throw ItineraryAIError.serverError(errorMsg)
        }
    }

    // MARK: - Private Helpers

    private func bearerToken() async throws -> String {
        guard let client = AuthSessionService.shared.client else {
            throw ItineraryAIError.noSession
        }
        let session = try await client.auth.session
        return session.accessToken
    }

    /// Performs the POST and, on a single 401, calls `auth.refreshSession()` and
    /// retries once with the new bearer — mirrors the Expo `getSessionBearerToken`
    /// retry path so plans don't fail just because the access token rotated mid-call.
    private func invoke(body: some Encodable, alreadyRetried: Bool = false) async throws -> Data {
        let token = try await bearerToken()

        let url = URL(string: "\(AppConfig.supabaseURL)/functions/v1/\(Self.functionName)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 90

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200, 201:
                break
            case 401, 403:
                if !alreadyRetried, let client = AuthSessionService.shared.client {
                    _ = try? await client.auth.refreshSession()
                    return try await invoke(body: body, alreadyRetried: true)
                }
                throw ItineraryAIError.noSession
            case 422:
                let msg = extractErrorMessage(from: data) ?? "Could not generate a plan. Try adjusting parameters."
                throw ItineraryAIError.planFailed(msg)
            case 429:
                // Wave 4.4b: a 429 can mean either of two things now —
                // (a) free user hit the monthly cap → upsell paywall,
                // (b) ANY user hit the per-day safety cap → "try
                // tomorrow" message, no paywall.
                // Distinguish by the `error` field in the body.
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (json["error"] as? String) == "daily_safety_cap_reached"
                {
                    throw ItineraryAIError.dailySafetyCapReached
                }
                throw ItineraryAIError.quotaExceeded
            default:
                let msg = extractErrorMessage(from: data) ?? "Server error \(http.statusCode)"
                throw ItineraryAIError.serverError(msg)
            }
        }

        return data
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String ?? json["detail"] as? String
    }

    private func decodeOrThrow<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            // Check for error before decoding the expected type
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["error"] as? String {
                throw ItineraryAIError.serverError(errorMsg)
            }
            return try decoder.decode(T.self, from: data)
        } catch let aiError as ItineraryAIError {
            throw aiError
        } catch {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            throw ItineraryAIError.decodingError("\(error.localizedDescription) — \(preview)")
        }
    }
}


// =============================================================================
