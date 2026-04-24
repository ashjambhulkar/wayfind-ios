import SwiftUI

struct SkeletonView: View {
    var height: CGFloat = 16
    var cornerRadius: CGFloat = AppCornerRadius.small

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppColors.appDivider)
            .frame(height: height)
            .shimmer()
    }
}

private struct ShimmerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                        let cycle = 1.8
                        let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                        let w = proxy.size.width
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.45),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: w * 0.55)
                        .offset(x: -w * 0.55 + CGFloat(t) * (w * 1.55))
                    }
                }
            }
            .mask(content)
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}


// =============================================================================

