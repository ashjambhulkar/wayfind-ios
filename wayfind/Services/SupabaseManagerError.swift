import Foundation

enum SupabaseManagerError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidDateRange
    case cannotShrinkTripDayHasActivities(date: String)
    case tripNotFound
    case invalidCoverImageData

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured."
        case .notAuthenticated:
            return "You must be signed in."
        case .invalidDateRange:
            return "End date must be on or after start date."
        case .cannotShrinkTripDayHasActivities(let date):
            return "Move or remove activities from \(date) before shrinking the trip, or pick dates that include that day."
        case .tripNotFound:
            return "Trip could not be found."
        case .invalidCoverImageData:
            return "That image could not be uploaded. Try another photo."
        }
    }
}


// =============================================================================

