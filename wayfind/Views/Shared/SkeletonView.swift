//
//  SkeletonView.swift
//  wayfind
//
//  Lightweight shimmering placeholder for loading states. Used by Phase 2's
//  `InviteAcceptView` while `fetchInvitePreview` is in flight (per the
//  UX review: "SkeletonView placeholder NEVER bare spinner") and by
//  Phase 4's recent-activity feed for initial-load rows.
//
//  Apple HIG: a skeleton mirrors the *shape* of the eventual content so
//  the layout doesn't reflow when data arrives. Treat each instance as a
//  rough block sized to the real text/image it will replace, not as a
//  generic spinner.
//
//  Reduce Motion: when on, the shimmer animation is suppressed and the
//  base fill color holds steady. The placeholder is still visible — we
//  only mute the moving gradient.
//

import SwiftUI

struct SkeletonView: View {
    var cornerRadius: CGFloat = AppCornerRadius.small
    var height: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppColors.appDivider.opacity(0.6))
            if !reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white.opacity(0.55), location: 0.5),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: UnitPoint(x: phase, y: 0.5),
                            endPoint: UnitPoint(x: phase + 1.0, y: 0.5)
                        )
                    )
                    .blendMode(.plusLighter)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}

extension View {
    /// Shorthand for wrapping a view in a skeleton overlay so the consumer
    /// can write `.shimmer()` instead of building a SkeletonView by hand.
    /// Currently unused — left as a hook for Phase 4.
    func shimmer(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .white.opacity(0.4), location: 0.5),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: UnitPoint(x: phase, y: 0.5),
                        endPoint: UnitPoint(x: phase + 1.0, y: 0.5)
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            phase = 1.0
                        }
                    }
                }
            }
            .mask(content)
    }
}

#Preview {
    VStack(spacing: 16) {
        SkeletonView(cornerRadius: 8, height: 24)
            .frame(width: 220)
        SkeletonView(cornerRadius: 8, height: 16)
            .frame(width: 160)
        SkeletonView(cornerRadius: 12, height: 80)
    }
    .padding()
}


// =============================================================================
