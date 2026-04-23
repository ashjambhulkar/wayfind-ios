import SwiftUI

/// Speed-dial menu (scrim + child actions) without the main FAB — host places the primary `+` separately (e.g. trip bottom bar).
struct SpeedDialMenuOverlay: View {
    @Binding var isOpen: Bool
    let items: [(sfSymbol: String, label: String, action: () -> Void)]
    var footerTip: SpeedDialFooterTip? = nil
    /// Space reserved above the bottom safe area for the floating bar + primary button.
    var bottomContentInset: CGFloat

    private let dialColors: [Color] = [
        AppColors.appPrimary,
        AppColors.appAccent,
        AppColors.appSuccess,
        AppColors.day1,
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isOpen {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        isOpen = false
                    }
            }

            VStack(alignment: .trailing, spacing: isOpen ? AppSpacing.md : 0) {
                ForEach(Array((0..<items.count).reversed()), id: \.self) { index in
                    let item = items[index]
                    dialRow(
                        sfSymbol: item.sfSymbol,
                        label: item.label,
                        color: dialColors[index % dialColors.count]
                    ) {
                        item.action()
                        isOpen = false
                    }
                    .opacity(isOpen ? 1 : 0)
                    .frame(height: isOpen ? nil : 0)
                    .clipped()
                    .allowsHitTesting(isOpen)
                    .animation(AppSpring.bouncy.delay(Double(index) * 0.06), value: isOpen)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, bottomContentInset)

            if isOpen, let tip = footerTip {
                VStack {
                    Spacer()
                    footerTipView(tip)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(AppSpring.smooth.delay(0.15), value: isOpen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(isOpen)
        .onChange(of: isOpen) { _, new in
            if new {
                HapticManager.medium()
            }
        }
    }

    private func footerTipView(_ tip: SpeedDialFooterTip) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 12))
            Text("Forward booking emails to ")
                .font(.appCaption)
            + Text(tip.email)
                .font(.system(.caption, design: .monospaced))
            + Text(" for auto-import")
                .font(.appCaption)

            Button {
                UIPasteboard.general.string = tip.email
                HapticManager.success()
                tip.onCopy()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: .bottom)
    }

    private func dialRow(
        sfSymbol: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(.white)
            Button(action: action) {
                Image(systemName: sfSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(Color.white, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}
