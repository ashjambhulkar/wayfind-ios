//
//  TripMembersAvatarStack.swift
//  wayfind
//
//  Overlapping collaborator avatars beside the trip Invite control. Avatars
//  show accepted collaborators only (not the owner). Tap-to-open-members
//  is handled by `TripMembersInviteButton`; set `allowsTap` to false so the
//  stack is display-only.
//

import SwiftUI

struct TripMembersAvatarStack: View {
    @Environment(CollaborationStore.self) private var collaborationStore
    let onTap: () -> Void
    /// High-contrast styling for overlapping avatars on the trip hero (dark scrim / photo).
    var heroOnPhoto: Bool = false
    /// When false, avatars are not a button (Invite opens the members sheet).
    var allowsTap: Bool = true

    private let displayLimit = 3
    private let avatarSize: CGFloat = 26
    private let overlap: CGFloat = 9

    var body: some View {
        if allowsTap {
            Button {
                HapticManager.selection()
                onTap()
            } label: {
                avatarStrip
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(String(localized: "Opens trip members"))
        } else {
            avatarStrip
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - Subviews

    private var avatarStrip: some View {
        HStack(spacing: 0) {
            stackedAvatars
            if let chip = overflowChipText {
                overflowChip(text: chip)
                    .padding(.leading, AppSpacing.xs + 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stackedAvatars: some View {
        let visible = visibleMembers
        if visible.isEmpty {
            Circle()
                .strokeBorder(heroOnPhoto ? Color.white.opacity(0.5) : AppColors.appDivider, lineWidth: 1.2)
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    Image(systemName: "person.2.fill")
                        .font(.system(size: avatarSize * 0.4, weight: .medium))
                        .foregroundStyle(heroOnPhoto ? Color.white.opacity(0.85) : AppColors.textTertiary)
                )
        } else {
            ZStack(alignment: .leading) {
                ForEach(Array(visible.enumerated()), id: \.element.stableID) { index, member in
                    AvatarView(
                        displayName: member.resolvedDisplayName,
                        imageURL: member.avatarURL,
                        stableID: member.stableID,
                        size: avatarSize,
                        showRing: true,
                        ringStrokeColor: heroOnPhoto ? Color.white.opacity(0.92) : nil
                    )
                    .offset(x: CGFloat(index) * (avatarSize - overlap))
                    .zIndex(Double(visible.count - index))
                }
            }
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
            .foregroundStyle(heroOnPhoto ? Color.white : AppColors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(heroOnPhoto ? Color.white.opacity(0.22) : AppColors.appDivider)
            )
    }

    // MARK: - Derived

    /// Accepted collaborators only (excludes trip owner).
    private var rankedMembers: [TripCollaborator] {
        collaborationStore.acceptedCollaborators
    }

    private var visibleMembers: [TripCollaborator] {
        Array(rankedMembers.prefix(displayLimit))
    }

    private var overflowChipText: String? {
        let extra = rankedMembers.count - displayLimit
        return extra > 0 ? "+\(extra)" : nil
    }

    private var accessibilityLabel: String {
        let n = rankedMembers.count
        if n == 0 {
            return String(localized: "No collaborators yet")
        }
        if n == 1 {
            return String(localized: "One collaborator")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld collaborators"),
            n
        )
    }
}

// MARK: - Invite → members sheet

/// Opens `TripMembersSheet` (bottom sheet). Placed to the right of collaborator avatars.
struct TripMembersInviteButton: View {
    var heroOnPhoto: Bool
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.light()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                Text(String(localized: "Invite"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(heroOnPhoto ? Color.white : AppColors.appPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(shareBackground)
            .overlay(shareStroke)
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Invite"))
        .accessibilityHint(String(localized: "Opens trip members and invite options"))
    }

    private var shareBackground: some View {
        Group {
            if heroOnPhoto {
                Color.white.opacity(0.24)
            } else {
                AppColors.appPrimaryLight
            }
        }
    }

    private var shareStroke: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                heroOnPhoto ? Color.white.opacity(0.38) : AppColors.appDivider,
                lineWidth: 0.5
            )
    }
}


// =============================================================================
