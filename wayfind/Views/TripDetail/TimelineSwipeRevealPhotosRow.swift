import SwiftUI

/// Trailing swipe on timeline rows (non-`List`): a **full** drag to the
/// stop opens `ActivityPhotosSheet`; a partial swipe snaps open to show the
/// **Photos** button (user taps to open).
struct TimelineSwipeRevealPhotosRow<Content: View>: View {
    var revealWidth: CGFloat = 80
    let onPhotos: () -> Void
    @ViewBuilder var content: () -> Content

    /// Within this distance of the hard stop counts as “extreme” swipe → open sheet.
    private var fullSwipeSlop: CGFloat { 4 }
    /// Smaller drifts spring closed; past this we snap the reveal button open.
    private var peekThreshold: CGFloat { 14 }

    @State private var offset: CGFloat = 0
    @State private var lastCommitted: CGFloat = 0
    @State private var axisLocked: Bool?

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    onPhotos()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        offset = 0
                        lastCommitted = 0
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .semibold))
                        Text(String(localized: "Photos"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(AppColors.appPrimary)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: AppCornerRadius.medium,
                            bottomLeadingRadius: AppCornerRadius.medium,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Photos"))
                .accessibilityHint(String(localized: "Opens activity photos"))
            }

            content()
                .background(Color.clear)
                .offset(x: offset)
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
        .clipped()
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                if axisLocked == nil {
                    let t = value.translation
                    if hypot(t.width, t.height) > 12 {
                        axisLocked = abs(t.width) >= abs(t.height)
                    }
                }
                guard axisLocked == true else { return }
                let proposed = lastCommitted + value.translation.width
                offset = min(0, max(-revealWidth, proposed))
            }
            .onEnded { _ in
                let wasHorizontal = axisLocked == true
                axisLocked = nil
                guard wasHorizontal else { return }
                let atHardStop = offset <= -revealWidth + fullSwipeSlop
                if atHardStop {
                    HapticManager.light()
                    onPhotos()
                    offset = 0
                    lastCommitted = 0
                } else if offset <= -peekThreshold {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        offset = -revealWidth
                        lastCommitted = -revealWidth
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        offset = 0
                        lastCommitted = 0
                    }
                }
            }
    }
}
