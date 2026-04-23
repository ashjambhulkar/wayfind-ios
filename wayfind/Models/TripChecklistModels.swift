import Foundation

/// Built-in checklist tabs — matches `trip_checklists.template_key` (Expo `CHECKLIST_TEMPLATE_KEYS`).
enum TripChecklistTemplateKey: String, CaseIterable, Sendable {
    case packing
    case todo
    case documents
    case general

    var tabLabel: String {
        switch self {
        case .packing: return "Packing"
        case .todo: return "To-Do"
        case .documents: return "Documents"
        case .general: return "General"
        }
    }

    static func sortIndex(forTemplateKey key: String?) -> Int {
        guard let key, let k = Self(rawValue: key) else { return 99 }
        return Self.allCases.firstIndex(of: k) ?? 99
    }
}

struct TripChecklistWithItems: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let templateKey: String?
    let title: String
    let sortOrder: Int
    var items: [TripChecklistItem]
}

struct TripChecklistItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let checklistId: UUID
    var title: String
    var isDone: Bool
    let sortOrder: Int
}
