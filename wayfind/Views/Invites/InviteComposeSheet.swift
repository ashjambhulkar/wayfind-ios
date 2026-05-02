//
//  InviteComposeSheet.swift
//  wayfind
//
//  Phase 2 — owner-facing sheet for creating a fresh invite link and
//  handing it off to the system share sheet via `ShareLink`. Replaces
//  the inert "Coming soon" empty-state CTA from the Phase 1 members
//  sheet.
//
//  Layout (per UX review):
//    • Two detents: `.medium` default, drag to `.large` reveals expanded
//      Customize Access toggles inline.
//    • Recipient-POV preview card at the top — shows the trip cover,
//      title, dates, and the recipient's role tag, so the owner can
//      see exactly what their friend will receive.
//    • Role CARDS (not picker chips) for Editor / Viewer with one-line
//      descriptions — chips compress to two characters at the smallest
//      Dynamic Type sizes, and "E"/"V" is meaningless. Cards reflow.
//    • "Customize access" disclosure row, COLLAPSED by default for the
//      common all-on case. Expanded reveals three toggles for Documents,
//      Expenses, Notes — each with a soft caption that updates when
//      toggled off ("They won't see this section in the trip").
//    • Primary CTA is a `ShareLink` with a `SharePreview` so Messages
//      / Mail / Slack render a rich card with the trip cover, not a
//      bare URL. Light haptic fires on share complete.
//
//  Permission prompt: after the first successful share *of this app
//  session*, the parent fires the push permission flow (UX review note —
//  ask once we know notifications will be useful, not on launch).
//

import SwiftUI
import UIKit

struct InviteComposeSheet: View {
    let trip: Trip
    /// Called once the owner actually shares the invite. Parent uses this
    /// to refresh active invites and drive the push permission prompt.
    let onShared: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastManager.self) private var toastManager

    @State private var selectedRole: TripRole = .editor
    @State private var canAccessDocuments = true
    @State private var canAccessExpenses = true
    @State private var canAccessNotes = true
    @State private var customizeExpanded = false

    @State private var inviteState: InviteState = .idle
    @State private var sharePayload: InviteSharePayload?

    private enum InviteState: Equatable {
        case idle
        case creating
        case failed(message: String)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    previewCard
                    roleSection
                    customizeAccessSection
                    Spacer().frame(height: AppSpacing.xl)
                }
                .padding(AppSpacing.lg)
            }
            .background(AppColors.appBackground.ignoresSafeArea())
            .navigationTitle("Invite to trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        HapticManager.light()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ctaBar
            }
            .sheet(item: $sharePayload) { payload in
                InviteActivitySheet(payload: payload) { completed in
                    Task { @MainActor in
                        if completed {
                            HapticManager.light()
                            onShared()
                        } else {
                            try? await CollaboratorService.shared.deactivateInvite(inviteId: payload.invite.id)
                        }
                        sharePayload = nil
                    }
                }
            }
        }
    }

    // MARK: - Preview card

    private var previewCard: some View {
        HStack(spacing: AppSpacing.md) {
            coverThumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text("They'll see")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
                Text(trip.title)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                if let formatted = formattedDateRange() {
                    Text(formatted)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(selectedRole.displayLabel)
                .font(.appSmall)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(AppColors.appPrimaryLight)
                )
                .foregroundStyle(AppColors.appPrimary)
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview. \(trip.title), \(formattedDateRange() ?? ""). Role: \(selectedRole.displayLabel).")
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: AppColors.appPrimaryLight
                case .success(let img): img.resizable().scaledToFill()
                case .failure: AppColors.appPrimaryLight
                @unknown default: AppColors.appPrimaryLight
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                .fill(AppColors.appPrimaryLight)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "map")
                        .foregroundStyle(AppColors.appPrimary)
                )
        }
    }

    // MARK: - Role cards

    private var roleSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Their role")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
            VStack(spacing: AppSpacing.sm) {
                roleCard(
                    role: .editor,
                    title: "Editor",
                    description: "Can add, change, and remove stops, bookings, and notes."
                )
                roleCard(
                    role: .viewer,
                    title: "Viewer",
                    description: "Can see everything, but can't change anything."
                )
            }
        }
    }

    @ViewBuilder
    private func roleCard(role: TripRole, title: String, description: String) -> some View {
        let selected = selectedRole == role
        Button {
            HapticManager.selection()
            withAnimation(.easeInOut(duration: 0.15)) { selectedRole = role }
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AppColors.appPrimary : AppColors.textTertiary)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(description)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
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
                    .strokeBorder(selected ? AppColors.appPrimary : AppColors.appDivider, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) — \(description)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Customize access

    private var customizeAccessSection: some View {
        DisclosureGroup(isExpanded: $customizeExpanded) {
            VStack(spacing: AppSpacing.sm) {
                accessToggleRow(
                    title: "Documents",
                    subtitle: "Tickets, reservations, and uploads",
                    isOn: $canAccessDocuments
                )
                accessToggleRow(
                    title: "Expenses",
                    subtitle: "Trip budget and per-stop costs",
                    isOn: $canAccessExpenses
                )
                accessToggleRow(
                    title: "Notes",
                    subtitle: "Free-form planning notes",
                    isOn: $canAccessNotes
                )
            }
            .padding(.top, AppSpacing.sm)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(AppColors.appPrimary)
                Text("Customize access")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
                Text(accessSummary)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .tint(AppColors.appPrimary)
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
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
            if !isOn.wrappedValue {
                Text("They won't see this section in the trip.")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.leading, 2)
            }
        }
    }

    private var accessSummary: String {
        let on = [canAccessDocuments, canAccessExpenses, canAccessNotes].filter { $0 }.count
        if on == 3 { return "All on" }
        return "\(on) of 3"
    }

    // MARK: - CTA bar

    private var ctaBar: some View {
        VStack(spacing: AppSpacing.sm) {
            switch inviteState {
            case .idle:
                Button {
                    Task { await createAndPresentInvite() }
                } label: {
                    Text("Share invite link")
                        .font(.appButton)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(AppColors.appPrimary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share invite link")
                .accessibilityHint("Creates a link and opens the system share sheet")
            case .creating:
                Button {
                } label: {
                    HStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Preparing link…")
                            .font(.appButton)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(AppColors.appPrimary.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .disabled(true)
            case .failed(let message):
                VStack(spacing: AppSpacing.xs) {
                    Text(message)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.appError)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await createAndPresentInvite() }
                    } label: {
                        Text("Try again")
                            .font(.appButton)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                    .fill(AppColors.appPrimary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(.ultraThinMaterial)
    }

    // MARK: - Invite creation

    private func createAndPresentInvite() async {
        if case .creating = inviteState { return }
        inviteState = .creating
        let role = selectedRole
        let documents = canAccessDocuments
        let expenses = canAccessExpenses
        let notes = canAccessNotes
        do {
            let invite = try await InviteService.shared.createInvite(
                tripId: trip.id,
                role: role,
                canAccessDocuments: documents,
                canAccessExpenses: expenses,
                canAccessNotes: notes
            )
            guard let url = InviteDeepLink.shareableURL(for: invite.token) else {
                try? await CollaboratorService.shared.deactivateInvite(inviteId: invite.id)
                inviteState = .failed(message: "We couldn't build the share link. Try again.")
                return
            }
            inviteState = .idle
            sharePayload = InviteSharePayload(
                invite: invite,
                url: url,
                subject: "Wayfind trip: \(trip.title)",
                message: "Join my trip on Wayfind: \(trip.title)"
            )
        } catch SupabaseManagerError.notAuthenticated {
            inviteState = .failed(message: "Sign in again to invite people.")
        } catch {
            inviteState = .failed(message: "We couldn't create the invite. Check your connection and try again.")
        }
    }

    private func formattedDateRange() -> String? {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: trip.startDate, to: trip.endDate)
    }
}

private struct InviteSharePayload: Identifiable {
    var id: UUID { invite.id }
    let invite: TripInvite
    let url: URL
    let subject: String
    let message: String
}

private struct InviteActivitySheet: UIViewControllerRepresentable {
    let payload: InviteSharePayload
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [payload.message, payload.url],
            applicationActivities: nil
        )
        controller.setValue(payload.subject, forKey: "subject")
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


// =============================================================================
