import Observation
import SwiftUI

enum ToastKind {
    case success
    case warning
    case error
    case info
    case undo
}

struct ToastData: Identifiable {
    let id = UUID()
    var message: String
    var type: ToastKind
    var duration: TimeInterval = 3
    var undoAction: (() -> Void)?
    /// Optional inline action shown to the trailing edge of the toast — e.g.
    /// "View" on the booking-tracked-as-expense confirmation. Takes
    /// precedence over `undoAction` when both are set so each toast surfaces
    /// at most one tappable affordance. Mirrors `Snackbar` action semantics
    /// from Material so the UI doesn't have to teach the user a new
    /// interaction.
    var actionLabel: String?
    var actionHandler: (() -> Void)?
}

@MainActor
@Observable
final class ToastManager {
    var currentToast: ToastData?
    private var dismissTask: Task<Void, Never>?
    private var activeToastID: UUID?

    func show(_ toast: ToastData) {
        dismissTask?.cancel()
        activeToastID = toast.id
        currentToast = toast
        let toastID = toast.id
        let duration = toast.duration
        dismissTask = Task { @MainActor in
            let ns = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, activeToastID == toastID else { return }
            if currentToast?.id == toastID {
                currentToast = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        activeToastID = nil
        currentToast = nil
    }
}

struct ToastView: View {
    @Environment(ToastManager.self) private var toastManager

    var body: some View {
        Group {
            if let toast = toastManager.currentToast {
                toastCard(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(AppSpring.smooth, value: toastManager.currentToast?.id)
    }

    private func toastCard(_ toast: ToastData) -> some View {
        HStack(alignment: .center, spacing: 0) {
            accentBar(for: toast.type)
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Text(toast.message)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let label = toast.actionLabel, let handler = toast.actionHandler {
                    Button(label) {
                        handler()
                        toastManager.dismiss()
                    }
                    .font(.appButton)
                    .foregroundStyle(AppColors.appPrimary)
                } else if toast.undoAction != nil {
                    Button("Undo") {
                        toast.undoAction?()
                        toastManager.dismiss()
                    }
                    .font(.appButton)
                    .foregroundStyle(AppColors.appPrimary)
                }
            }
            .padding(.vertical, AppSpacing.md)
            .padding(.horizontal, AppSpacing.lg)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.xl)
    }

    private func accentBar(for type: ToastKind) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(accentColor(for: type))
            .frame(width: 4)
            .padding(.vertical, AppSpacing.sm)
    }

    private func accentColor(for type: ToastKind) -> Color {
        switch type {
        case .success:
            return AppColors.appSuccess
        case .warning:
            return AppColors.appWarning
        case .error:
            return AppColors.appError
        case .info:
            return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .undo:
            return AppColors.appPrimary
        }
    }
}

private struct ToastOverlayModifier: ViewModifier {
    let toastManager: ToastManager

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                ToastView()
                    .environment(toastManager)
            }
    }
}

extension View {
    func toastOverlay(manager: ToastManager) -> some View {
        modifier(ToastOverlayModifier(toastManager: manager))
    }
}


// =============================================================================

