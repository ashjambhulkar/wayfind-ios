//
//  UserProfileDetail.swift
//  wayfind
//
//  Mirrors Expo `Profile` row fields used on the profile hero.
//

import Foundation

struct UserProfileDetail: Equatable, Sendable {
    let id: UUID
    let username: String
    let displayName: String?
    let avatarURLString: String?
    let bio: String?
    let preferredAirport: String?
    let preferredCurrency: String?
    let createdAt: Date?

    var avatarURL: URL? {
        guard let avatarURLString, let url = URL(string: avatarURLString), !avatarURLString.isEmpty else {
            return nil
        }
        return url
    }
}

enum ProfileHeroFormatting {
    /// Primary line: display name if set, else username (no @), else email.
    static func primaryLine(detail: UserProfileDetail?, email: String) -> String {
        if let dn = detail?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !dn.isEmpty {
            return dn
        }
        if let u = detail?.username.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            return u.hasPrefix("@") ? String(u.dropFirst()) : u
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEmail.isEmpty ? "—" : trimmedEmail
    }

    /// Username line below display name (only when both are present).
    static func usernameLine(detail: UserProfileDetail?) -> String? {
        guard let detail else { return nil }
        let dn = detail.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !dn.isEmpty else { return nil }
        let u = detail.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return nil }
        return u.hasPrefix("@") ? u : "@\(u)"
    }

    static func joinedSubtitle(createdAt: Date?) -> String? {
        guard let createdAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return "Joined \(formatter.string(from: createdAt))"
    }

    /// Expo `formatProfileTripSummaryLine`.
    static func tripSummaryLine(tripCount: Int, upcomingOrActiveCount: Int) -> String {
        if tripCount == 0 { return "No trips yet" }
        let tripsWord = tripCount == 1 ? "trip" : "trips"
        if upcomingOrActiveCount <= 0 { return "\(tripCount) \(tripsWord)" }
        return "\(tripCount) \(tripsWord) · \(upcomingOrActiveCount) upcoming"
    }

    static func initialsForHero(detail: UserProfileDetail?, email: String) -> String {
        if let dn = detail?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !dn.isEmpty {
            let parts = dn.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count >= 2 {
                let a = String(parts[0].prefix(1))
                let b = String(parts[1].prefix(1))
                return (a + b).uppercased()
            }
            return String(dn.prefix(2)).uppercased()
        }
        let u = detail?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !u.isEmpty {
            let stripped = u.hasPrefix("@") ? String(u.dropFirst()) : u
            return String(stripped.prefix(2)).uppercased()
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.contains("@") {
            return String(trimmedEmail.prefix(2)).uppercased()
        }
        return "?"
    }
}

