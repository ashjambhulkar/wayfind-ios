import Foundation

struct TripNote: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let userId: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
}
