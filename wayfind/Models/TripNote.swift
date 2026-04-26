import Foundation

struct TripNote: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let userId: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date

    /// True when the note has no meaningful title or body (list + cleanup).
    var isVisuallyEmpty: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty && b.isEmpty
    }
}


// =============================================================================

