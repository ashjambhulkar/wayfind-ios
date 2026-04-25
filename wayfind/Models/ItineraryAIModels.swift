import Foundation

// MARK: - Enums

enum PlanPace: String, CaseIterable, Identifiable, Codable {
    case relaxed, balanced, packed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .balanced: return "Balanced"
        case .packed: return "Packed"
        }
    }
    var icon: String {
        switch self {
        case .relaxed: return "leaf"
        case .balanced: return "scale.3d"
        case .packed: return "bolt"
        }
    }
}

enum ExplorationScope: String, CaseIterable, Identifiable, Codable {
    case walkable
    case city_wide
    case spread_out
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .walkable: return "Walkable"
        case .city_wide: return "City-wide"
        case .spread_out: return "Spread out"
        }
    }
    var icon: String {
        switch self {
        case .walkable: return "figure.walk"
        case .city_wide: return "map"
        case .spread_out: return "car"
        }
    }
}

// MARK: - Request

struct PlanDayParams {
    var dayId: UUID
    var date: Date
    var destination: String
    var interests: [String] = []
    var pace: PlanPace = .balanced
    var stopCountMin: Int = 3
    var stopCountMax: Int = 6
    var timeStart: String = "09:00"
    var timeEnd: String = "21:00"
    var includeMeals: Bool = true
    var stayAreaLabel: String
    var stayAreaPlaceId: String
    var explorationScope: ExplorationScope = .city_wide
    var travelStyle: String? = nil
    var excludePlaces: [String] = []
}

// MARK: - Network Layer DTOs

struct PlanDayRequestBody: Encodable {
    let trip_id: String
    let action: String = "plan_day"
    let day_id: String
    let date: String
    let destination: String
    var interests: [String]
    var pace: String
    var stop_count_min: Int
    var stop_count_max: Int
    var time_start: String
    var time_end: String
    var include_meals: Bool
    var stay_area_label: String
    var stay_area_place_id: String
    var exploration_scope: String
    var travel_style: String?
    var preview_only: Bool = true
    var exclude_places: [String]
}

struct ApplyPlanDayOpsRequestBody: Encodable {
    let trip_id: String
    let action: String = "apply_plan_day_ops"
    let itinerary_ops: [ItineraryOp]
}

// MARK: - Response

struct PlanDayPreviewResponse: Decodable {
    var summary: String
    var story_title: String?
    var story_subtitle: String?
    var story_arc: [String]?
    var preview_only: Bool?
    var itinerary_ops: [ItineraryOp]?
    var applied_ops: Int?
    var activity_names: [String]?
    var display_timezone: String?
    var usage_feature: String?
}

struct ItineraryOp: Codable {
    var action: String
    var id: String?
    var row: ItineraryOpRow?
}

struct ItineraryOpRow: Codable {
    var day_id: String?
    var name: String?
    var description: String?
    var category: String?
    var starts_at: String?
    var duration_minutes: Int?
    var latitude: Double?
    var longitude: Double?
    var address: String?
    var place_id: String?
    var place_search_query: String?
    var hero_image_url: String?
    var phase_label: String?
    var moment_line: String?
    var tips: [String]?
    var sort_order: Int?
    var meal_anchor: Bool?
    var rating: Double?
    var price_level: Int?
    var travel_from_previous_minutes: Int?
    var directions_url: String?
    var travel_mode: String?
    var estimated_cost: Double?
    var currency: String?
}

// MARK: - Display Card (parsed from ops for preview UI)

struct ActivityPreviewCard: Identifiable {
    let id: UUID
    let name: String
    let description: String?
    let category: String?
    let startsAt: String?
    let durationMinutes: Int?
    let heroImageUrl: String?
    let phaseLabel: String?
    let momentLine: String?
    let tips: [String]
    let latitude: Double?
    let longitude: Double?
    let placeId: String?
    let rating: Double?
    let priceLevel: Int?
    let travelFromPreviousMinutes: Int?

    init(from row: ItineraryOpRow) {
        self.id = UUID()
        self.name = row.name ?? "Stop"
        self.description = row.description
        self.category = row.category
        self.startsAt = row.starts_at
        self.durationMinutes = row.duration_minutes
        self.heroImageUrl = row.hero_image_url
        self.phaseLabel = row.phase_label
        self.momentLine = row.moment_line
        self.tips = row.tips ?? []
        self.latitude = row.latitude
        self.longitude = row.longitude
        self.placeId = row.place_id
        self.rating = row.rating
        self.priceLevel = row.price_level
        self.travelFromPreviousMinutes = row.travel_from_previous_minutes
    }
}

// MARK: - AI Error

enum ItineraryAIError: LocalizedError {
    case noSession
    case missingPlaceId
    case serverError(String)
    case quotaExceeded
    case planFailed(String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "Sign in to use AI planning."
        case .missingPlaceId:
            return "Trip destination is missing location data. Try editing the trip and re-selecting the destination."
        case .serverError(let msg):
            return msg
        case .quotaExceeded:
            return "You've reached your monthly AI planning limit. Upgrade to plan more days."
        case .planFailed(let msg):
            return "Couldn't generate a plan. \(msg)"
        case .decodingError(let msg):
            return "Unexpected response from server: \(msg)"
        }
    }
}


// =============================================================================
