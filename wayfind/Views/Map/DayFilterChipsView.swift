import SwiftUI

/// Horizontal day filter using capsule buttons that keep the selected day centered as the page changes.
struct DayFilterChipsView: View {
    @Binding var selectedDay: Int?
    let dayCount: Int
    var controlSize: ControlSize = .regular

    private var selectedScrollId: Int {
        selectedDay ?? 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    let allSelected = selectedDay == nil
                    DayFilterCapsuleButton(
                        title: String(localized: "All"),
                        isSelected: allSelected,
                        accentColor: AppColors.appPrimary,
                        showsDot: allSelected,
                        controlSize: controlSize
                    ) {
                        selectedDay = nil
                    }
                    .id(0)

                    if dayCount > 0 {
                        ForEach(1 ... dayCount, id: \.self) { day in
                            DayFilterCapsuleButton(
                                title: String(localized: "Day \(day)"),
                                isSelected: selectedDay == day,
                                accentColor: AppColors.dayColor(for: day),
                                showsDot: true,
                                controlSize: controlSize
                            ) {
                                selectedDay = day
                            }
                            .id(day)
                        }
                    }
                }
                .padding(.vertical, AppSpacing.xs)
                .padding(.horizontal, AppSpacing.sm)
            }
            .onAppear {
                proxy.scrollTo(selectedScrollId, anchor: .center)
            }
            .onChange(of: selectedScrollId) { _, newValue in
                withAnimation(AppSpring.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: dayCount) { _, _ in
                withAnimation(AppSpring.snappy) {
                    proxy.scrollTo(selectedScrollId, anchor: .center)
                }
            }
            // Subtle edge fade hints that content scrolls horizontally when there
            // are too many days to fit. Only the trailing edge fades — the leading
            // edge stays opaque so the "All" anchor remains readable at rest.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.92),
                        .init(color: .black.opacity(0.0), location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

// MARK: - Capsule control

private struct DayFilterCapsuleButton: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let showsDot: Bool
    var controlSize: ControlSize = .regular
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.selection()
            action()
        } label: {
            label
                .padding(.horizontal, controlSize == .small ? AppSpacing.sm : AppSpacing.md)
                .padding(.vertical, controlSize == .small ? AppSpacing.xs : AppSpacing.sm)
                .background(
                    isSelected ? accentColor : AppColors.appSurface,
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? accentColor : AppColors.appDivider, lineWidth: 0.5)
                }
        }
        .buttonStyle(DayFilterPopupButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        HStack(spacing: AppSpacing.xs) {
            if showsDot {
                Circle()
                    .fill(isSelected ? Color.white : accentColor)
                    .overlay {
                        Circle()
                            .strokeBorder((isSelected ? Color.white : accentColor).opacity(0.35), lineWidth: 0.5)
                    }
                    .frame(width: controlSize == .small ? 6 : 7, height: controlSize == .small ? 6 : 7)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font((controlSize == .small ? Font.appCaption : Font.appBody).weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : AppColors.textPrimary)
                .lineLimit(1)
        }
    }
}

private struct DayFilterPopupButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.06 : 1.0)
            .animation(
                reduceMotion
                    ? .linear(duration: 0.08)
                    : (configuration.isPressed ? AppSpring.snappy : AppSpring.bouncy),
                value: configuration.isPressed
            )
    }
}

// =============================================================================


#if DEBUG
#Preview("Day filter — light") {
    @Previewable @State var selected: Int? = 2
    DayFilterChipsView(selectedDay: $selected, dayCount: 5)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(.regularMaterial)
        .preferredColorScheme(.light)
}

#Preview("Day filter — dark") {
    @Previewable @State var selected: Int? = 2
    DayFilterChipsView(selectedDay: $selected, dayCount: 5)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
}
#endif
