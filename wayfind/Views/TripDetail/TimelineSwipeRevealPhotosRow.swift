import SwiftUI

// MARK: - Row width (for full-swipe threshold)

private struct TimelineSwipeRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum TimelineSwipeRevealPhotosMetrics {
    /// Share the same trailing-corner family as `timelineCardChassis` so the action reads as part of the card.
    static let actionCornerRadius = AppCornerRadius.large
    /// Past this fraction of `snapOpen`, a release snaps fully open (Mail-style commit).
    static let openCommitFraction: CGFloat = 0.38
    /// Drag past open + row × this fraction triggers full-swipe-to-photos.
    static let fullSwipeRowFraction: CGFloat = 0.26
    /// Extra travel past snap-open, as a fraction of row width (with resistance applied).
    static let maxExtraDragRowFraction: CGFloat = 0.42
    /// Finger movement beyond snap-open is scaled by this for rubber-band feel.
    static let overscrollResistance: CGFloat = 0.42
    static let axisLockMinimumDistance: CGFloat = 16
    static let axisLockHypotenuse: CGFloat = 12
}

/// Trailing swipe on timeline rows (non-`List`):
/// - A **short** swipe snaps open a compact **Photos** affordance; tapping it jumps into **add photos**
///   (`ActivityPhotosSheet` + system picker when slots remain).
/// - Keep pulling (**stretch**) past that — past a row-relative threshold — and **release** for the same
///   presentation without tapping.
struct TimelineSwipeRevealPhotosRow<Content: View>: View {
    /// Width of the revealed “Photos” control when snapped open (compact by design).
    var snapOpenWidth: CGFloat = 54
    let onPhotos: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var offset: CGFloat = 0
    @State private var lastCommitted: CGFloat = 0
    @State private var axisLocked: Bool?
    @State private var rowWidth: CGFloat = 0

    private var effectiveRowWidth: CGFloat {
        rowWidth > 1 ? rowWidth : 320
    }

    private var fullSwipeThreshold: CGFloat {
        snapOpenWidth + effectiveRowWidth * TimelineSwipeRevealPhotosMetrics.fullSwipeRowFraction
    }

    private var maxDrag: CGFloat {
        snapOpenWidth + effectiveRowWidth * TimelineSwipeRevealPhotosMetrics.maxExtraDragRowFraction
    }

    private var openCommitThreshold: CGFloat {
        -snapOpenWidth * TimelineSwipeRevealPhotosMetrics.openCommitFraction
    }

    /// Release animation: respect Reduce Motion (instant settle).
    private var releaseAnimation: Animation? {
        reduceMotion ? nil : AppSpring.smooth
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                photosActionButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            content()
                .background(Color.clear)
                .offset(x: offset)
                .contentShape(Rectangle())
                .simultaneousGesture(dragGesture)
        }
        // Do not clip: `timelineCardChassis` uses a shadow; clipping looked like a cut-off card at rest / mid-swipe.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TimelineSwipeRowWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(TimelineSwipeRowWidthKey.self) { width in
            if width > 0 {
                rowWidth = width
            }
        }
    }

    private var photosActionButton: some View {
        let revealedWidth = max(0, -offset)
        return Button {
            openPhotosAndReset()
        } label: {
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(AppColors.appPrimary)

                VStack(spacing: AppSpacing.xs) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.body.weight(.semibold))
                    Text(String(localized: "Photos"))
                        .font(.appSmall.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white)
                .frame(width: snapOpenWidth)
                .frame(maxHeight: .infinity)
            }
            .frame(width: revealedWidth)
            .frame(maxHeight: .infinity)
            .clipped()
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: TimelineSwipeRevealPhotosMetrics.actionCornerRadius,
                    topTrailingRadius: TimelineSwipeRevealPhotosMetrics.actionCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(revealedWidth > 0.5)
        .accessibilityHidden(revealedWidth < 0.5)
        .accessibilityLabel(String(localized: "Photos"))
        .accessibilityHint(String(localized: "Opens activity photos"))
    }

    private func openPhotosAndReset() {
        onPhotos()
        withAnimation(releaseAnimation) {
            offset = 0
            lastCommitted = 0
        }
    }

    private func dragOffset(proposed: CGFloat) -> CGFloat {
        let raw = min(0, proposed)
        guard raw < -snapOpenWidth else { return max(-maxDrag, raw) }

        let excess = -raw - snapOpenWidth
        let maxExcess = max(0, maxDrag - snapOpenWidth)
        let resisted = excess * TimelineSwipeRevealPhotosMetrics.overscrollResistance
        return -(snapOpenWidth + min(resisted, maxExcess))
    }

    private var dragGesture: some Gesture {
        DragGesture(
            minimumDistance: TimelineSwipeRevealPhotosMetrics.axisLockMinimumDistance,
            coordinateSpace: .local
        )
        .onChanged { value in
            if axisLocked == nil {
                let t = value.translation
                if hypot(t.width, t.height) > TimelineSwipeRevealPhotosMetrics.axisLockHypotenuse {
                    axisLocked = abs(t.width) >= abs(t.height)
                }
            }
            guard axisLocked == true else { return }
            let proposed = lastCommitted + value.translation.width
            offset = dragOffset(proposed: proposed)
        }
        .onEnded { value in
            let wasHorizontal = axisLocked == true
            axisLocked = nil
            guard wasHorizontal else { return }

            let predicted = lastCommitted + value.predictedEndTranslation.width
            let releaseTarget = min(0, dragOffset(proposed: predicted))

            if releaseTarget <= -fullSwipeThreshold {
                HapticManager.light()
                onPhotos()
                withAnimation(releaseAnimation) {
                    offset = 0
                    lastCommitted = 0
                }
            } else if releaseTarget <= openCommitThreshold {
                withAnimation(releaseAnimation) {
                    offset = -snapOpenWidth
                    lastCommitted = -snapOpenWidth
                }
            } else {
                withAnimation(releaseAnimation) {
                    offset = 0
                    lastCommitted = 0
                }
            }
        }
    }
}
