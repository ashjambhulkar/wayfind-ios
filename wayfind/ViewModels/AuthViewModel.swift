//
//  AuthViewModel.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Observation

enum AuthState {
    case loading
    case signedIn
    case signedOut
}

@Observable
final class AuthViewModel {
    var authState: AuthState = .loading
    var currentUserEmail = ""
    var currentUserName = ""
    var isLoading = false
    var errorMessage: String?
    var needsDisplayName = false

    private var currentNonce: String?

    init() {
        if AppConfig.useRealBackend {
            Task { await restoreSession() }
        } else {
            authState = .signedOut
        }
    }

    // MARK: - Mock Auth (when Supabase not configured)

    func signIn(email: String, password: String) async {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter email and password"
            return
        }
        isLoading = true
        errorMessage = nil

        if AppConfig.useRealBackend {
            // TODO: supabase.auth.signIn(email: email, password: password)
            try? await Task.sleep(for: .milliseconds(500))
        } else {
            try? await Task.sleep(for: .milliseconds(800))
        }

        currentUserEmail = email
        currentUserName = email.components(separatedBy: "@").first?.capitalized ?? "Traveler"
        authState = .signedIn
        isLoading = false
    }

    func signUp(name: String, email: String, password: String) async {
        guard !name.isEmpty, !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please fill in all fields"
            return
        }
        isLoading = true
        errorMessage = nil

        if AppConfig.useRealBackend {
            // TODO: supabase.auth.signUp(email: email, password: password, data: ["full_name": name])
            try? await Task.sleep(for: .milliseconds(500))
        } else {
            try? await Task.sleep(for: .milliseconds(800))
        }

        currentUserName = name
        currentUserEmail = email
        authState = .signedIn
        isLoading = false
    }

    func signOut() {
        // TODO: supabase.auth.signOut()
        authState = .signedOut
        currentUserEmail = ""
        currentUserName = ""
    }

    // MARK: - Apple Sign In

    func prepareAppleSignIn() -> String {
        let nonce = UUID().uuidString
        currentNonce = nonce
        return sha256(nonce)
    }

    func signInWithApple(result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let identityToken = credential.identityToken,
                  let tokenString = String(data: identityToken, encoding: .utf8)
            else { return }

            isLoading = true
            errorMessage = nil

            if AppConfig.useRealBackend {
                // TODO: supabase.auth.signInWithIdToken(
                //     credentials: .init(provider: .apple, idToken: tokenString, nonce: nonce)
                // )
                try? await Task.sleep(for: .milliseconds(500))
            }

            if let fullName = credential.fullName {
                let name = [fullName.givenName, fullName.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                currentUserName = name
            }

            currentUserEmail = credential.email ?? ""
            authState = .signedIn
            isLoading = false

            if currentUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                needsDisplayName = true
            }

        case .failure:
            break
        }
    }

    // MARK: - Google Sign In

    func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil

        if AppConfig.useRealBackend {
            // TODO: supabase.auth.signInWithOAuth(
            //     provider: .google,
            //     redirectTo: URL(string: "com.wayfind.app://auth/callback")
            // )
        }

        try? await Task.sleep(for: .milliseconds(500))
        currentUserEmail = "user@gmail.com"
        currentUserName = "Google User"
        authState = .signedIn
        isLoading = false
    }

    // MARK: - Session

    func restoreSession() async {
        // TODO: Check supabase.auth.session
        try? await Task.sleep(for: .milliseconds(300))
        authState = .signedOut
    }

    func setDisplayName(_ name: String) async {
        currentUserName = name
        needsDisplayName = false
        // TODO: Update profile in Supabase
    }

    // MARK: - Helpers

    var isSignedIn: Bool { authState == .signedIn }

    var userInitials: String {
        let parts = currentUserName.split(separator: " ")
        if parts.count >= 2 {
            return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
        let name = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(name.prefix(2)).uppercased()
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
