//
//  ActivityLogEntry.swift
//  wayfind
//
//  Phase 4 — Decoded view of one row in `trip_activity_log`. The action
//  enum mirrors the SQL CHECK constraint plus a forward-compat `unknown`
//  case so a new server-side action doesn't crash the iOS feed before
//  we ship the matching client.
//
//  Copy guideline (verb-rich): we intentionally render description text
//  here rather than in the row view so the same description is reused
//  by the future push-notification body without diverging from the feed.
//

import Foundation

struct ActivityLogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let userId: UUID
    let action: Action
    let entityType: String?
    let entityId: UUID?
    let entityName: String?
    let metadata: [String: String]?
    let createdAt: Date

    /// Resolved name for the actor — set by the store after a batched
    /// `profiles` lookup. May be `nil` for actors whose profile we
    /// couldn't fetch (RLS race / orphaned auth user).
    var actorDisplayName: String?

    enum Action: String, Hashable, Sendable {
        case activityAdded = "activity_added"
        case activityUpdated = "activity_updated"
        case activityDeleted = "activity_deleted"
        case bookingAdded = "booking_added"
        case bookingUpdated = "booking_updated"
        case bookingDeleted = "booking_deleted"
        case noteAdded = "note_added"
        case noteUpdated = "note_updated"
        case checklistAdded = "checklist_added"
        case checklistItemToggled = "checklist_item_toggled"
        case dayReordered = "day_reordered"
        case collaboratorJoined = "collaborator_joined"
        case collaboratorLeft = "collaborator_left"
        case collaboratorRoleChanged = "collaborator_role_changed"
        case tripUpdated = "trip_updated"
        /// Phase 1.5 forward-compat — backend trigger to be added in a
        /// follow-up migration. Renders cleanly today; just no rows yet.
        case collaboratorAccessChanged = "collaborator_access_changed"
        case unknown = ""

        static func from(rawValue raw: String?) -> Action {
            guard let raw, !raw.isEmpty else { return .unknown }
            return Action(rawValue: raw) ?? .unknown
        }

        /// SF Symbol shown at the leading edge of each row at 60% opacity.
        /// Picked to read at-a-glance when scanning the feed — round
        /// `plus.circle` for adds, single `pencil` for edits, `trash` for
        /// deletes, etc.
        var systemImage: String {
            switch self {
            case .activityAdded, .bookingAdded, .noteAdded, .checklistAdded:
                return "plus.circle"
            case .activityUpdated, .bookingUpdated, .noteUpdated, .tripUpdated:
                return "pencil"
            case .activityDeleted, .bookingDeleted:
                return "trash"
            case .checklistItemToggled:
                return "checkmark.circle"
            case .dayReordered:
                return "arrow.left.arrow.right"
            case .collaboratorJoined:
                return "person.crop.circle.badge.plus"
            case .collaboratorLeft:
                return "person.crop.circle.badge.minus"
            case .collaboratorRoleChanged:
                return "person.crop.circle.badge.questionmark"
            case .collaboratorAccessChanged:
                return "lock.shield"
            case .unknown:
                return "circle"
            }
        }
    }

    /// Verb-rich one-liner. Always begins with the actor name so the row
    /// reads like a sentence: "Alex added Eiffel Tower". Uses lowercase
    /// nouns ("trip", "booking") per the copy guidelines.
    var description: String {
        let actor = displayActor
        let name = entityName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (name?.isEmpty == false ? name! : nil)
        switch action {
        case .activityAdded:
            return "\(actor) added \(safeName ?? "a stop")"
        case .activityUpdated:
            return "\(actor) updated \(safeName ?? "a stop")"
        case .activityDeleted:
            return "\(actor) removed \(safeName ?? "a stop")"
        case .bookingAdded:
            return "\(actor) added a booking — \(safeName ?? "Booking")"
        case .bookingUpdated:
            return "\(actor) updated \(safeName ?? "a booking")"
        case .bookingDeleted:
            return "\(actor) removed \(safeName ?? "a booking")"
        case .noteAdded:
            return "\(actor) added a note"
        case .noteUpdated:
            return "\(actor) updated a note"
        case .checklistAdded:
            return "\(actor) added a checklist"
        case .checklistItemToggled:
            return "\(actor) checked off an item"
        case .dayReordered:
            return "\(actor) reordered the days"
        case .collaboratorJoined:
            return "\(actor) joined the trip"
        case .collaboratorLeft:
            return "\(actor) left the trip"
        case .collaboratorRoleChanged:
            return collaboratorRoleChangedDescription(actor: actor)
        case .collaboratorAccessChanged:
            return collaboratorAccessChangedDescription(actor: actor)
        case .tripUpdated:
            return "\(actor) updated the trip"
        case .unknown:
            return "\(actor) made a change"
        }
    }

    private var displayActor: String {
        guard let trimmed = actorDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return "Someone" }
        return trimmed
    }

    private func collaboratorRoleChangedDescription(actor: String) -> String {
        let from = metadata?["from_role"]
        let to = metadata?["to_role"]
        switch (from, to) {
        case (_, "editor"):
            return "\(actor) made someone an editor"
        case (_, "viewer"):
            return "\(actor) changed someone to view-only"
        default:
            return "\(actor) updated someone's role"
        }
    }

    private func collaboratorAccessChangedDescription(actor: String) -> String {
        // Future-compat: when the backend trigger ships, metadata will
        // carry `surface` ("documents" / "expenses" / "notes") and
        // `granted` ("true" / "false"). Until then the generic copy is
        // perfectly readable.
        if let surface = metadata?["surface"]?.lowercased(),
           let granted = metadata?["granted"] {
            let verb = (granted == "true") ? "granted" : "removed"
            return "\(actor) \(verb) someone's access to \(surface)"
        }
        return "\(actor) updated someone's access"
    }

    /// Day bucket for the section header in the activity sheet.
    /// Returns "Today", "Yesterday", or a localized short date.
    func dayBucketLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(createdAt) { return "Today" }
        if calendar.isDateInYesterday(createdAt) { return "Yesterday" }
        return Self.dateFormatter.string(from: createdAt)
    }

    /// Stable hashable bucket key for grouping (we group by start-of-day).
    func dayBucketKey(calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}


// =============================================================================
