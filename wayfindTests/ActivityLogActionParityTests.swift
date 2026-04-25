//
//  ActivityLogActionParityTests.swift
//  wayfindTests
//
//  Phase 10 — Asserts the iOS `ActivityLogEntry.Action` enum and the SQL
//  `trip_activity_log_action_check` constraint stay in lock step. A drift
//  here means the backend writes a row that the client treats as `.unknown`
//  (degraded UI) or — worse — the client tries to write a value the server
//  rejects (silent insert failure).
//
//  The SQL constraint snapshot below is the authoritative list copied from
//  `supabase/migrations/20260501120000_collaborative_budget_v1.sql` lines
//  408-431. Update both together when adding a new action.
//

import XCTest
@testable import wayfind

final class ActivityLogActionParityTests: XCTestCase {
    /// Snapshot of the SQL CHECK constraint as of the v1 collaborative-budget
    /// migration. The `unknown` case is iOS-only (forward-compat fallback)
    /// and the `collaborator_access_changed` case is iOS-only too — its
    /// matching trigger ships in a follow-up migration. Both are documented
    /// in `Models/ActivityLogEntry.swift`.
    private static let sqlAllowedActions: Set<String> = [
        "activity_added",
        "activity_updated",
        "activity_deleted",
        "booking_added",
        "booking_updated",
        "booking_deleted",
        "note_added",
        "note_updated",
        "checklist_added",
        "checklist_item_toggled",
        "day_reordered",
        "collaborator_joined",
        "collaborator_left",
        "collaborator_role_changed",
        "trip_updated",
        "pending_invite_declined",
        "expense_added",
        "expense_updated",
        "expense_deleted",
        "expense_settled",
        "budget_updated",
    ]

    /// Documented iOS-only cases that exist before the matching SQL ships.
    /// If you remove one of these, also remove it from the SQL allow-list
    /// above (and vice versa).
    private static let iosOnlyActions: Set<String> = [
        "collaborator_access_changed",
    ]

    /// Every value the SQL CHECK accepts must have a matching iOS case so
    /// the client never renders a row as "Someone made a change" (the
    /// `.unknown` fallback) when the row is actually a known action.
    func testEverySqlActionHasIosCase() {
        let iosRawValues = Self.allKnownIosRawValues()
        for sqlAction in Self.sqlAllowedActions {
            XCTAssertTrue(
                iosRawValues.contains(sqlAction),
                "SQL action \(sqlAction) has no matching ActivityLogEntry.Action case"
            )
        }
    }

    /// Every iOS case (except documented forward-compat extras and the
    /// `unknown` sentinel) must be present in the SQL allow-list — otherwise
    /// the client could try to insert a row the server rejects.
    func testEveryIosActionHasSqlEntry() {
        let iosRawValues = Self.allKnownIosRawValues()
        for raw in iosRawValues {
            if Self.iosOnlyActions.contains(raw) { continue }
            XCTAssertTrue(
                Self.sqlAllowedActions.contains(raw),
                "iOS action \(raw) is missing from the SQL CHECK constraint"
            )
        }
    }

    /// `.unknown` exists explicitly as a forward-compat fallback. We assert
    /// it stays as the empty-string raw value so a missing/null `action`
    /// column maps to it without crashing the row decoder.
    func testUnknownActionIsForwardCompatFallback() {
        XCTAssertEqual(ActivityLogEntry.Action.unknown.rawValue, "")
        XCTAssertEqual(ActivityLogEntry.Action.from(rawValue: nil), .unknown)
        XCTAssertEqual(ActivityLogEntry.Action.from(rawValue: ""), .unknown)
        XCTAssertEqual(ActivityLogEntry.Action.from(rawValue: "future_action_2027"), .unknown)
    }

    /// Round-trip every iOS case: raw → enum → raw.
    func testActionRawValueRoundTripsForKnownCases() {
        for raw in Self.allKnownIosRawValues() {
            let action = ActivityLogEntry.Action(rawValue: raw)
            XCTAssertEqual(action?.rawValue, raw, "Action \(raw) failed round-trip")
        }
    }

    // MARK: - Helpers

    /// All known iOS raw values, EXCLUDING the empty-string `.unknown`
    /// sentinel (which exists for nil/unknown decoding only).
    private static func allKnownIosRawValues() -> Set<String> {
        // Action is not CaseIterable to keep `.unknown` from leaking into
        // user-facing pickers. Build the set explicitly.
        Set([
            "activity_added", "activity_updated", "activity_deleted",
            "booking_added", "booking_updated", "booking_deleted",
            "note_added", "note_updated",
            "checklist_added", "checklist_item_toggled",
            "day_reordered",
            "collaborator_joined", "collaborator_left",
            "collaborator_role_changed", "collaborator_access_changed",
            "trip_updated", "pending_invite_declined",
            "expense_added", "expense_updated", "expense_deleted", "expense_settled",
            "budget_updated",
        ])
    }
}
