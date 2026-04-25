//
//  PlacePhotoModels.swift
//  wayfind
//
//  Phase F.5 — UI models for the user-photo carousel + fullscreen viewer.
//
//  These are deliberately lightweight value types — the network layer hands
//  back a flat list, the carousel renders it, the viewer pages through it.
//  Anything richer (status lifecycle, EXIF, attribution) lives in the
//  database row that backs each entry.
//

import Foundation

/// One photo eligible for display in the carousel + fullscreen viewer.
///
/// `kind` is what drives the badge / gating logic in the gallery. Pending
/// items are visible to the uploader (so they can see "still under
/// review") but never to anonymous viewers.
struct PlacePhoto: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// Promoted user photo (status='approved'). Public, served from
        /// the place-photos-public bucket.
        case approvedUser
        /// Pending user photo from the *current* uploader (status =
        /// pending_moderation / pending_review). Visible only to the
        /// uploader; tagged "Awaiting review" in the UI.
        case pendingUser
        /// Google-sourced fallback (city_places.images / thumbnail_url
        /// when image_source != 'user').
        case providerFallback
    }

    let id: String
    let url: URL
    let kind: Kind
    let attribution: String?
    /// Photographer / uploader display name when known. Used as the
    /// secondary line on the attribution chip; nil for provider photos
    /// where we credit the source globally instead.
    let credit: String?
}

/// Phase F.7 — one entry from `place_user_photo_events`. Surfaces the
/// outcome of the moderation pipeline back to the uploader so we can
/// honour DSA Article 17 (Statement of Reasons) inside the app even
/// when push delivery fails.
struct PhotoLifecycleEvent: Identifiable, Hashable, Sendable {
    let id: Int64
    let photoId: UUID
    let status: String
    let reason: String?
    let detail: String?
    let createdAt: Date

    /// Display-friendly verdict label. Kept here so both notification
    /// surfaces and the in-app inbox stay in sync.
    var headline: String {
        switch status {
        case "approved": return "Your photo is live"
        case "rejected": return "Your photo wasn't approved"
        case "pending_review": return "Your photo needs another look"
        case "reported": return "Your photo was flagged"
        case "removed": return "Your photo was removed"
        default: return "Photo update"
        }
    }
}

