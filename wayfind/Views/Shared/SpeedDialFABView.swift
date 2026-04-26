import SwiftUI

struct SpeedDialFABView: View {
    @Binding var isOpen: Bool
    let items: [(sfSymbol: String, label: String, action: () -> Void)]
    var footerTip: SpeedDialFooterTip? = nil

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

                mainFAB
            }
            .padding(AppSpacing.lg)

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

    private var mainFAB: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(AppColors.appPrimary, in: Circle())
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                .rotationEffect(.degrees(isOpen ? 45 : 0))
                .animation(AppSpring.bouncy, value: isOpen)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Close menu" : "Add new item")
    }
}

struct SpeedDialFooterTip {
    let email: String
    var onCopy: () -> Void
}


// =============================================================================


#if DEBUG
import SwiftUI

#Preview("Speed Dial") {
    @Previewable @State var isOpen = false
    ZStack(alignment: .bottomTrailing) {
        AppColors.appBackground.ignoresSafeArea()
        SpeedDialFABView(
            isOpen: $isOpen,
            items: [
                ("plus.circle", "Add Place", {}),
                ("ticket", "Add Booking", {}),
                ("note.text", "Add Note", {}),
            ]
        )
        .padding()
    }
}
#endif
