import SwiftUI
import UIKit

/// Horizontal day filter using system bordered capsule buttons (SwiftUI `buttonBorderShape(.capsule)`),
/// matching the native control look used across iOS for filter rows.
struct DayFilterChipsView: View {
    @Binding var selectedDay: Int?
    let dayCount: Int
    var controlSize: ControlSize = .regular

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                let allSelected = selectedDay == nil
                DayFilterCapsuleButton(
                    title: String(localized: "All"),
                    isSelected: allSelected,
                    dotColor: allSelected ? AppColors.appPrimary : nil,
                    controlSize: controlSize
                ) {
                    selectedDay = nil
                }
                if dayCount > 0 {
                    ForEach(1 ... dayCount, id: \.self) { day in
                        DayFilterCapsuleButton(
                            title: String(localized: "Day \(day)"),
                            isSelected: selectedDay == day,
                            dotColor: AppColors.dayColor(for: day),
                            controlSize: controlSize
                        ) {
                            selectedDay = day
                        }
                    }
                }
            }
            .padding(.vertical, AppSpacing.xs)
            .padding(.horizontal, AppSpacing.sm)
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

// MARK: - Capsule control

private struct DayFilterCapsuleButton: View {
    let title: String
    let isSelected: Bool
    /// Leading accent; `nil` hides the dot (e.g. unselected “All”).
    let dotColor: Color?
    var controlSize: ControlSize = .regular
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.selection()
            action()
        } label: {
            label
                .padding(.horizontal, controlSize == .small ? 10 : 12)
                .padding(.vertical, controlSize == .small ? 5 : 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            Color.primary.opacity(isSelected ? 0.18 : 0.10),
                            lineWidth: 0.5
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        HStack(spacing: 5) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    }
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(Color(uiColor: isSelected ? .label : .secondaryLabel))
                .lineLimit(1)
        }
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
