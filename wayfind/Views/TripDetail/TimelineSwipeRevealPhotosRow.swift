import SwiftUI

// MARK: - Row width (for full-swipe threshold)

private struct TimelineSwipeRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Trailing swipe on timeline rows (non-`List`):
/// - A **short** swipe snaps open a **compact Photos** affordance (tap to open the sheet).
/// - Keep pulling (**stretch**) past that — past a row-relative threshold — and **release** to jump
///   straight into the activity photos / upload flow (`ActivityPhotosSheet`) without tapping the button.
struct TimelineSwipeRevealPhotosRow<Content: View>: View {
    /// Width of the revealed “Photos” control when snapped open (compact by design).
    var snapOpenWidth: CGFloat = 54
    let onPhotos: () -> Void
    @ViewBuilder var content: () -> Content

    /// Past `snapOpenWidth + rowWidth * fullSwipeRowFraction` → releasing opens photos directly.
    private var fullSwipeRowFraction: CGFloat { 0.26 }
    /// How far past the snap we allow rubber-band drag (caps finger travel).
    private var maxExtraDragRowFraction: CGFloat { 0.42 }
    private var peekThreshold: CGFloat { 12 }

    @State private var offset: CGFloat = 0
    @State private var lastCommitted: CGFloat = 0
    @State private var axisLocked: Bool?
    @State private var rowWidth: CGFloat = 0

    private var effectiveRowWidth: CGFloat {
        rowWidth > 1 ? rowWidth : 320
    }

    private var fullSwipeThreshold: CGFloat {
        snapOpenWidth + effectiveRowWidth * fullSwipeRowFraction
    }

    private var maxDrag: CGFloat {
        snapOpenWidth + effectiveRowWidth * maxExtraDragRowFraction
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    openPhotosAndReset()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 16, weight: .semibold))
                        Text(String(localized: "Photos"))
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(.white)
                    .frame(width: snapOpenWidth)
                    .frame(maxHeight: .infinity)
                    .background(AppColors.appPrimary)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: AppCornerRadius.medium,
                            topTrailingRadius: AppCornerRadius.medium,
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

    private func openPhotosAndReset() {
        onPhotos()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            offset = 0
            lastCommitted = 0
        }
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
                offset = min(0, max(-maxDrag, proposed))
            }
            .onEnded { _ in
                let wasHorizontal = axisLocked == true
                axisLocked = nil
                guard wasHorizontal else { return }

                if offset <= -fullSwipeThreshold {
                    HapticManager.light()
                    onPhotos()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        offset = 0
                        lastCommitted = 0
                    }
                } else if offset <= -peekThreshold {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        offset = -snapOpenWidth
                        lastCommitted = -snapOpenWidth
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
