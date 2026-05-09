import AuthenticationServices
import SwiftUI
import UIKit

struct SignInView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var password = ""
    @State private var showPasswordReset = false
    @State private var resetEmail = ""
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

                    AuthBrandMark()

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
                        googleBundledLogoTitle: "Continue with Google"
                    ) {
                        Task {
                            await authViewModel.signInWithGoogle()
                        }
                    }
                    .accessibilityLabel("Continue with Google")
                    .accessibilityHint("Opens the Google sign-in flow")

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

                    Button("Forgot password?") {
                        resetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        showPasswordReset = true
                    }
                    .font(Font.appBody)
                    .foregroundStyle(AppColors.appPrimary)
                    .padding(.top, AppSpacing.md)

                    Spacer()
                        .frame(height: AppSpacing.xxl)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(AppSpring.smooth, value: authViewModel.errorMessage)
        .animation(AppSpring.smooth, value: authViewModel.successMessage)
        .sheet(isPresented: $showPasswordReset) {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    Text("We’ll email you a link to reset your password. The link opens in this app using your saved redirect URL.")
                        .font(Font.appCaption)
                        .foregroundStyle(AppColors.textSecondary)

                    AuthIconRow(icon: "envelope") {
                        TextField("Email", text: $resetEmail)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if let message = authViewModel.successMessage {
                        Text(message)
                            .font(Font.appCaption)
                            .foregroundStyle(AppColors.appSuccess)
                    }
                    if let message = authViewModel.errorMessage {
                        Text(message)
                            .font(Font.appCaption)
                            .foregroundStyle(AppColors.appError)
                    }

                    Spacer()
                }
                .padding(AppSpacing.xl)
                .navigationTitle("Reset password")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showPasswordReset = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            Task {
                                await authViewModel.sendPasswordReset(email: resetEmail)
                            }
                        }
                        .disabled(resetEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authViewModel.isLoading)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// Raster logo (`AppLogo` asset) above the app name on sign-in / sign-up.
struct AuthBrandMark: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .accessibilityLabel("Wayfind")
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
    private enum LeadingIcon {
        case sfSymbol(String)
        case googleBundledLogo
    }

    private let leadingIcon: LeadingIcon
    let title: String
    let action: () -> Void

    init(icon: String, title: String, action: @escaping () -> Void) {
        self.leadingIcon = .sfSymbol(icon)
        self.title = title
        self.action = action
    }

    /// Uses the multicolor “G” shipped inside `GoogleSignIn_GoogleSignIn.bundle` (official SDK asset).
    init(googleBundledLogoTitle title: String, action: @escaping () -> Void) {
        self.leadingIcon = .googleBundledLogo
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                switch leadingIcon {
                case .sfSymbol(let name):
                    Image(systemName: name)
                case .googleBundledLogo:
                    GoogleSignInBundledLogoView()
                }
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

/// Multicolor Google “G” from the Google Sign-In SDK resource bundle (no duplicate asset in our catalog).
private struct GoogleSignInBundledLogoView: View {
    private static var resourceBundle: Bundle? {
        let names = ["GoogleSignIn_GoogleSignIn", "GoogleSignIn"]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    private static var logoImage: UIImage? {
        guard let bundle = resourceBundle else { return nil }
        return UIImage(named: "google", in: bundle, compatibleWith: nil)
    }

    var body: some View {
        Group {
            if let uiImage = Self.logoImage {
                Image(uiImage: uiImage)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: GoogleSignInBundledLogoMetrics.size, height: GoogleSignInBundledLogoMetrics.size)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "g.circle.fill")
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum GoogleSignInBundledLogoMetrics {
    /// Aligns with Google’s sign-in button artwork scale at our 48pt row height.
    static let size: CGFloat = 20
}

struct AuthOutlinePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}

// =============================================================================

