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
    /// Public URL from `profiles.avatar_url`; drives list/nav avatars without a separate profile fetch.
    var currentUserAvatarURLString: String?
    var currentUserId: UUID?
    var isLoading = false
    var errorMessage: String?
    /// Shown after sign-up when the project requires email confirmation (no session yet).
    var successMessage: String?
    var needsDisplayName = false

    private var currentNonce: String?

    /// Phase 5 — invoked just before the auth session is dropped on
    /// `signOut()`. The host (`WayfindApp`) installs a closure here that
    /// drops the FCM token row, tears down the realtime channel, clears
    /// the collaboration store, and resets in-memory deep-link state in
    /// the order specified by the implementation plan:
    ///   1. clearTokenForCurrentDevice (server-side row deletion needs
    ///      the auth session to still be alive for RLS)
    ///   2. realtimeService.unbind
    ///   3. collaborationStore.clear
    ///   4. then auth signOut (this method)
    ///   5. host navigates back to the sign-in surface
    /// `PendingInviteStorage` is intentionally NOT cleared so a pending
    /// invite token survives a sign-out → fresh sign-in cycle.
    var preSignOutCleanup: (() async -> Void)?

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
        currentUserAvatarURLString = nil
        currentUserId = nil
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
        // Run the host-installed cleanup BEFORE we tear down the auth
        // session — `clearTokenForCurrentDevice` needs RLS to still
        // pass for the row delete, and the realtime channel close needs
        // a live websocket. Failure of any individual step is caught
        // and ignored inside the closure (push token cleanup is a
        // best-effort concern, not blocking).
        if let preSignOutCleanup {
            await preSignOutCleanup()
        }
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

    func deleteAccount() async throws {
        errorMessage = nil
        if let preSignOutCleanup {
            await preSignOutCleanup()
        }
        guard AppConfig.useRealBackend else {
            clearLocalSession()
            return
        }
        try await AuthSessionService.shared.deleteCurrentUserAccount()
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

    /// Resolved avatar URL for toolbar / list chrome; nil when absent or not a valid URL.
    var profileAvatarURL: URL? {
        guard let raw = currentUserAvatarURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    /// Stable key for `AvatarView` tint and initials fallback.
    var userAvatarStableID: String {
        if let currentUserId { return currentUserId.uuidString }
        let trimmed = currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "user" : trimmed
    }

    private func applySession(
        _ session: Session,
        appleCredential: ASAuthorizationAppleIDCredential?
    ) async throws {
        await AuthSessionService.shared.ensureProfileExists(for: session)
        let (displayName, email, avatarURLString) = try await AuthSessionService.shared.fetchProfile(for: session)

        let sessionEmail = session.user.email ?? email
        currentUserEmail = sessionEmail
        currentUserId = session.user.id
        currentUserAvatarURLString = avatarURLString

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
        Task {
            await PushNotificationService.shared.resyncFCMTokenAfterAuth()
        }
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

