import SwiftUI
import UIKit

struct PillButtonView: View {
    let sfSymbol: String
    let label: String
    /// Optional suffix after the label (e.g. `" 2/10"` for checklist progress, `" 3"` for note count).
    var trailingDetail: String?
    var badgeCount: Int?
    var showPulseDot: Bool = false
    var isActive: Bool = true
    let action: () -> Void

    @State private var showComingSoon = false
    @State private var pulsing = false

    var body: some View {
        Group {
            if isActive {
                Button(action: action) {
                    pillLabel
                }
                .buttonStyle(PillPressButtonStyle())
            } else {
                Button {
                    showComingSoon = true
                } label: {
                    pillLabel
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showComingSoon) {
                    Text("Coming Soon")
                        .font(.appBody)
                        .padding(AppSpacing.md)
                }
            }
        }
    }

    private var pillLabel: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: sfSymbol)
            Text(label + (trailingDetail ?? ""))
            if let badgeCount {
                Text("\(badgeCount)")
            }
            if showPulseDot {
                Circle()
                    .fill(AppColors.appPrimary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsing ? 1.5 : 1.0)
                    .opacity(pulsing ? 0.6 : 1.0)
                    .onAppear {
                        guard !UIAccessibility.isReduceMotionEnabled else { return }
                        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                            pulsing = true
                        }
                    }
            }
        }
        .font(.appCaption)
        .foregroundStyle(isActive ? AppColors.textPrimary : AppColors.textTertiary)
        .padding(.horizontal, AppSpacing.md)
        .frame(height: 36)
        .background {
            if isActive {
                Capsule()
                    .fill(AppColors.appSurface)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            } else {
                Capsule()
                    .fill(Color.clear)
            }
        }
        .accessibilityLabel(
            "\(label)\(trailingDetail.map { "\($0)" } ?? "")\(badgeCount.map { ", \($0) items" } ?? "")"
        )
    }
}

private struct PillPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}


// =============================================================================

