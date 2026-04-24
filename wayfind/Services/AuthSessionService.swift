import Foundation
import GoogleSignIn
import Supabase
import UIKit

enum EmailPasswordSignUpResult: Sendable {
    case signedIn(Session)
    case needsEmailConfirmation
}

enum AuthSessionError: LocalizedError {
    case notConfigured
    case googleNotConfigured
    case googleCancelled
    case missingPresenter
    case missingGoogleTokens

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured."
        case .googleNotConfigured:
            return "Google Sign-In is not configured for this app."
        case .googleCancelled:
            return nil
        case .missingPresenter:
            return "Could not present sign-in. Try again."
        case .missingGoogleTokens:
            return "Google did not return a valid token."
        }
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct ProfileIdRow: Decodable {
    let id: UUID
}

private struct NewProfileRow: Encodable {
    let id: UUID
    let username: String
    let display_name: String?
    let avatar_url: String?
    let bio: String?
    let default_pin_color: String
    let updated_at: String
}

private enum ProfileTimestamp {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private enum ProfileDefaults {
    /// Matches Expo `ensureProfile` / `profileService` default pin color.
    static let defaultPinColorHex = "#E53935"
}

@MainActor
final class AuthSessionService {
    static let shared = AuthSessionService()

    private(set) var client: SupabaseClient?

    private init() {}

    func configure() {
        guard AppConfig.useRealBackend else { return }
        if client != nil { return }
        guard let url = URL(string: AppConfig.supabaseURL) else { return }
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabaseAnonKey,
            options: SupabaseClientOptions(
                db: .init(),
                auth: .init(redirectToURL: AppConfig.supabaseAuthRedirectURL),
                global: .init(),
                functions: .init(),
                realtime: .init(),
                storage: .init()
            )
        )

        if AppConfig.isGoogleSignInConfigured {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                clientID: AppConfig.googleIOSClientID,
                serverClientID: AppConfig.googleWebClientID
            )
        }
    }

    func handleGoogleURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    /// True when the URL may carry Supabase auth tokens (email confirmation, password recovery, OAuth PKCE).
    static func urlLooksLikeSupabaseAuthCallback(_ url: URL) -> Bool {
        let raw = url.absoluteString
        let lower = raw.lowercased()
        if lower.contains("access_token=") { return true }
        if lower.contains("refresh_token=") { return true }
        if lower.contains("code=") { return true }
        if lower.contains("type=recovery") { return true }
        if lower.contains("type=signup") { return true }
        if lower.contains("type=magiclink") { return true }
        if url.scheme?.caseInsensitiveCompare(AppConfig.appURLScheme) == .orderedSame {
            let host = url.host?.lowercased() ?? ""
            if host == "auth" { return true }
            if lower.contains("auth/callback") { return true }
        }
        return false
    }

    /// Exchanges a deep-link callback for a persisted session (PKCE / implicit), same as `supabase.auth.session(from:)` in Expo examples.
    func exchangeSessionFromAuthCallback(url: URL) async throws -> Session {
        guard let client else { throw AuthSessionError.notConfigured }
        return try await client.auth.session(from: url)
    }

    func sendPasswordReset(email: String) async throws {
        guard let client else { throw AuthSessionError.notConfigured }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.auth.resetPasswordForEmail(trimmed, redirectTo: AppConfig.supabaseAuthRedirectURL)
    }

    func currentSession() async -> Session? {
        guard let client else { return nil }
        return try? await client.auth.session
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> Session {
        guard let client else { throw AuthSessionError.notConfigured }
        return try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken,
                accessToken: nil,
                nonce: rawNonce
            )
        )
    }

    func signInWithGoogle() async throws -> Session {
        guard let client else { throw AuthSessionError.notConfigured }
        guard AppConfig.isGoogleSignInConfigured else { throw AuthSessionError.googleNotConfigured }
        guard let presenter = UIWindowScene.keyPresenter else { throw AuthSessionError.missingPresenter }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            let user = result.user
            guard let idToken = user.idToken?.tokenString else { throw AuthSessionError.missingGoogleTokens }
            let accessToken = user.accessToken.tokenString

            return try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .google,
                    idToken: idToken,
                    accessToken: accessToken,
                    nonce: nil
                )
            )
        } catch {
            let ns = error as NSError
            if ns.domain == "com.google.GIDSignIn", ns.code == -5 {
                throw AuthSessionError.googleCancelled
            }
            throw error
        }
    }

    func signInWithEmailPassword(email: String, password: String) async throws -> Session {
        guard let client else { throw AuthSessionError.notConfigured }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await client.auth.signIn(email: trimmedEmail, password: password)
    }

    func signUpWithEmailPassword(email: String, password: String, displayName: String?) async throws -> EmailPasswordSignUpResult {
        guard let client else { throw AuthSessionError.notConfigured }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata: [String: AnyJSON]?
        if let trimmedName, !trimmedName.isEmpty {
            metadata = [
                "full_name": .string(trimmedName),
                "display_name": .string(trimmedName),
            ]
        }
        let response = try await client.auth.signUp(
            email: trimmedEmail,
            password: password,
            data: metadata
        )
        if let session = response.session {
            return .signedIn(session)
        }
        return .needsEmailConfirmation
    }

    /// Ensures a `profiles` row exists for the signed-in user (matches Expo `ensureProfile`).
    func ensureProfileExists(for session: Session) async {
        guard let client else { return }
        let user = session.user
        let userId = user.id
        do {
            let existing: [ProfileIdRow] = try await client
                .from("profiles")
                .select("id")
                .eq("id", value: userId.uuidString)
                .execute()
                .value
            if !existing.isEmpty { return }

            let email = user.email ?? ""
            let displayName = Self.displayNameFromUserMetadata(user)
            let username = try await pickUsername(forEmail: email, userId: userId, client: client)
            let row = NewProfileRow(
                id: userId,
                username: username,
                display_name: displayName,
                avatar_url: nil,
                bio: nil,
                default_pin_color: ProfileDefaults.defaultPinColorHex,
                updated_at: ProfileTimestamp.isoFormatter.string(from: Date())
            )
            do {
                try await client.from("profiles").insert(row).execute()
            } catch {
                // Concurrent insert / unique violation (23505) — same as Expo `ensureProfile`.
            }
        } catch {
            return
        }
    }

    private static func displayNameFromUserMetadata(_ user: User) -> String? {
        let keys = ["display_name", "full_name", "name"]
        for key in keys {
            if let raw = user.userMetadata[key]?.stringValue {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func pickUsername(forEmail email: String, userId: UUID, client: SupabaseClient) async throws -> String {
        let base = Self.suggestUsernameFromEmail(email)
        let rows: [ProfileIdRow] = try await client
            .from("profiles")
            .select("id")
            .eq("username", value: base)
            .execute()
            .value
        if rows.isEmpty { return base }
        if rows.count == 1, rows[0].id == userId { return base }
        let suffix = String(userId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        return "\(base)_\(suffix)"
    }

    private static func suggestUsernameFromEmail(_ email: String) -> String {
        let localPart = email.split(separator: "@").first.map(String.init) ?? ""
        let trimmed = localPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" {
                return character
            }
            return "_"
        }
        var cleaned = String(mapped)
        while cleaned.contains("__") {
            cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let capped = String(cleaned.prefix(24))
        return capped.isEmpty ? "traveler" : capped
    }

    func fetchProfile(for session: Session) async throws -> (displayName: String?, email: String) {
        guard let client else { throw AuthSessionError.notConfigured }
        let userId = session.user.id
        let email = session.user.email ?? ""

        do {
            let row: ProfileRow = try await client
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            return (row.displayName, email)
        } catch {
            // Row may not exist yet (DB trigger race) or RLS edge case — still allow sign-in.
            return (nil, email)
        }
    }

    func updateDisplayName(_ name: String, userId: UUID) async throws {
        guard let client else { throw AuthSessionError.notConfigured }
        struct UpdatePayload: Encodable {
            let display_name: String
        }
        try await client
            .from("profiles")
            .update(UpdatePayload(display_name: name))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    func signOut() async throws {
        GIDSignIn.sharedInstance.signOut()
        guard let client else { return }
        try await client.auth.signOut(scope: .global)
    }
}

extension UIWindowScene {
    static var keyPresenter: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return nil }
        let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        guard let root = window?.rootViewController else { return nil }
        return root.topMost
    }
}

private extension UIViewController {
    var topMost: UIViewController {
        if let presented = presentedViewController { return presented.topMost }
        if let nav = self as? UINavigationController, let visible = nav.visibleViewController {
            return visible.topMost
        }
        if let tab = self as? UITabBarController, let selected = tab.selectedViewController {
            return selected.topMost
        }
        return self
    }
}


// =============================================================================

