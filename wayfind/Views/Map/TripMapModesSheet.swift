import SwiftUI
import UIKit

/// Bottom sheet: map mode tiles (hybrid / standard) + attribution.
struct TripMapModesSheet: View {
    @Binding var selectedMode: TripMapMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Map Modes")
                    .font(.headline)
                    .fontWeight(.semibold)
                HStack {
                    Spacer()
                    Button {
                        HapticManager.light()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, AppSpacing.md)

            HStack(spacing: 12) {
                ForEach(TripMapMode.allCases) { mode in
                    mapModeOption(mode: mode)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.bottom, AppSpacing.lg)

            Text("© OpenStreetMap and other data providers")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, AppSpacing.md)
        }
        .frame(maxWidth: .infinity)
    }

    private func mapModeOption(mode: TripMapMode) -> some View {
        let isOn = selectedMode == mode
        return Button {
            HapticManager.light()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                selectedMode = mode
            }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: mode.sfSymbol)
                            .font(.system(size: 28, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.primary.opacity(0.9))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isOn ? AppColors.appPrimary : Color.clear, lineWidth: 3)
                    }
                Text(mode.title)
                    .font(.caption)
                    .fontWeight(isOn ? .semibold : .regular)
                    .foregroundStyle(isOn ? AppColors.appPrimary : .primary)
                    .lineLimit(1)
                Text(mode.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(mode.title) map")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// =============================================================================

