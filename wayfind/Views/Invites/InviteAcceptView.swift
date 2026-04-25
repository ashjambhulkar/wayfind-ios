//
//  InviteAcceptView.swift
//  wayfind
//
//  Phase 2 — recipient-facing invite landing screen. Presented as a
//  `.fullScreenCover` (NOT a sheet) so it commands full attention, in
//  line with the UX review's note that join-a-trip is a high-stakes
//  decision deserving of full-bleed treatment (not the small-detent
//  sheet feel of "review this menu").
//
//  Lifecycle:
//
//   1. Presented when `wayfindApp.swift` receives a deep link via
//      `onOpenURL` and `InviteDeepLink.token(from:)` returns non-nil,
//      OR when the post-auth drain replays a token from
//      `PendingInviteStorage`.
//
//   2. On appear we call `InviteService.fetchInvitePreview(token:)`.
//      During the fetch we show `SkeletonView` placeholders that match
//      the eventual layout — title, dates, inviter row, bullets — so
//      the layout doesn't reflow.
//
//   3. On success we render the trip cover with a legibility gradient
//      and the recipient-POV preview card.
//
//   4. Tap "Join trip":
//      • Signed-in: call `acceptInvite`, on success dismiss + navigate
//        + present `InviteeWelcomeSheet`.
//      • Signed-out: persist token to `PendingInviteStorage` and route
//        to the sign-in flow. The post-auth drain re-presents this view
//        and we'll be in the signed-in branch.
//
//   5. Tap "Maybe later": dismiss + clear pending storage.
//
//  Errors map to conversational copy (`errorMessage(for:)`) rather than
//  raw strings, per the UX review's tone guidance.
//

import SwiftUI

struct InviteAcceptView: View {
    let token: String
    /// Called when the user successfully joins — root view uses this to
    /// dismiss the cover, navigate to the trip, and present the
    /// `InviteeWelcomeSheet`.
    let onJoinSuccess: (UUID, InvitePreview) -> Void
    /// Called when the user taps Maybe Later or the X — root view should
    /// dismiss the cover and clear `PendingInviteStorage`.
    let onDismiss: () -> Void
    /// Whether the user is currently signed in. Drives the sign-in
    /// banner and the Join CTA's behavior.
    let isSignedIn: Bool
    /// Called when a signed-out user taps Join. Root view persists the
    /// token to `PendingInviteStorage` and surfaces the sign-in screen.
    let onSignInRequested: () -> Void

    @State private var loadState: LoadState = .loading
    @State private var preview: InvitePreview?
    @State private var loadError: InviteError?
    @State private var isJoining = false
    @State private var joinError: InviteError?
    @State private var showJoinErrorBanner = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum LoadState: Equatable {
        case loading
        case ready
        case failed
    }

    var body: some View {
        ZStack {
            AppColors.appBackground.ignoresSafeArea()
            content
        }
        .task { await loadPreview() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            loadingView
        case .ready:
            if let preview {
                readyView(preview: preview)
            } else {
                loadingView
            }
        case .failed:
            failedView
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 0) {
            // Cover area placeholder — gradient block sized to match the
            // eventual hero image.
            SkeletonView(cornerRadius: 0, height: 320)
                .frame(maxWidth: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                SkeletonView(cornerRadius: 8, height: 32)
                    .frame(width: 240)
                SkeletonView(cornerRadius: 6, height: 18)
                    .frame(width: 180)
                SkeletonView(cornerRadius: 6, height: 18)
                    .frame(width: 140)
                Spacer().frame(height: AppSpacing.lg)
                SkeletonView(cornerRadius: 8, height: 56)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.top, AppSpacing.xl)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Ready

    @ViewBuilder
    private func readyView(preview: InvitePreview) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                heroCover(preview: preview)
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    titleBlock(preview: preview)
                    inviterRow(preview: preview)
                    Divider()
                        .background(AppColors.appDivider)
                    canDoBlock(role: preview.role)
                    if !isSignedIn {
                        signedOutBanner
                    }
                    if let joinError, showJoinErrorBanner {
                        joinErrorBanner(joinError)
                    }
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xxl)
            }
        }
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ctaBar(preview: preview)
        }
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, AppSpacing.xl)
                .padding(.trailing, AppSpacing.lg)
        }
    }

    private func heroCover(preview: InvitePreview) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let url = preview.coverImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        AppColors.appPrimaryLight
                    case .success(let img):
                        img
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        AppColors.appPrimaryLight
                    @unknown default:
                        AppColors.appPrimaryLight
                    }
                }
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .clipped()
            } else {
                LinearGradient(
                    colors: [AppColors.appPrimary.opacity(0.5), AppColors.appAccent.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 320)
            }
            // Legibility gradient
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
        }
        .accessibilityHidden(true)
    }

    private func titleBlock(preview: InvitePreview) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(preview.tripName)
                .font(.screenTitle)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppSpacing.sm) {
                if let formatted = formattedDateRange(start: preview.startDate, end: preview.endDate) {
                    Label(formatted, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            if let destination = preview.destination, !destination.isEmpty {
                Label(destination, systemImage: "mappin.and.ellipse")
                    .labelStyle(.titleAndIcon)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(titleAccessibility(for: preview))
    }

    private func inviterRow(preview: InvitePreview) -> some View {
        HStack(spacing: AppSpacing.md) {
            AvatarView(
                displayName: preview.resolvedInviterName,
                imageURL: nil,
                stableID: preview.resolvedInviterName,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("\(preview.resolvedInviterName) invited you")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text(preview.role.verboseLabel)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preview.resolvedInviterName) invited you. \(preview.role.verboseLabel)")
    }

    private func canDoBlock(role: TripRole) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("What you can do")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
            ForEach(canDoBullets(for: role), id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.appPrimary)
                        .accessibilityHidden(true)
                    Text(bullet)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var signedOutBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(AppColors.appPrimary)
                .accessibilityHidden(true)
            Text("Sign in to join. We'll bring you right back here.")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                .fill(AppColors.appPrimaryLight)
        )
    }

    private func joinErrorBanner(_ error: InviteError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.appWarning)
                .accessibilityHidden(true)
            Text(errorMessage(for: error))
                .font(.appCaption)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                .fill(AppColors.appWarning.opacity(0.12))
        )
        .transition(.opacity)
    }

    private func ctaBar(preview: InvitePreview) -> some View {
        VStack(spacing: AppSpacing.sm) {
            Button {
                Task { await primaryAction(preview: preview) }
            } label: {
                HStack {
                    if isJoining {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Text(isSignedIn ? "Join trip" : "Sign in to join")
                            .font(.appButton)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(AppColors.appPrimary)
                )
            }
            .buttonStyle(.plain)
            .disabled(isJoining)
            .accessibilityLabel(isSignedIn ? "Join trip" : "Sign in to join")
            .accessibilityHint("Joins \(preview.tripName) as \(preview.role.displayLabel.lowercased())")

            Button {
                HapticManager.light()
                onDismiss()
            } label: {
                Text("Maybe later")
                    .font(.appButton)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(.ultraThinMaterial)
    }

    private var closeButton: some View {
        Button {
            HapticManager.light()
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    // MARK: - Failed

    private var failedView: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            Image(systemName: failedIconName)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(AppColors.textTertiary)
            Text(failedTitle)
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(failedSubtitle)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
            Spacer()
            Button {
                HapticManager.light()
                onDismiss()
            } label: {
                Text("Close")
                    .font(.appButton)
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedIconName: String {
        switch loadError {
        case .alreadyOwner, .alreadyMember:
            return "checkmark.circle"
        case .invalidOrExpired, .notFound:
            return "link.badge.plus"
        case .tripFull:
            return "person.3"
        default:
            return "exclamationmark.triangle"
        }
    }

    private var failedTitle: String {
        switch loadError {
        case .notFound: return "We couldn't find that invite"
        case .invalidOrExpired: return "This invite has expired"
        case .alreadyOwner: return "This is your trip"
        case .alreadyMember: return "You're already on this trip"
        case .tripFull: return "This trip is full"
        case .notAuthenticated: return "Sign in to continue"
        case .unknownServerError, .transport, .none:
            return "Something went wrong"
        }
    }

    private var failedSubtitle: String {
        switch loadError {
        case .notFound:
            return "Double-check the link, or ask them to send a new one."
        case .invalidOrExpired:
            return "Ask them to send a new invite — they only stay open for a few days."
        case .alreadyOwner:
            return "You created this trip, so there's nothing to accept."
        case .alreadyMember:
            return "Open it from your trips list to keep planning."
        case .tripFull:
            return "Trips can have up to 25 collaborators. Ask the owner to remove someone first."
        case .notAuthenticated:
            return "Sign in and tap the link again."
        case .unknownServerError(let raw):
            return raw
        case .transport(let message):
            return message
        case .none:
            return "Try opening the link again in a moment."
        }
    }

    // MARK: - Actions

    private func loadPreview() async {
        loadState = .loading
        loadError = nil
        do {
            let p = try await InviteService.shared.fetchInvitePreview(token: token)
            preview = p
            loadState = .ready
        } catch let inviteError as InviteError {
            loadError = inviteError
            loadState = .failed
        } catch {
            loadError = .transport(message: error.localizedDescription)
            loadState = .failed
        }
    }

    private func primaryAction(preview: InvitePreview) async {
        if !isSignedIn {
            HapticManager.light()
            onSignInRequested()
            return
        }
        await join(preview: preview)
    }

    private func join(preview: InvitePreview) async {
        isJoining = true
        defer { isJoining = false }
        joinError = nil
        showJoinErrorBanner = false
        do {
            let tripId = try await InviteService.shared.acceptInvite(token: token)
            HapticManager.success()
            onJoinSuccess(tripId, preview)
        } catch let error as InviteError {
            joinError = error
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                showJoinErrorBanner = true
            }
            HapticManager.warning()
            // For terminal cases (already member / already owner) treat the
            // banner as the only resolution; user can still tap Maybe later.
            if case .alreadyMember = error {
                // Silent navigation — the membership is already there, so
                // synthesize a "join success" for the existing trip and
                // let the root navigator open it.
                onJoinSuccess(preview.tripId, preview)
            }
        } catch {
            joinError = .transport(message: error.localizedDescription)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                showJoinErrorBanner = true
            }
            HapticManager.warning()
        }
    }

    // MARK: - Copy helpers

    private func canDoBullets(for role: TripRole) -> [String] {
        switch role {
        case .owner, .editor:
            return [
                "Add stops, bookings, and notes",
                "Move and reorder days",
                "See everyone's edits the moment they happen"
            ]
        case .viewer:
            return [
                "See the full trip plan and bookings",
                "Get notified when things change",
                "Suggest ideas in the trip chat (coming soon)"
            ]
        }
    }

    private func formattedDateRange(start: Date?, end: Date?) -> String? {
        guard let start, let end else { return nil }
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: start, to: end)
    }

    private func titleAccessibility(for preview: InvitePreview) -> String {
        var parts: [String] = [preview.tripName]
        if let formatted = formattedDateRange(start: preview.startDate, end: preview.endDate) {
            parts.append(formatted)
        }
        if let destination = preview.destination, !destination.isEmpty {
            parts.append(destination)
        }
        return parts.joined(separator: ", ")
    }

    private func errorMessage(for error: InviteError) -> String {
        switch error {
        case .invalidOrExpired:
            return "This invite has expired. Ask them to send a new one."
        case .notFound:
            return "We couldn't find that invite."
        case .alreadyOwner:
            return "You created this trip — open it from your trips list."
        case .alreadyMember:
            return "You're already on this trip."
        case .tripFull:
            return "This trip is full. The owner can remove someone to make room."
        case .notAuthenticated:
            return "Sign in to join this trip."
        case .unknownServerError(let raw):
            return raw
        case .transport(let message):
            return "We couldn't reach Wayfind. \(message)"
        }
    }
}


// =============================================================================
