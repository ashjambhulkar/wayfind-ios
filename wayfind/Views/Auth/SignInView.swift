import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case password
    }

    var body: some View {
        ZStack {
            AppColors.appBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: AppSpacing.xxl)

                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(AppColors.appPrimary)

                    Text("Wayfind")
                        .font(Font.screenTitle)
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer()
                        .frame(height: 40)

                    Text("Welcome back")
                        .font(Font.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)

                    Text("Sign in to continue planning")
                        .font(Font.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.center)

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    // MARK: - Sign in with Apple (first, per Apple HIG)

                    SignInWithAppleButton(.signIn) { request in
                        let nonce = authViewModel.prepareAppleSignIn()
                        request.requestedScopes = [.email, .fullName]
                        request.nonce = nonce
                    } onCompletion: { result in
                        Task {
                            await authViewModel.signInWithApple(result: result)
                        }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

                    Spacer()
                        .frame(height: AppSpacing.md)

                    // MARK: - Google Sign In

                    AuthOutlineIconButton(
                        icon: "g.circle.fill",
                        title: "Continue with Google"
                    ) {
                        Task {
                            await authViewModel.signInWithGoogle()
                        }
                    }

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    // MARK: - Divider

                    HStack(spacing: AppSpacing.md) {
                        Rectangle()
                            .fill(AppColors.appDivider)
                            .frame(height: 1)
                        Text("or")
                            .font(Font.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                        Rectangle()
                            .fill(AppColors.appDivider)
                            .frame(height: 1)
                    }

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    // MARK: - Email / Password

                    AuthIconRow(icon: "envelope") {
                        TextField("Email", text: $email)
                            .focused($focusedField, equals: .email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                    }

                    Spacer()
                        .frame(height: AppSpacing.md)

                    AuthIconRow(icon: "lock") {
                        SecureField("Password", text: $password)
                            .focused($focusedField, equals: .password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit {
                                Task {
                                    await authViewModel.signIn(email: email, password: password)
                                }
                            }
                    }

                    if let message = authViewModel.errorMessage {
                        Text(message)
                            .font(Font.appCaption)
                            .foregroundStyle(AppColors.appError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, AppSpacing.sm)
                    }

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    AppButton(title: "Sign In", style: .primary, isLoading: authViewModel.isLoading) {
                        Task {
                            await authViewModel.signIn(email: email, password: password)
                        }
                    }

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    HStack(spacing: AppSpacing.xs) {
                        Text("Don't have an account?")
                            .font(Font.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                        NavigationLink {
                            SignUpView()
                        } label: {
                            Text("Sign up")
                                .font(Font.appBody)
                                .foregroundStyle(AppColors.appPrimary)
                        }
                    }

                    Spacer()
                        .frame(height: AppSpacing.xxl)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(AppSpring.smooth, value: authViewModel.errorMessage)
    }
}

struct AuthIconRow<Content: View>: View {
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: 24, alignment: .center)

            content()
                .font(Font.appBody)
                .foregroundStyle(AppColors.textPrimary)
        }
        .frame(height: 48)
        .padding(.horizontal, AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
    }
}

struct AuthOutlineIconButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: icon)
                Text(title)
                    .font(Font.appButton)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(AppColors.textPrimary)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )
        }
        .buttonStyle(AuthOutlinePressStyle())
    }
}

struct AuthOutlinePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}