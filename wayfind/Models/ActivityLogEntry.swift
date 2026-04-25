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
        case pendingInviteDeclined = "pending_invite_declined"
        // Budget v1
        case expenseAdded = "expense_added"
        case expenseUpdated = "expense_updated"
        case expenseDeleted = "expense_deleted"
        case expenseSettled = "expense_settled"
        case budgetUpdated = "budget_updated"
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
            case .activityAdded, .bookingAdded, .noteAdded, .checklistAdded, .expenseAdded:
                return "plus.circle"
            case .activityUpdated, .bookingUpdated, .noteUpdated, .tripUpdated, .expenseUpdated:
                return "pencil"
            case .activityDeleted, .bookingDeleted, .expenseDeleted:
                return "trash"
            case .checklistItemToggled:
                return "checkmark.circle"
            case .dayReordered:
                return "arrow.left.arrow.right"
            case .collaboratorJoined:
                return "person.crop.circle.badge.plus"
            case .collaboratorLeft, .pendingInviteDeclined:
                return "person.crop.circle.badge.minus"
            case .collaboratorRoleChanged:
                return "person.crop.circle.badge.questionmark"
            case .collaboratorAccessChanged:
                return "lock.shield"
            case .expenseSettled:
                return "checkmark.seal"
            case .budgetUpdated:
                return "creditcard"
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
        case .pendingInviteDeclined:
            return "\(actor) declined the invite"
        case .expenseAdded:
            return expenseAddedDescription(actor: actor, name: safeName)
        case .expenseUpdated:
            return "\(actor) updated \(safeName ?? "an expense")"
        case .expenseDeleted:
            return "\(actor) removed \(safeName ?? "an expense")"
        case .expenseSettled:
            return expenseSettledDescription(actor: actor)
        case .budgetUpdated:
            return budgetUpdatedDescription(actor: actor)
        case .unknown:
            return "\(actor) made a change"
        }
    }

    /// "Alex added a $42 dinner expense" — the amount + category if available,
    /// falling back to the entity name. Auto-synced rows read more naturally
    /// as "Alex added a booking — Hotel Indigo (auto-tracked)" to set the
    /// expectation that this is the booking integration, not a manual entry.
    private func expenseAddedDescription(actor: String, name: String?) -> String {
        let amount = formattedMetadataAmount()
        let category = metadata?["category"].flatMap { ExpenseCategory(rawValue: $0)?.displayLabel.lowercased() }
        let auto = (metadata?["auto"] == "true")
        if auto, let name {
            return "\(actor) added a tracked expense — \(name)"
        }
        if let amount, let category {
            return "\(actor) added a \(amount) \(category) expense"
        }
        if let amount {
            return "\(actor) added a \(amount) expense"
        }
        return "\(actor) added \(name ?? "an expense")"
    }

    private func expenseSettledDescription(actor: String) -> String {
        let amount = formattedMetadataAmount()
        if let amount {
            return "\(actor) settled \(amount)"
        }
        return "\(actor) settled up"
    }

    private func budgetUpdatedDescription(actor: String) -> String {
        if let scope = metadata?["scope"], scope == "trip_total" {
            return "\(actor) updated the trip budget"
        }
        if let category = metadata?["category"].flatMap({ ExpenseCategory(rawValue: $0)?.displayLabel.lowercased() }) {
            return "\(actor) updated the \(category) budget"
        }
        return "\(actor) updated a budget"
    }

    /// Build a "$42.00" string from the trigger metadata. The trigger writes
    /// amounts as `numeric::text` so we round-trip through `Decimal` to keep
    /// trailing-zero formatting consistent with the rest of the app.
    private func formattedMetadataAmount() -> String? {
        guard let raw = metadata?["amount"], let value = Decimal(string: raw) else {
            return nil
        }
        let code = metadata?["currency"] ?? "USD"
        return value.formatted(.currency(code: code))
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
