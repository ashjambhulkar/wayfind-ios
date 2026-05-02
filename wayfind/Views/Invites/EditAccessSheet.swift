//
//  EditAccessSheet.swift
//  wayfind
//
//  Phase 6 — owner-only sheet for editing the per-surface access flags
//  of an existing collaborator. Reuses the same plain-language copy as
//  `InviteComposeSheet` so a member's "what can they see?" UX feels
//  consistent across invite-time and after-the-fact edits.
//
//  Save is disabled until at least one toggle has changed, so a no-op
//  open-then-close pattern doesn't fire a network call. Save calls
//  `CollaboratorService.updateAccessFlags` which patches all three
//  flags in a single UPDATE so the realtime layer fires one event.
//
//  Accessibility:
//   - The header avatar carries a combined VoiceOver label so the
//     screen reader hears "Customize access for Alex Mitchell" once.
//   - Toggles include their own subtitles via `.accessibilityHint`.
//   - Reduce Motion has no special behavior here — the only animation
//     is the standard sheet present/dismiss which the system handles.
//
//  Mock-mode: `AppConfig.useRealBackend == false` short-circuits the
//  save call and just closes the sheet with the success toast — the
//  store has no listener to update so the optimistic UI is the only
//  visible change.
//

import SwiftUI

struct EditAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastManager.self) private var toastManager
    @Environment(CollaborationStore.self) private var collaborationStore

    let trip: Trip
    let member: TripCollaborator

    @State private var canAccessDocuments: Bool
    @State private var canAccessExpenses: Bool
    @State private var canAccessNotes: Bool
    @State private var saveInFlight = false
    @State private var errorBanner: String?

    init(trip: Trip, member: TripCollaborator) {
        self.trip = trip
        self.member = member
        _canAccessDocuments = State(initialValue: member.canAccessDocuments)
        _canAccessExpenses = State(initialValue: member.canAccessExpenses)
        _canAccessNotes = State(initialValue: member.canAccessNotes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headerCard
                    togglesCard
                    if let errorBanner {
                        errorBannerView(errorBanner)
                    }
                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)
            }
            .background(AppColors.appBackground)
            .navigationTitle("Edit access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppColors.textSecondary)
                        .disabled(saveInFlight)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saveInFlight {
                            ProgressView()
                                .tint(AppColors.appPrimary)
                        } else {
                            Text("Save")
                                .font(.appButton)
                                .foregroundStyle(saveDisabled ? AppColors.textTertiary : AppColors.appPrimary)
                        }
                    }
                    .disabled(saveDisabled || saveInFlight)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .tint(AppColors.appPrimary)
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: AppSpacing.md) {
            AvatarView(
                displayName: member.resolvedDisplayName,
                imageURL: member.avatarURL,
                stableID: member.stableID,
                size: 48
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize access for \(member.resolvedDisplayName)")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(member.role.verboseLabel)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Customize access for \(member.resolvedDisplayName), \(member.role.verboseLabel)")
    }

    // MARK: - Toggles

    private var togglesCard: some View {
        VStack(spacing: AppSpacing.sm) {
            accessToggleRow(
                title: "Documents",
                subtitle: "Tickets, reservations, and uploads",
                isOn: $canAccessDocuments
            )
            Divider().background(AppColors.appDivider)
            accessToggleRow(
                title: "Expenses",
                subtitle: "Trip budget and per-stop costs",
                isOn: $canAccessExpenses
            )
            Divider().background(AppColors.appDivider)
            accessToggleRow(
                title: "Notes",
                subtitle: "Free-form planning notes",
                isOn: $canAccessNotes
            )
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
    }

    private func accessToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(AppColors.appPrimary)
            .accessibilityHint(subtitle)
            if !isOn.wrappedValue {
                Text("They won't see this section in the trip.")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.leading, 2)
            }
        }
    }

    private func errorBannerView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.appCaption)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: - Save

    private var hasChanges: Bool {
        canAccessDocuments != member.canAccessDocuments
            || canAccessExpenses != member.canAccessExpenses
            || canAccessNotes != member.canAccessNotes
    }

    private var saveDisabled: Bool {
        !hasChanges
    }

    private func save() async {
        guard let rowId = member.id else {
            errorBanner = "We can't update access for this member yet."
            return
        }
        saveInFlight = true
        errorBanner = nil
        defer { saveInFlight = false }

        if AppConfig.useRealBackend {
            do {
                try await CollaboratorService.shared.updateAccessFlags(
                    rowId: rowId,
                    canAccessDocuments: canAccessDocuments,
                    canAccessExpenses: canAccessExpenses,
                    canAccessNotes: canAccessNotes
                )
            } catch {
                HapticManager.warning()
                errorBanner = "We couldn't update access. Try again in a moment."
                return
            }
        }

        HapticManager.light()
        toastManager.show(ToastData(
            message: "Updated access for \(member.resolvedDisplayName).",
            type: .success,
            duration: 3
        ))
        // Realtime UPDATE on `trip_collaborators` will refetch the store
        // automatically — but we kick off a refresh defensively in case
        // realtime is degraded so the members sheet reflects the new
        // chips immediately.
        await collaborationStore.reloadMembers(tripId: trip.id)
        dismiss()
    }
}


// =============================================================================
