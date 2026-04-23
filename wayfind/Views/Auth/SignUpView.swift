import AuthenticationServices
import SwiftUI

struct SignUpView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
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

                    Text("Create your account")
                        .font(Font.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)

                    Text("Start planning adventures")
                        .font(Font.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.center)

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    SignInWithAppleButton(.signUp) { request in
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

                    AuthIconRow(icon: "person.fill") {
                        TextField("Name", text: $name)
                            .focused($focusedField, equals: .name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .email }
                    }

                    Spacer()
                        .frame(height: AppSpacing.md)

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
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .onSubmit {
                                Task {
                                    await authViewModel.signUp(name: name, email: email, password: password)
                                }
                            }
                    }

                    if let message = authViewModel.successMessage {
                        Text(message)
                            .font(Font.appCaption)
                            .foregroundStyle(AppColors.appSuccess)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, AppSpacing.sm)
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

                    AppButton(title: "Create Account", style: .primary, isLoading: authViewModel.isLoading) {
                        Task {
                            await authViewModel.signUp(name: name, email: email, password: password)
                        }
                    }

                    Spacer()
                        .frame(height: AppSpacing.xl)

                    HStack(spacing: AppSpacing.xs) {
                        Text("Already have an account?")
                            .font(Font.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                        Button {
                            dismiss()
                        } label: {
                            Text("Sign in")
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
        .animation(AppSpring.smooth, value: authViewModel.successMessage)
    }
}