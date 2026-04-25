//
//  TripActivityRemoteChange.swift
//  wayfind
//
//  Phase 3 — Decoded view of a single `trip_activities` row arriving over
//  realtime. The 15-field `meaningfullyChanged` check exists so we can
//  ignore Postgres `UPDATE`s that flip nothing the user can see — e.g.
//  the trigger-driven `updated_at` bump after a no-op write — and avoid
//  paying for a full timeline refetch on every transient ripple.
//

import Foundation

struct TripActivityRemoteChange: Decodable, Hashable, Sendable {
    let id: UUID?
    let tripId: UUID?
    let dayId: UUID?
    let title: String?
    let activityType: String?
    let category: String?
    let startTime: Date?
    let endTime: Date?
    let lat: Double?
    let lng: Double?
    let address: String?
    let placeId: String?
    let sortOrder: Int?
    let notes: String?
    let createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case dayId = "day_id"
        case title
        case activityType = "activity_type"
        case category
        case startTime = "start_time"
        case endTime = "end_time"
        case lat
        case lng
        case address
        case placeId = "place_id"
        case sortOrder = "sort_order"
        case notes
        case createdBy = "created_by"
    }

    /// Returns `true` when at least one of the 15 user-visible fields has
    /// drifted between the OLD and NEW snapshots. Anything that only flipped
    /// `updated_at` (which is NOT in this struct) returns `false` and we
    /// short-circuit the refetch.
    ///
    /// We intentionally compare value-by-value rather than relying on
    /// `Equatable` synthesis so we can keep this list explicit — adding a
    /// new column to the migration without thinking about the realtime cost
    /// should NOT silently start triggering a refetch.
    static func meaningfullyChanged(
        old: TripActivityRemoteChange,
        new: TripActivityRemoteChange
    ) -> Bool {
        if old.dayId != new.dayId { return true }
        if old.title != new.title { return true }
        if old.activityType != new.activityType { return true }
        if old.category != new.category { return true }
        if old.startTime != new.startTime { return true }
        if old.endTime != new.endTime { return true }
        if old.lat != new.lat { return true }
        if old.lng != new.lng { return true }
        if old.address != new.address { return true }
        if old.placeId != new.placeId { return true }
        if old.sortOrder != new.sortOrder { return true }
        if old.notes != new.notes { return true }
        if old.tripId != new.tripId { return true }
        if old.id != new.id { return true }
        if old.createdBy != new.createdBy { return true }
        return false
    }
}


// =============================================================================
