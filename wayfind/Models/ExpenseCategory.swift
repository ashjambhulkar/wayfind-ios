//
//  ExpenseCategory.swift
//  wayfind
//
//  Single source of truth for the eight expense categories the budget UI
//  understands. Mirrors the `trip_budgets.category` CHECK constraint so we
//  never write a value the database will reject (round-tripped via the
//  forward-compat `from(rawValue:)` initialiser).
//
//  Each case carries its own SF Symbol, accent color, and display label so
//  the category grid, expense rows, and category sections all read from a
//  single table. The grid order matches the display order chosen during the
//  UX review (transport-heavy categories first, then food, then "soft"
//  travel categories, then a catch-all).
//

import SwiftUI

enum ExpenseCategory: String, CaseIterable, Hashable, Sendable, Identifiable {
    case flight
    case lodging
    case car
    case food
    case transport
    case activities
    case shopping
    case other

    var id: String { rawValue }

    /// Human-readable label shown on chips, rows, and section headers. Avoids
    /// "Other" sounding like a fall-back by using "Misc" — readers parse it
    /// as "miscellaneous" without thinking.
    var displayLabel: String {
        switch self {
        case .flight: return "Flights"
        case .lodging: return "Lodging"
        case .car: return "Car"
        case .food: return "Food"
        case .transport: return "Transport"
        case .activities: return "Activities"
        case .shopping: return "Shopping"
        case .other: return "Misc"
        }
    }

    /// SF Symbol shown in the 28-pt category badge / 56-pt grid tile.
    var systemImage: String {
        switch self {
        case .flight: return "airplane"
        case .lodging: return "bed.double.fill"
        case .car: return "car.fill"
        case .food: return "fork.knife"
        case .transport: return "tram.fill"
        case .activities: return "sparkles"
        case .shopping: return "bag.fill"
        case .other: return "circle.grid.2x2.fill"
        }
    }

    /// Accent tint used for the category tile, the row badge, and the
    /// per-category progress bar fill. Drawn from the existing AppColors
    /// vocabulary so a future theme swap in `AppTheme.swift` flows here too.
    var accentColor: Color {
        switch self {
        case .flight: return Color.blue
        case .lodging: return Color.indigo
        case .car: return Color.orange
        case .food: return Color.red
        case .transport: return Color.teal
        case .activities: return Color.purple
        case .shopping: return Color.pink
        case .other: return Color.gray
        }
    }

    /// Forward-compat parse — unknown values fall back to `.other` so a new
    /// category added on the backend (e.g. "insurance") doesn't crash a stale
    /// build before iOS catches up.
    static func from(rawValue raw: String?) -> ExpenseCategory {
        guard let raw, let match = ExpenseCategory(rawValue: raw.lowercased()) else {
            return .other
        }
        return match
    }

    /// Map a `trip_bookings.kind` value (or the iOS BookingCategory raw value)
    /// to the matching expense category. Mirrors `tg_sync_booking_expense` in
    /// the SQL trigger so a unit test can assert iOS + SQL agree.
    static func fromBookingKind(_ kind: String?) -> ExpenseCategory {
        guard let normalised = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalised.isEmpty
        else { return .other }
        switch normalised {
        case "flight", "flights", "airline":
            return .flight
        case "hotel", "lodging", "accommodation", "hotels":
            return .lodging
        case "car", "carrental", "car_rental":
            return .car
        case "restaurant", "food", "dining":
            return .food
        case "train", "bus", "ferry", "cruise", "transport", "transit":
            return .transport
        case "concert", "theater", "tour", "activity", "activities":
            return .activities
        case "shopping":
            return .shopping
        default:
            return .other
        }
    }
}


// =============================================================================
