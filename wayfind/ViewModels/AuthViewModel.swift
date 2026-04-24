//
//  AuthViewModel.swift
//  wayfind
//

import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Supabase

enum AuthState {
    case loading
    case signedIn
    case signedOut
}

@Observable
@MainActor
final class AuthViewModel {
    var authState: AuthState = .loading
    var currentUserEmail = ""
    var currentUserName = ""
    var isLoading = false
    var errorMessage: String?
    /// Shown after sign-up when the project requires email confirmation (no session yet).
    var successMessage: String?
    var needsDisplayName = false

    private var currentNonce: String?

    init() {
        AuthSessionService.shared.configure()
        if AppConfig.useRealBackend {
            Task { await restoreSession() }
            startAuthStateListener()
        } else {
            authState = .signedOut
        }
    }

    private func startAuthStateListener() {
        guard AppConfig.useRealBackend else { return }
        Task { @MainActor in
            guard let client = AuthSessionService.shared.client else { return }
            for await (event, session) in client.auth.authStateChanges {
                switch event {
                case .signedOut, .userDeleted:
                    clearLocalSession()
                case .signedIn, .initialSession, .userUpdated:
                    if let session {
                        try? await applySession(session, appleCredential: nil)
                    }
                case .passwordRecovery:
                    if let session {
                        try? await applySession(session, appleCredential: nil)
                    }
                case .tokenRefreshed, .mfaChallengeVerified:
                    break
                }
            }
        }
    }

    private func clearLocalSession() {
        authState = .signedOut
        currentUserEmail = ""
        currentUserName = ""
        needsDisplayName = false
        errorMessage = nil
        successMessage = nil
    }

    func signIn(email: String, password: String) async {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter email and password"
            return
        }
        isLoading = true
        errorMessage = nil
        successMessage = nil

        if AppConfig.useRealBackend {
            do {
                let session = try await AuthSessionService.shared.signInWithEmailPassword(email: email, password: password)
                try await applySession(session, appleCredential: nil)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            try? await Task.sleep(for: .milliseconds(800))
            currentUserEmail = email
            currentUserName = email.components(separatedBy: "@").first?.capitalized ?? "Traveler"
            authState = .signedIn
        }

        isLoading = false
    }

    func signUp(name: String, email: String, password: String) async {
        guard !name.isEmpty, !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please fill in all fields"
            return
        }
        isLoading = true
        errorMessage = nil
        successMessage = nil

        if AppConfig.useRealBackend {
            do {
                let outcome = try await AuthSessionService.shared.signUpWithEmailPassword(
                    email: email,
                    password: password,
                    displayName: name
                )
                switch outcome {
                case .signedIn(let session):
                    try await applySession(session, appleCredential: nil)
                case .needsEmailConfirmation:
                    successMessage = "Check your inbox to confirm your email, then sign in."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            try? await Task.sleep(for: .milliseconds(800))
            currentUserName = name
            currentUserEmail = email
            authState = .signedIn
        }

        isLoading = false
    }

    func handleIncomingAuthURL(_ url: URL) async {
        guard AppConfig.useRealBackend else { return }
        guard AuthSessionService.urlLooksLikeSupabaseAuthCallback(url) else { return }
        errorMessage = nil
        do {
            let session = try await AuthSessionService.shared.exchangeSessionFromAuthCallback(url: url)
            try await applySession(session, appleCredential: nil)
        } catch {
            let message = error.localizedDescription
            if message.contains("Not a valid PKCE flow URL")
                || message.contains("Not a valid implicit grant flow URL")
            {
                return
            }
            errorMessage = message
        }
    }

    func sendPasswordReset(email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter your email address"
            return
        }
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { isLoading = false }
        guard AppConfig.useRealBackend else {
            errorMessage = "Password reset is not available in offline demo mode."
            return
        }
        do {
            try await AuthSessionService.shared.sendPasswordReset(email: trimmed)
            successMessage = "If an account exists for that email, we sent reset instructions."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        errorMessage = nil
        if AppConfig.useRealBackend {
            do {
                try await AuthSessionService.shared.signOut()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        clearLocalSession()
    }

    func prepareAppleSignIn() -> String {
        let nonce = UUID().uuidString
        currentNonce = nonce
        return sha256(nonce)
    }

    func signInWithApple(result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == ASAuthorizationError.errorDomain, ns.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let rawNonce = currentNonce,
                  let identityToken = credential.identityToken,
                  let tokenString = String(data: identityToken, encoding: .utf8)
            else {
                errorMessage = "Could not read Apple credentials."
                return
            }

            isLoading = true
            errorMessage = nil
            successMessage = nil

            if AppConfig.useRealBackend {
                do {
                    let session = try await AuthSessionService.shared.signInWithApple(
                        idToken: tokenString,
                        rawNonce: rawNonce
                    )
                    try await applySession(session, appleCredential: credential)
                } catch {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    return
                }
            } else {
                if let fullName = credential.fullName {
                    let name = [fullName.givenName, fullName.familyName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    currentUserName = name
                }
                currentUserEmail = credential.email ?? ""
                authState = .signedIn
            }

            isLoading = false
        }
    }

    func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        guard AppConfig.useRealBackend else {
            try? await Task.sleep(for: .milliseconds(500))
            currentUserEmail = "user@gmail.com"
            currentUserName = "Google User"
            authState = .signedIn
            isLoading = false
            return
        }

        do {
            let session = try await AuthSessionService.shared.signInWithGoogle()
            try await applySession(session, appleCredential: nil)
        } catch AuthSessionError.googleCancelled {
            errorMessage = nil
        } catch AuthSessionError.googleNotConfigured {
            errorMessage = AuthSessionError.googleNotConfigured.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func restoreSession() async {
        guard AppConfig.useRealBackend else {
            authState = .signedOut
            return
        }
        if let session = await AuthSessionService.shared.currentSession() {
            do {
                try await applySession(session, appleCredential: nil)
            } catch {
                authState = .signedOut
            }
        } else {
            authState = .signedOut
        }
    }

    func setDisplayName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentUserName = trimmed
        needsDisplayName = false

        guard AppConfig.useRealBackend,
              let session = await AuthSessionService.shared.currentSession()
        else { return }

        do {
            try await AuthSessionService.shared.updateDisplayName(trimmed, userId: session.user.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var isSignedIn: Bool { authState == .signedIn }

    var userInitials: String {
        let parts = currentUserName.split(separator: " ")
        if parts.count >= 2 {
            return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
        let name = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return String(name.prefix(2)).uppercased() }
        let email = currentUserEmail
        if email.contains("@") {
            return String(email.prefix(2)).uppercased()
        }
        return "?"
    }

    private func applySession(
        _ session: Session,
        appleCredential: ASAuthorizationAppleIDCredential?
    ) async throws {
        await AuthSessionService.shared.ensureProfileExists(for: session)
        let (displayName, email) = try await AuthSessionService.shared.fetchProfile(for: session)

        let sessionEmail = session.user.email ?? email
        currentUserEmail = sessionEmail

        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentUserName = displayName
            needsDisplayName = false
        } else if let apple = appleCredential, let fullName = apple.fullName {
            let name = [fullName.givenName, fullName.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            if !name.isEmpty {
                currentUserName = name
            } else {
                currentUserName = fallbackName(from: sessionEmail)
            }
            needsDisplayName = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            currentUserName = fallbackName(from: sessionEmail)
            needsDisplayName = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || currentUserName == fallbackName(from: sessionEmail) && sessionEmail.isEmpty
        }

        if currentUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            needsDisplayName = true
        }

        authState = .signedIn
    }

    private func fallbackName(from email: String) -> String {
        guard let local = email.split(separator: "@").first, !local.isEmpty else { return "" }
        return String(local).capitalized
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}


// =============================================================================

