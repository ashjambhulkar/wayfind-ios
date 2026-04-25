//
//  CollaborativeAttributionPill.swift
//  wayfind
//
//  Phase 3 — "Alex · just now" / "Alex · added now" inline pill rendered in
//  the metadata row of a `TimelinePlaceCardView` when the card was just
//  touched by another collaborator over realtime. Replaces the Slack-style
//  green border that pushed layout around — this version reserves no
//  vertical space when there's no flash and uses the brand-warm primary
//  color so it reads as friendly attribution rather than a status chip.
//
//  Visual: 16pt avatar + verb-rich label, separated by a middle dot. Sized
//  identically to the other subtitle parts (font.appCaption) so it slots
//  in cleanly next to "★ 4.6 · $$ · Cocktail bar".
//

import SwiftUI

struct CollaborativeAttributionPill: View {
    let actorDisplayName: String
    let actorUserId: UUID?
    let kind: TripCollaborationUiStore.ChangeKind

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            AvatarView(
                displayName: actorDisplayName,
                imageURL: nil,
                stableID: actorUserId?.uuidString ?? actorDisplayName,
                size: 16,
                showRing: false
            )
            Text(label)
                .font(.appCaption)
                .foregroundStyle(AppColors.appPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch kind {
        case .new: return "\(actorDisplayName) added"
        case .updated: return "\(actorDisplayName) edited"
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .new: return "\(actorDisplayName) just added this stop"
        case .updated: return "\(actorDisplayName) just edited this stop"
        }
    }
}


// =============================================================================
