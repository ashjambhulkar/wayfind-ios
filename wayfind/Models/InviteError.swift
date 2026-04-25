//
//  InviteError.swift
//  wayfind
//
//  Typed errors surfaced by `InviteService.acceptInvite` and friends. The
//  `accept_invite` and `accept_pending_collaborator` RPCs both return HTTP
//  200 with `{"error": "..."}` on failure (see migration
//  20260410120000_collaboration_stage1_foundation.sql line 270, 283, 289,
//  299, 309) — the Swift wrapper parses the body and maps the documented
//  error strings to these cases. Any unrecognised error string falls
//  through to `.unknownServerError(String)` so we never silently swallow
//  a backend change.
//
//  The UI maps each case to conversational copy per the UX review (Phase 2
//  notes, items #16 / #17): error toasts lead with what the user can do,
//  not "rpc failed". See `InviteAcceptView.errorMessage(for:)`.
//

import Foundation

enum InviteError: Error, Equatable, Hashable, Sendable {
    /// Returned when no invite row matches the token. Distinct from
    /// `.invalidOrExpired` so the UI can suggest a different fix
    /// ("ask Alex to send a new one" vs "the link looks malformed").
    case notFound

    /// Token exists but the row is inactive, past `expires_at`, or has
    /// hit `max_uses`.
    case invalidOrExpired

    /// The current user already owns this trip — cannot accept an invite
    /// to a trip they themselves created. Backend message:
    /// `"You already own this trip"`.
    case alreadyOwner

    /// The current user is already an accepted collaborator on this trip.
    /// UI maps this to a friendly "You're already on this trip!" with a
    /// CTA to open it.
    case alreadyMember

    /// Trip has hit the 25-collaborator cap. Backend message:
    /// `"This trip has reached the collaborator limit"`.
    case tripFull

    /// The caller isn't signed in. The `accept_invite` RPC requires an
    /// authenticated session — surfaced when the iOS layer calls it
    /// before signing in (defensive — we should never actually reach
    /// this state because the UI gates the call behind auth).
    case notAuthenticated

    /// Anything else — the server returned an error string we don't yet
    /// recognise. Carries the raw string so logs are useful and the UI
    /// can show it as a fallback.
    case unknownServerError(String)

    /// HTTP / network layer failed before the RPC could even run.
    case transport(message: String)

    /// Map a server error string (the value in `{"error": "..."}`) to a
    /// typed case. Substring matching keeps us forward-compatible with
    /// minor backend wording tweaks.
    static func fromServerErrorString(_ raw: String) -> InviteError {
        let lower = raw.lowercased()
        if lower.contains("not found") { return .notFound }
        if lower.contains("invalid") || lower.contains("expired") { return .invalidOrExpired }
        if lower.contains("already own") { return .alreadyOwner }
        if lower.contains("already a collaborator") || lower.contains("already a member") {
            return .alreadyMember
        }
        if lower.contains("collaborator limit") || lower.contains("trip is full") {
            return .tripFull
        }
        return .unknownServerError(raw)
    }
}


// =============================================================================
