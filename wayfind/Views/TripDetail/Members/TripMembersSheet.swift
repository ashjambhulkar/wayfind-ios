//
//  TripMembersSheet.swift
//  wayfind
//
//  Phase 1 read-only members surface. Sectioned list:
//    1. (Optional) "You're invited" full card if the current user has a
//       pending row on this trip — gives the same gravitas as the
//       `InviteAcceptView` that Phase 2 will introduce.
//    2. Owner row (single).
//    3. Members (accepted editors / viewers).
//    4. Pending invites (only visible to the owner).
//
//  An owner-only state shows a soft empty state with a hero "Invite people"
//  button. The button itself is wired in Phase 2 — Phase 1 just shows the
//  CTA and prints a TODO when tapped, so the hierarchy is in place.
//

import SwiftUI

struct TripMembersSheet: View {
    @Environment(CollaborationStore.self) private var collaborationStore
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss
    let trip: Trip

    @State private var showInviteCompose = false
    @State private var pendingActionInFlight = false

    // Phase 6 management state
    @State private var editAccessMember: TripCollaborator?
    @State private var removeConfirmation: TripCollaborator?
    @State private var leaveConfirmation = false
    @State private var deactivateConfirmation: TripInviteRow?
    /// Set of `stableID`s currently being mutated. Used to disable the
    /// row's Menu and show a brief progress chip so the owner can see
    /// the ask is in flight without blocking other rows.
    @State private var rowMutationsInFlight: Set<String> = []
    @State private var inviteMutationsInFlight: Set<UUID> = []
    @State private var leaveInFlight = false
    @State private var activeInvites: [TripInviteRow] = []
    @State private var activeInvitesLoading = false
    @State private var activeInvitesLoadFailed = false

    var body: some View {
        NavigationStack {
            sheetBody
                .background(AppColors.appBackground)
                .navigationTitle("Members")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Owner-only "+ Invite" entry point. Lives in the
                        // leading slot so it survives across all member-list
                        // states (including the empty state, which has its
                        // own visually richer CTA but where this small
                        // toolbar entry serves as a fallback for VoiceOver
                        // users who'd otherwise have to scroll to find it).
                        if collaborationStore.canManage {
                            Button {
                                HapticManager.light()
                                showInviteCompose = true
                            } label: {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .foregroundStyle(AppColors.appPrimary)
                            }
                            .accessibilityLabel("Invite people")
                            .accessibilityHint("Opens the invite share sheet")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(AppColors.appPrimary)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(AppColors.appPrimary)
        .task {
            await loadActiveInvitesIfNeeded()
        }
        .onChange(of: collaborationStore.canManage) { _, canManage in
            // If the current user just became owner (e.g. ownership transfer
            // in a future release) load the invites; if they were demoted,
            // wipe the cached list so we don't leak it across the gate.
            if canManage {
                Task { await loadActiveInvitesIfNeeded(force: true) }
            } else {
                activeInvites = []
            }
        }
        .sheet(item: $editAccessMember) { member in
            EditAccessSheet(trip: trip, member: member)
        }
        .confirmationDialog(
            removeConfirmation.map { "Remove \($0.resolvedDisplayName) from this trip?" } ?? "",
            isPresented: Binding(
                get: { removeConfirmation != nil },
                set: { if !$0 { removeConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeConfirmation
        ) { member in
            Button("Remove", role: .destructive) {
                HapticManager.warning()
                Task { await removeMember(member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They'll lose access to the plan and bookings. You can re-invite them anytime.")
        }
        .confirmationDialog(
            "Leave \"\(trip.title)\"?",
            isPresented: $leaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave trip", role: .destructive) {
                HapticManager.warning()
                Task { await leaveTrip() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll lose access to the plan, bookings, and updates. The owner can re-invite you anytime.")
        }
        .confirmationDialog(
            "Deactivate invite?",
            isPresented: Binding(
                get: { deactivateConfirmation != nil },
                set: { if !$0 { deactivateConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: deactivateConfirmation
        ) { invite in
            Button("Deactivate", role: .destructive) {
                HapticManager.warning()
                Task { await deactivateInvite(invite) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Anyone with this link will no longer be able to join.")
        }
        .sheet(isPresented: $showInviteCompose) {
            InviteComposeSheet(
                trip: trip,
                onShared: {
                    Task { await loadActiveInvitesIfNeeded(force: true) }
                    // Phase 5 — post-share is the canonical "permission
                    // ask" surface for the *owner*. They've just done
                    // the first collaborative thing on this trip, so
                    // notifying them about replies/edits feels useful
                    // (vs an out-of-context launch ask, which always
                    // gets denied). Only fires the OS prompt the first
                    // time — subsequent shares just acknowledge.
                    if NotificationManager.shared.shouldShowPermissionPrompt {
                        Task {
                            let granted = await NotificationManager.shared.requestPermission()
                            await MainActor.run {
                                if granted {
                                    toastManager.show(ToastData(
                                        message: "Notifications on. We'll let you know when they reply.",
                                        type: .success,
                                        duration: 3
                                    ))
                                }
                            }
                        }
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var sheetBody: some View {
        if case .failed(let message) = collaborationStore.loadState {
            failedState(message: message)
        } else if collaborationStore.members.isEmpty
                    && (collaborationStore.loadState == .loading || collaborationStore.loadState == .idle) {
            loadingState
        } else {
            ScrollView {
                LazyVStack(spacing: AppSpacing.lg, pinnedViews: []) {
                    if let pendingSelf = collaborationStore.pendingSelfMember {
                        pendingSelfHeroCard(member: pendingSelf)
                    }

                    if let owner = collaborationStore.owner {
                        section(title: "Owner") {
                            memberRow(member: owner, showSelfBadge: collaborationStore.isCurrentUserOwner)
                        }
                    }

                    let acceptedOthers = collaborationStore.acceptedCollaborators
                    if acceptedOthers.isEmpty && collaborationStore.canManage {
                        ownerOnlyEmptyState
                    } else if !acceptedOthers.isEmpty {
                        section(title: "Members") {
                            VStack(spacing: AppSpacing.sm) {
                                ForEach(acceptedOthers) { member in
                                    memberRow(
                                        member: member,
                                        showSelfBadge: member.userId == collaborationStore.currentUserId
                                    )
                                }
                            }
                        }
                    }

                    let pendingOthers = collaborationStore.pendingCollaborators
                        .filter { $0.userId != collaborationStore.currentUserId }
                    if !pendingOthers.isEmpty, collaborationStore.canManage {
                        section(title: "Pending") {
                            VStack(spacing: AppSpacing.sm) {
                                ForEach(pendingOthers) { member in
                                    memberRow(member: member, showSelfBadge: false)
                                }
                            }
                        }
                    }

                    if collaborationStore.canManage, !visibleActiveInvites.isEmpty {
                        section(title: "Active invites") {
                            VStack(spacing: AppSpacing.sm) {
                                ForEach(visibleActiveInvites) { invite in
                                    activeInviteRow(invite: invite)
                                }
                            }
                        }
                    }

                    if let selfMember = collaborationStore.selfMember,
                       !collaborationStore.isCurrentUserOwner,
                       selfMember.status == .accepted {
                        leaveTripSection(selfMember: selfMember)
                    }

                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
            }
            .refreshable {
                collaborationStore.refresh()
                await loadActiveInvitesIfNeeded(force: true)
                // Give the in-flight task a brief moment so the spinner
                // doesn't flash off-on-off if the network is fast.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }


    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title.uppercased())
                .font(.appSmall)
                .tracking(1.4)
                .foregroundStyle(AppColors.textTertiary)
                .padding(.horizontal, AppSpacing.xs)

            content()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func memberRow(member: TripCollaborator, showSelfBadge: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.md) {
                AvatarView(
                    displayName: member.resolvedDisplayName,
                    imageURL: member.avatarURL,
                    stableID: member.stableID,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpacing.xs) {
                        Text(member.resolvedDisplayName)
                            .font(.cardTitle)
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                        if member.role == .owner {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColors.appPrimary)
                                .accessibilityHidden(true)
                        }
                        if showSelfBadge {
                            Text("you")
                                .font(.appSmall)
                                .foregroundStyle(AppColors.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(AppColors.appDivider)
                                )
                        }
                    }
                    Text(member.role.verboseLabel)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if rowMutationsInFlight.contains(member.stableID) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColors.appPrimary)
                        .accessibilityLabel("Updating member")
                } else if shouldShowManageMenu(for: member) {
                    manageMenu(for: member)
                }

                if member.status == .pending {
                    Text("Invited")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppColors.appDivider)
                        )
                }
            }

            // Per-surface access scope (Phase 1.5). Owners always have all
            // three surfaces; we omit the row for them to keep their card
            // visually quieter. For collaborators we render the three SF
            // Symbols at full opacity if granted and at 30% opacity if
            // revoked, with a single combined VoiceOver label so a screen
            // reader hears "Documents, Expenses, Notes — Notes access
            // revoked" rather than three separate icons.
            if member.role != .owner {
                accessScopeRow(member: member)
            }
        }
        .padding(.vertical, AppSpacing.sm + 2)
        .padding(.horizontal, AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(for: member, showSelfBadge: showSelfBadge))
    }

    // MARK: - Phase 6 manage menu

    /// True only for the owner viewing an *accepted* non-self, non-owner
    /// collaborator row. Pending invites and the owner's own row don't
    /// surface management actions — pending invites get deactivated via
    /// the active-invites section instead, and demoting the owner is a
    /// future ownership-transfer flow.
    private func shouldShowManageMenu(for member: TripCollaborator) -> Bool {
        guard collaborationStore.canManage else { return false }
        guard member.role != .owner else { return false }
        guard member.status == .accepted else { return false }
        guard member.userId != collaborationStore.currentUserId else { return false }
        return member.id != nil
    }

    @ViewBuilder
    private func manageMenu(for member: TripCollaborator) -> some View {
        Menu {
            // Single role-flip action — show the *opposite* of the
            // current role so the owner picks a destination, not a
            // role-equals-source no-op.
            switch member.role {
            case .editor:
                Button {
                    HapticManager.light()
                    Task { await updateRole(of: member, to: .viewer) }
                } label: {
                    Label("Make Viewer", systemImage: "eye")
                }
            case .viewer:
                Button {
                    HapticManager.light()
                    Task { await updateRole(of: member, to: .editor) }
                } label: {
                    Label("Make Editor", systemImage: "pencil")
                }
            case .owner:
                EmptyView()
            }

            Button {
                HapticManager.light()
                editAccessMember = member
            } label: {
                Label("Edit access", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button(role: .destructive) {
                HapticManager.light()
                removeConfirmation = member
            } label: {
                Label("Remove from trip", systemImage: "person.crop.circle.badge.minus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(member.resolvedDisplayName)")
        .accessibilityHint("Change role, edit access, or remove from this trip")
        .disabled(rowMutationsInFlight.contains(member.stableID))
    }

    // MARK: - Active invites section

    private var visibleActiveInvites: [TripInviteRow] {
        // Already filtered server-side by `is_active = true`; we filter
        // expired client-side too inside CollaboratorService. Keep the
        // computed property even though it's a passthrough so a future
        // search/filter UI can hook in here without touching call sites.
        activeInvites
    }

    @ViewBuilder
    private func activeInviteRow(invite: TripInviteRow) -> some View {
        let mutating = inviteMutationsInFlight.contains(invite.id)
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "link")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.appPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(AppColors.appPrimaryLight))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(invite.roleLabel) invite")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(inviteMetadata(for: invite))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if mutating {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppColors.appPrimary)
                    .accessibilityLabel("Deactivating invite")
            } else {
                Menu {
                    Button(role: .destructive) {
                        HapticManager.light()
                        deactivateConfirmation = invite
                    } label: {
                        Label("Deactivate", systemImage: "link.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for invite")
                .accessibilityHint("Deactivate this invite link")
            }
        }
        .padding(.vertical, AppSpacing.sm + 2)
        .padding(.horizontal, AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(invite.roleLabel) invite, \(inviteMetadata(for: invite))")
    }

    private func inviteMetadata(for invite: TripInviteRow) -> String {
        guard let expiresAt = invite.expiresAt else {
            return "No expiration"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "expires \(formatter.string(from: expiresAt))"
    }

    // MARK: - Leave trip section

    @ViewBuilder
    private func leaveTripSection(selfMember: TripCollaborator) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("YOU".uppercased())
                .font(.appSmall)
                .tracking(1.4)
                .foregroundStyle(AppColors.textTertiary)
                .padding(.horizontal, AppSpacing.xs)

            Button {
                HapticManager.light()
                leaveConfirmation = true
            } label: {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.red.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Leave trip")
                            .font(.cardTitle)
                            .foregroundStyle(.red)
                        Text("You'll lose access to the plan and updates.")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if leaveInFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.red)
                    }
                }
                .padding(.vertical, AppSpacing.sm + 2)
                .padding(.horizontal, AppSpacing.md)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(AppColors.appSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(leaveInFlight)
            .accessibilityLabel("Leave trip")
            .accessibilityHint("Removes you from this trip. The owner can re-invite you anytime.")
        }
    }

    // MARK: - Phase 6 mutations

    private func updateRole(of member: TripCollaborator, to newRole: TripRole) async {
        guard let rowId = member.id else { return }
        guard !rowMutationsInFlight.contains(member.stableID) else { return }
        rowMutationsInFlight.insert(member.stableID)
        defer { rowMutationsInFlight.remove(member.stableID) }

        if AppConfig.useRealBackend {
            do {
                try await CollaboratorService.shared.updateRole(rowId: rowId, role: newRole)
            } catch {
                handleMutationError(error, fallbackMessage: "We couldn't change \(member.resolvedDisplayName)'s role. Try again in a moment.")
                return
            }
        }

        HapticManager.success()
        toastManager.show(ToastData(
            message: "\(member.resolvedDisplayName) is now \(newRole.verboseLabel.lowercased()).",
            type: .success,
            duration: 3
        ))
        await collaborationStore.reloadMembers(tripId: trip.id)
    }

    private func removeMember(_ member: TripCollaborator) async {
        guard let rowId = member.id else { return }
        guard !rowMutationsInFlight.contains(member.stableID) else { return }
        rowMutationsInFlight.insert(member.stableID)
        defer { rowMutationsInFlight.remove(member.stableID) }

        if AppConfig.useRealBackend {
            do {
                try await CollaboratorService.shared.removeCollaborator(rowId: rowId)
            } catch {
                handleMutationError(error, fallbackMessage: "We couldn't remove \(member.resolvedDisplayName). Try again in a moment.")
                return
            }
        }

        HapticManager.success()
        toastManager.show(ToastData(
            message: "Removed \(member.resolvedDisplayName) from the trip.",
            type: .success,
            duration: 3
        ))
        await collaborationStore.reloadMembers(tripId: trip.id)
    }

    private func leaveTrip() async {
        guard let selfMember = collaborationStore.selfMember,
              let rowId = selfMember.id else {
            return
        }
        leaveInFlight = true
        defer { leaveInFlight = false }

        if AppConfig.useRealBackend {
            do {
                try await CollaboratorService.shared.leaveTrip(rowId: rowId)
            } catch {
                HapticManager.warning()
                toastManager.show(ToastData(
                    message: "We couldn't take you off the trip. Try again in a moment.",
                    type: .warning,
                    duration: 3
                ))
                return
            }
        }

        // Owner-side toast comes from realtime DELETE on the host. We
        // dismiss the sheet here; the realtime channel torn down by the
        // host will navigate the user back to the trip list.
        HapticManager.success()
        toastManager.show(ToastData(
            message: "You left \(trip.title).",
            type: .success,
            duration: 3
        ))
        dismiss()
    }

    private func deactivateInvite(_ invite: TripInviteRow) async {
        guard !inviteMutationsInFlight.contains(invite.id) else { return }
        inviteMutationsInFlight.insert(invite.id)
        defer { inviteMutationsInFlight.remove(invite.id) }

        if AppConfig.useRealBackend {
            do {
                try await CollaboratorService.shared.deactivateInvite(inviteId: invite.id)
            } catch {
                handleMutationError(error, fallbackMessage: "We couldn't deactivate this invite. Try again in a moment.")
                return
            }
        }

        HapticManager.success()
        toastManager.show(ToastData(
            message: "Invite deactivated.",
            type: .success,
            duration: 3
        ))
        await loadActiveInvitesIfNeeded(force: true)
    }

    /// Common error path. If the error description hints at a 403 /
    /// permission denial, treat it as the demotion case so the toast
    /// reads correctly and we trigger a refetch — otherwise fall back
    /// to the supplied user-friendly message.
    private func handleMutationError(_ error: Error, fallbackMessage: String) {
        let description = (error as NSError).localizedDescription.lowercased()
        let isPermissionError = description.contains("permission")
            || description.contains("forbidden")
            || description.contains("not authorized")
            || description.contains("403")
            || description.contains("rls")
        HapticManager.warning()
        if isPermissionError {
            toastManager.show(ToastData(
                message: "Your role on this trip changed.",
                type: .warning,
                duration: 3
            ))
            collaborationStore.refresh()
        } else {
            toastManager.show(ToastData(
                message: fallbackMessage,
                type: .warning,
                duration: 3
            ))
        }
    }

    // MARK: - Active invite loading

    private func loadActiveInvitesIfNeeded(force: Bool = false) async {
        guard collaborationStore.canManage else {
            activeInvites = []
            return
        }
        guard AppConfig.useRealBackend else {
            // Mock-mode: no invites to show. Owners still see the empty
            // state in the rest of the sheet — the active-invites
            // section is silently absent.
            activeInvites = []
            return
        }
        if !force, !activeInvites.isEmpty { return }
        if activeInvitesLoading { return }

        activeInvitesLoading = true
        activeInvitesLoadFailed = false
        defer { activeInvitesLoading = false }

        do {
            let rows = try await CollaboratorService.shared.listActiveInvites(tripId: trip.id)
            self.activeInvites = rows
        } catch {
            // Soft-fail: hide the section silently. Owners can pull-to-
            // refresh to retry, and a successful invite share will
            // trigger another load on close of InviteCompose.
            activeInvitesLoadFailed = true
            self.activeInvites = []
        }
    }

    /// Three SF Symbol chips telling the viewer which of the per-surface
    /// areas this member can see. When the backend ships the columns
    /// (Phase 1.5 backend dependency) the values flip from always-on to
    /// the actual `can_access_*` flags. Today the iOS model defaults to
    /// `true` for every flag so this row reads "all three granted" until
    /// the migration lands.
    @ViewBuilder
    private func accessScopeRow(member: TripCollaborator) -> some View {
        HStack(spacing: AppSpacing.sm) {
            scopeChip(symbol: "doc.text", granted: member.canAccessDocuments)
            scopeChip(symbol: "dollarsign.circle", granted: member.canAccessExpenses)
            scopeChip(symbol: "note.text", granted: member.canAccessNotes)
            Spacer(minLength: 0)
        }
        .padding(.leading, 40 + AppSpacing.md) // align with text column past the avatar
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scopeAccessibilityLabel(for: member))
    }

    private func scopeChip(symbol: String, granted: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.appPrimary.opacity(granted ? 1.0 : 0.3))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(AppColors.appPrimary.opacity(granted ? 0.12 : 0.04))
            )
    }

    private func scopeAccessibilityLabel(for member: TripCollaborator) -> String {
        var revoked: [String] = []
        if !member.canAccessDocuments { revoked.append("Documents") }
        if !member.canAccessExpenses { revoked.append("Expenses") }
        if !member.canAccessNotes { revoked.append("Notes") }
        if revoked.isEmpty {
            return "Documents, Expenses, Notes — all granted"
        }
        let revokedList = revoked.joined(separator: ", ")
        return "Documents, Expenses, Notes — \(revokedList) access revoked"
    }

    private func rowAccessibilityLabel(for member: TripCollaborator, showSelfBadge: Bool) -> String {
        var pieces: [String] = [member.resolvedDisplayName, member.role.verboseLabel]
        if showSelfBadge { pieces.append("you") }
        if member.status == .pending { pieces.append("invited, not yet joined") }
        return pieces.joined(separator: ", ")
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            ProgressView()
                .tint(AppColors.appPrimary)
            Text("Loading members…")
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.textTertiary)
            Text(message)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                collaborationStore.refresh()
            } label: {
                Text("Try again")
                    .font(.appButton)
                    .foregroundStyle(AppColors.appPrimary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ownerOnlyEmptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.appPrimary.opacity(0.6))
            Text("Travel together")
                .font(.cardTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text("Invite friends and family to plan, view, or edit this trip.")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppSpacing.lg)

            Button {
                HapticManager.light()
                showInviteCompose = true
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "person.crop.circle.badge.plus")
                    Text("Invite people")
                }
                .font(.appButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(AppColors.appPrimary)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, AppSpacing.sm)
            .accessibilityHint("Opens the invite share sheet")
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
        .padding(.bottom, AppSpacing.lg)
    }

    @ViewBuilder
    private func pendingSelfHeroCard(member: TripCollaborator) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(AppColors.appPrimaryLight)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're invited")
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("\(collaborationStore.owner?.resolvedDisplayName ?? "The owner") added you as \(member.role.verboseLabel.lowercased()).")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: AppSpacing.sm) {
                Button {
                    HapticManager.light()
                    Task { await declinePendingSelf() }
                } label: {
                    Text("Maybe later")
                        .font(.appButton)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(AppColors.appSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .strokeBorder(AppColors.appDivider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(pendingActionInFlight)
                Button {
                    HapticManager.medium()
                    Task { await acceptPendingSelf() }
                } label: {
                    HStack {
                        if pendingActionInFlight {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Text("Accept")
                                .font(.appButton)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(AppColors.appPrimary)
                    )
                }
                .buttonStyle(.plain)
                .disabled(pendingActionInFlight)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(AppColors.appPrimaryLight.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appPrimary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Pending self actions

    private func acceptPendingSelf() async {
        pendingActionInFlight = true
        defer { pendingActionInFlight = false }
        do {
            _ = try await InviteService.shared.acceptPendingCollaborator(tripId: trip.id)
            HapticManager.success()
            collaborationStore.refresh()
            toastManager.show(ToastData(
                message: "You're in! Welcome to \(trip.title).",
                type: .success,
                duration: 3
            ))
        } catch let error as InviteError {
            HapticManager.warning()
            toastManager.show(ToastData(
                message: pendingErrorCopy(for: error),
                type: .warning,
                duration: 3
            ))
        } catch {
            HapticManager.warning()
            toastManager.show(ToastData(
                message: "We couldn't join you to this trip. Try again in a moment.",
                type: .warning,
                duration: 3
            ))
        }
    }

    private func declinePendingSelf() async {
        pendingActionInFlight = true
        defer { pendingActionInFlight = false }
        do {
            try await InviteService.shared.declinePendingCollaborator(tripId: trip.id)
            HapticManager.light()
            // Dismiss the sheet — there's nothing left for them to do
            // here, and the trip itself disappears from their list once
            // realtime catches up.
            dismiss()
        } catch {
            HapticManager.warning()
            toastManager.show(ToastData(
                message: "We couldn't decline the invite. Try again in a moment.",
                type: .warning,
                duration: 3
            ))
        }
    }

    private func pendingErrorCopy(for error: InviteError) -> String {
        switch error {
        case .alreadyMember: return "You're already on this trip!"
        case .alreadyOwner: return "You created this trip — open it from your trips list."
        case .tripFull: return "This trip is full. Ask the owner to remove someone first."
        case .invalidOrExpired: return "This invite is no longer valid."
        case .notFound: return "We couldn't find that invite."
        case .notAuthenticated: return "Sign in again and try."
        case .unknownServerError(let raw): return raw
        case .transport(let m): return m
        }
    }
}


// =============================================================================
