//
//  TripMembersAvatarStack.swift
//  wayfind
//
//  Canonical entry point to the trip members surface. Lives in the trailing
//  toolbar slot of `TripDetailView` next to the existing ellipsis menu.
//
//  Per the UX review: "Members" must NOT live behind the kebab — that surface
//  is the social signal of the trip. Showing 1–3 overlapping avatars + a
//  numeric overflow chip ("+4") is both discoverable and self-explaining.
//
//  Tap → opens `TripMembersSheet` (medium detent by default).
//

import SwiftUI

struct TripMembersAvatarStack: View {
    @Environment(CollaborationStore.self) private var collaborationStore
    let onTap: () -> Void

    private let displayLimit = 3
    private let avatarSize: CGFloat = 26
    private let overlap: CGFloat = 9

    var body: some View {
        Button {
            HapticManager.selection()
            onTap()
        } label: {
            HStack(spacing: 0) {
                stackedAvatars
                if let chip = overflowChipText {
                    overflowChip(text: chip)
                        .padding(.leading, AppSpacing.xs + 2)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens trip members")
    }

    // MARK: - Subviews

    @ViewBuilder
    private var stackedAvatars: some View {
        let visible = visibleMembers
        if visible.isEmpty {
            // Loading or owner-only edge: render a single placeholder
            // outline so the toolbar doesn't reflow when data lands.
            Circle()
                .strokeBorder(AppColors.appDivider, lineWidth: 1.2)
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: avatarSize * 0.45, weight: .medium))
                        .foregroundStyle(AppColors.textTertiary)
                )
        } else {
            ZStack(alignment: .leading) {
                ForEach(Array(visible.enumerated()), id: \.element.stableID) { index, member in
                    AvatarView(
                        displayName: member.resolvedDisplayName,
                        imageURL: member.avatarURL,
                        stableID: member.stableID,
                        size: avatarSize,
                        showRing: true
                    )
                    .offset(x: CGFloat(index) * (avatarSize - overlap))
                    .zIndex(Double(visible.count - index))
                }
            }
            // Width must account for the offset stack so SwiftUI lays it out
            // correctly inside the toolbar HStack.
            .frame(
                width: avatarSize + CGFloat(max(visible.count - 1, 0)) * (avatarSize - overlap),
                height: avatarSize,
                alignment: .leading
            )
        }
    }

    private func overflowChip(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(AppColors.appDivider)
            )
    }

    // MARK: - Derived

    private var rankedMembers: [TripCollaborator] {
        // Owner first, then accepted collaborators in insertion order. We
        // intentionally exclude pending rows from the toolbar avatar stack
        // because they're not yet "on the trip" socially; they show inside
        // the members sheet under a "Pending" section.
        var ordered: [TripCollaborator] = []
        if let owner = collaborationStore.owner {
            ordered.append(owner)
        }
        ordered.append(contentsOf: collaborationStore.acceptedCollaborators)
        return ordered
    }

    private var visibleMembers: [TripCollaborator] {
        Array(rankedMembers.prefix(displayLimit))
    }

    private var overflowChipText: String? {
        let extra = rankedMembers.count - displayLimit
        return extra > 0 ? "+\(extra)" : nil
    }

    private var accessibilityLabel: String {
        let count = collaborationStore.totalAcceptedMemberCount
        if count <= 1 { return "Trip members, you only" }
        return "Trip members, \(count) people"
    }
}


// =============================================================================
