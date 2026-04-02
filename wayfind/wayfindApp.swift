import SwiftUI

@main
struct WayfindApp: App {
    @State private var authViewModel = AuthViewModel()
    @State private var dataService = MockDataService()
    @State private var toastManager = ToastManager()

    var body: some Scene {
        WindowGroup {
            Group {
                switch authViewModel.authState {
                case .loading:
                    VStack(spacing: AppSpacing.lg) {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(AppColors.appPrimary)
                        Text("Wayfind")
                            .font(.screenTitle)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.appBackground.ignoresSafeArea())

                case .signedIn:
                    TripsListView()
                        .sheet(isPresented: .init(
                            get: { authViewModel.needsDisplayName },
                            set: { _ in }
                        )) {
                            DisplayNamePromptView()
                        }

                case .signedOut:
                    NavigationStack {
                        SignInView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.appBackground.ignoresSafeArea())
            .environment(authViewModel)
            .environment(dataService)
            .environment(toastManager)
            .toastOverlay(manager: toastManager)
        }
    }
}

private struct DisplayNamePromptView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            Text("👋")
                .font(.system(size: 50))

            Text("Welcome!")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)

            Text("What should we call you?")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)

            HStack(spacing: AppSpacing.md) {
                Image(systemName: "person.fill")
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(width: 24)
                TextField("Your name", text: $name)
                    .font(.appBody)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { saveName() }
            }
            .frame(height: 48)
            .padding(.horizontal, AppSpacing.md)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )
            .padding(.horizontal, AppSpacing.xxl)

            AppButton(
                title: "Continue →",
                style: .primary,
                isDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                saveName()
            }
            .padding(.horizontal, AppSpacing.xxl)

            Spacer()
        }
        .background(AppColors.appBackground)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onAppear {
            let prefix = authViewModel.currentUserEmail.components(separatedBy: "@").first ?? ""
            name = prefix.capitalized
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await authViewModel.setDisplayName(trimmed)
        }
        dismiss()
    }
}