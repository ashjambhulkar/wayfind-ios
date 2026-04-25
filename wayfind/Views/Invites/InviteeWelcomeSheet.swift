//
//  InviteeWelcomeSheet.swift
//  wayfind
//
//  Phase 2 — celebratory welcome sheet shown the FIRST time a user opens
//  a trip they were invited to. Goals (per UX review):
//
//    • Make the moment of joining feel like a moment, not a silent state
//      change. Confetti + success haptic.
//    • Name the person who invited them ("Alex invited you to Paris
//      2026") so the trip feels social from the first second.
//    • Three feature tiles introducing the collaborative pieces they're
//      most likely to use first — see plan, suggest stops, get notified.
//    • A soft-CTA push-permission row, NOT a hard system prompt — we
//      ask only when the user opts in.
//
//  Presented at `.large` only with `.presentationBackgroundInteraction(
//  .disabled)` so the sheet feels like a dedicated celebration screen
//  rather than a peek above their trip.
//
//  Reduce Motion: confetti is suppressed; the success haptic still
//  fires.
//

import SwiftUI

struct InviteeWelcomeSheet: View {
    let tripTitle: String
    let inviterName: String
    let role: TripRole
    /// User tapped "Get notified" — parent triggers the permission flow.
    /// `nil` if push isn't wired yet (Phase 5 deliverable).
    let onRequestNotifications: (() -> Void)?
    /// User dismissed via Continue or the X.
    let onDismiss: () -> Void

    @State private var showConfetti = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.appBackground.ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: AppSpacing.xl) {
                        hero
                        featureTiles
                        if onRequestNotifications != nil {
                            notificationsRow
                        }
                        Spacer().frame(height: AppSpacing.xl)
                    }
                    .padding(AppSpacing.xl)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    continueBar
                }

                if showConfetti && !reduceMotion {
                    ConfettiOverlay()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        HapticManager.light()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .onAppear {
            HapticManager.success()
            withAnimation(.easeOut(duration: 0.3)) {
                showConfetti = true
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 36))
                .foregroundStyle(AppColors.appPrimary)
                .padding(.bottom, AppSpacing.xs)
            Text("You're in!")
                .font(.screenTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text("\(inviterName) invited you to \(tripTitle).")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You're in! \(inviterName) invited you to \(tripTitle).")
    }

    // MARK: - Feature tiles

    private var featureTiles: some View {
        VStack(spacing: AppSpacing.sm) {
            featureTile(
                symbol: "list.bullet.below.rectangle",
                title: "See the plan",
                subtitle: "Days, stops, and bookings — already organised."
            )
            featureTile(
                symbol: role == .viewer ? "eye" : "plus.circle",
                title: role == .viewer ? "Stay in the loop" : "Add your ideas",
                subtitle: role == .viewer
                    ? "Watch the trip take shape — you'll see every change."
                    : "Drop in stops, restaurants, and notes anytime."
            )
            featureTile(
                symbol: "bell",
                title: "Get notified",
                subtitle: "We'll let you know when something changes."
            )
        }
    }

    private func featureTile(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(AppColors.appPrimary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(AppColors.appPrimaryLight)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: - Notifications row

    private var notificationsRow: some View {
        Button {
            HapticManager.light()
            onRequestNotifications?()
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(AppColors.appPrimary)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn on notifications")
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Hear about new stops, bookings, and edits.")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(AppColors.textTertiary)
                    .font(.appCaption)
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppColors.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .strokeBorder(AppColors.appPrimary.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the system notifications permission prompt")
    }

    // MARK: - Continue bar

    private var continueBar: some View {
        Button {
            HapticManager.light()
            onDismiss()
        } label: {
            Text("Continue")
                .font(.appButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(AppColors.appPrimary)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Confetti overlay

/// Lightweight confetti effect — a few dozen colored shapes that drift
/// downward with rotation. Lives next to the welcome sheet because
/// nothing else in the app needs it. Reduce Motion users skip it
/// entirely (caller wraps in `if !reduceMotion`).
private struct ConfettiOverlay: View {
    @State private var pieces: [Piece] = (0..<24).map { Piece(id: $0) }
    @State private var animateDown = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(piece.color)
                        .frame(width: 8, height: 14)
                        .rotationEffect(.degrees(piece.rotation))
                        .offset(
                            x: piece.startX * geo.size.width,
                            y: animateDown ? geo.size.height + 100 : -50
                        )
                        .opacity(animateDown ? 0 : 1)
                        .animation(
                            .easeIn(duration: piece.duration).delay(piece.delay),
                            value: animateDown
                        )
                }
            }
            .onAppear { animateDown = true }
        }
    }

    private struct Piece: Identifiable {
        let id: Int
        let startX: CGFloat = .random(in: 0...1)
        let rotation: Double = .random(in: 0...360)
        let duration: Double = .random(in: 1.6...2.6)
        let delay: Double = .random(in: 0...0.3)
        let color: Color = [
            AppColors.appPrimary,
            AppColors.appAccent,
            AppColors.day1,
            AppColors.day3,
            AppColors.day5,
            AppColors.day6
        ].randomElement() ?? AppColors.appPrimary
    }
}


// =============================================================================
