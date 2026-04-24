import SwiftUI

enum AppButtonStyle {
    case primary
    case outline
    case destructive
    case text
}

struct AppButton: View {
    let title: String
    let style: AppButtonStyle
    var isDisabled: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                labelContent
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(loaderTint)
                }
            }
            .frame(maxWidth: style == .text ? nil : .infinity)
            .frame(height: style == .text ? nil : 48)
            .padding(.horizontal, style == .text ? AppSpacing.sm : 0)
            .padding(.vertical, style == .text ? AppSpacing.xs : 0)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appPrimary, lineWidth: 1)
                }
            }
            .modifier(ButtonClipModifier(style: style))
        }
        .buttonStyle(WayfindButtonStyle())
        .disabled(isDisabled || isLoading)
    }

    @ViewBuilder
    private var labelContent: some View {
        Text(title)
            .font(.appButton)
    }

    private var loaderTint: Color {
        switch style {
        case .primary:
            return .white
        case .outline, .text:
            return AppColors.appPrimary
        case .destructive:
            return AppColors.appError
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return AppColors.appPrimary
        case .outline, .destructive, .text:
            return .clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .white
        case .outline, .text:
            return AppColors.appPrimary
        case .destructive:
            return AppColors.appError
        }
    }
}

private struct ButtonClipModifier: ViewModifier {
    let style: AppButtonStyle

    func body(content: Content) -> some View {
        switch style {
        case .primary, .outline:
            content.clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        case .destructive, .text:
            content
        }
    }
}

private struct WayfindButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(AppSpring.snappy, value: configuration.isPressed)
            .background(
                PressFeedbackView(isPressed: configuration.isPressed)
            )
    }
}

private struct PressFeedbackView: View {
    let isPressed: Bool

    var body: some View {
        Color.clear
            .onChange(of: isPressed) { _, new in
                if new {
                    HapticManager.light()
                }
            }
    }
}


// =============================================================================

