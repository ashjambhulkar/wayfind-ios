//
//  InvitePreview.swift
//  wayfind
//
//  Lightweight preview of a trip invite, returned by `get_invite_preview`.
//  This is the *only* data the recipient sees before they decide to join,
//  so we deliberately keep it small — trip name, dates, destination, role,
//  cover image, and inviter name. No collaborator list, no activities, no
//  bookings.
//
//  The RPC is callable by `anon` (see migration line 254–255) so the
//  signed-out invite preview path works without a session. Once the user
//  signs in and accepts, `accept_invite` surfaces their full collaborator
//  row via the regular CollaborationStore fetch.
//

import Foundation

struct InvitePreview: Hashable, Sendable {
    let tripId: UUID
    let role: TripRole
    let tripName: String
    let coverImageURLString: String?
    let startDate: Date?
    let endDate: Date?
    let destination: String?
    let inviterName: String?

    var coverImageURL: URL? {
        guard let coverImageURLString, !coverImageURLString.isEmpty else { return nil }
        return URL(string: coverImageURLString)
    }

    /// Best-effort label for the inviter row on `InviteAcceptView`. Falls
    /// back to "Someone" when the inviter profile is private or deleted.
    var resolvedInviterName: String {
        if let name = inviterName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Someone"
    }
}


// =============================================================================
