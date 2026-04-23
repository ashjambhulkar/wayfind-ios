import SwiftUI
import UIKit

struct NowIndicatorView: View {
    private static let railWidth: CGFloat = 40

    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 10))
                    path.addLine(to: CGPoint(x: geo.size.width, y: 10))
                }
                .stroke(
                    AppColors.appPrimary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
            }
            .frame(height: 20)
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                Text("NOW")
                    .font(.appSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(minWidth: 24)
                    .background(AppColors.appPrimary)
                    .clipShape(Capsule())
                    .frame(width: Self.railWidth, alignment: .center)

                Spacer(minLength: 0)
            }
        }
        .frame(height: 20)
        .opacity(pulseOpacity)
        .accessibilityLabel("Current time indicator")
        .id("now-indicator")
        .onAppear {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.6
            }
        }
    }
}

