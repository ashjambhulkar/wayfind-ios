//
//  InviteDeepLink.swift
//  wayfind
//
//  Pure helper that extracts an invite token from a `wayfind://invite/<token>`
//  URL. Lives in `Services/` rather than `Models/` because it's a string
//  operation, not data.
//
//  v1 supports only the custom-scheme URL (`wayfind://invite/...`). v2 will
//  add `https://wayfind.city/invite/<token>` once the backend ships
//  associated-domains entitlements + the apple-app-site-association file
//  on the wayfind.city web side. The web page that lives at that HTTPS
//  URL is responsible for redirecting back to `wayfind://invite/<token>`
//  on iOS, so v1 still works end-to-end as long as the recipient has the
//  app installed.
//
//  Why we share the HTTPS URL but only handle the custom-scheme one:
//  Messages, Mail, and Slack all preview HTTPS URLs nicely (rich card,
//  expanded preview); a `wayfind://` URL renders as raw text in those
//  apps and looks broken. The HTTPS landing page is the social signal;
//  the deep link is the technical handoff.
//

import Foundation

enum InviteDeepLink {
    /// Build the URL we hand to `ShareLink` — the public, cross-platform
    /// landing page. Recipients on Android, web, or iOS-without-the-app
    /// see a useful page; iOS users with the app are bounced back into
    /// the app via JS redirect on the web side.
    static func shareableURL(for token: String) -> URL? {
        URL(string: "https://wayfind.city/invite/\(token)")
    }

    /// Build the `wayfind://invite/<token>` URL that the iOS app actually
    /// handles. Used for in-process re-presentation of an invite (e.g.
    /// after sign-in completes and we need to re-trigger the accept flow).
    static func appDeepLinkURL(for token: String) -> URL? {
        URL(string: "wayfind://invite/\(token)")
    }

    /// Does this URL look like an invite link the app should handle?
    /// Strict matching prevents collision with `wayfind://auth/callback`.
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "wayfind" else { return false }
        // Custom URL scheme components: scheme://host/path. With
        // `wayfind://invite/<token>` host is "invite". Some Apple URL
        // parsers trim the host into pathComponents instead — handle both
        // shapes defensively.
        if url.host?.lowercased() == "invite" {
            return token(from: url) != nil
        }
        // Fallback: the path-only shape `wayfind:invite/<token>`.
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.lowercased().hasPrefix("invite/") {
            return token(from: url) != nil
        }
        return false
    }

    /// Extract the token segment, if any.
    static func token(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "wayfind" else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        // Shape A — host=invite, pathComponents=["<token>"]
        if url.host?.lowercased() == "invite", let first = pathComponents.first {
            let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        // Shape B — pathComponents=["invite", "<token>"]
        if pathComponents.count >= 2,
           pathComponents[0].lowercased() == "invite" {
            let t = pathComponents[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }
}


// =============================================================================
