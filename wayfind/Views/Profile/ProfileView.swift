import SwiftUI

struct ProfileView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var tripSort: TripSortPreference = .date
    @State private var appearance: AppearancePreference = .system

    private var joinedSubtitle: String {
        let joined = Date()
        let monthYear = joined.formatted(.dateTime.month(.abbreviated).year())
        return "Joined \(monthYear)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.xl) {
                userCard

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("PREFERENCES")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Sort trips by")
                                .font(.cardTitle)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Picker("Sort trips by", selection: $tripSort) {
                                ForEach(TripSortPreference.allCases) { option in
                                    Text(option.title)
                                        .tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                            .tint(AppColors.appPrimary)
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)

                        Divider()
                            .background(AppColors.appDivider)

                        HStack {
                            Text("Appearance")
                                .font(.cardTitle)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Picker("Appearance", selection: $appearance) {
                                ForEach(AppearancePreference.allCases) { option in
                                    Text(option.title)
                                        .tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                            .tint(AppColors.appPrimary)
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)
                    }
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                }

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("ABOUT")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Version")
                                .font(.cardTitle)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Text("1.0")
                                .font(.appBody)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)

                        Divider()
                            .background(AppColors.appDivider)

                        NavigationLink {
                            Text("Privacy Policy")
                                .font(.appBody)
                                .foregroundStyle(AppColors.textPrimary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(AppColors.appBackground)
                                .navigationTitle("Privacy Policy")
                        } label: {
                            HStack {
                                Text("Privacy Policy")
                                    .font(.cardTitle)
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.appCaption)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .background(AppColors.appDivider)

                        NavigationLink {
                            Text("Terms of Service")
                                .font(.appBody)
                                .foregroundStyle(AppColors.textPrimary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(AppColors.appBackground)
                                .navigationTitle("Terms of Service")
                        } label: {
                            HStack {
                                Text("Terms of Service")
                                    .font(.cardTitle)
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.appCaption)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                }

                AppButton(title: "Sign Out", style: .destructive) {
                    authViewModel.signOut()
                }
            }
            .padding(.horizontal, AppSpacing.lg)
        }
        .background(AppColors.appBackground)
        .navigationTitle("Profile")
    }

    private var userCard: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            Text(authViewModel.userInitials)
                .font(.appButton)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(AppColors.appPrimary)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(authViewModel.currentUserEmail)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                Text(joinedSubtitle)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
    }
}

private enum TripSortPreference: String, CaseIterable, Identifiable {
    case date
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: "Date"
        case .name: "Name"
        }
    }
}

private enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

#Preview {
    NavigationStack {
        ProfileView()
            .environment(AuthViewModel())
    }
}