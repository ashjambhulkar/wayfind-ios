//
//  InviteWelcomeStorage.swift
//  wayfind
//
//  Tracks which trips have already shown the `InviteeWelcomeSheet` to the
//  current user. The welcome sheet is a one-time celebration — confetti +
//  feature tour — and showing it twice would feel patronising.
//
//  Stored per-trip so a user who joins three different trips gets three
//  individual welcomes. The set is keyed by trip UUID so we can `contains`
//  in O(1).
//
//  Why Keychain instead of UserDefaults: a malicious / curious second
//  app on the same device would know which trips this user has joined
//  if the data were in `UserDefaults`. Also, Keychain survives app
//  uninstall on iOS for a small window, which is acceptable here.
//

import Foundation
import Security

enum InviteWelcomeStorage {
    private static let service = "wayfind.invites"
    private static let account = "wayfind.welcomed_trip_ids"

    /// Has the user already seen the welcome sheet for this trip?
    static func hasShown(tripId: UUID) -> Bool {
        loadSet().contains(tripId)
    }

    /// Mark this trip as welcomed so subsequent opens skip the sheet.
    static func markShown(tripId: UUID) {
        var set = loadSet()
        guard !set.contains(tripId) else { return }
        set.insert(tripId)
        save(set: set)
    }

    /// Wipe all welcome history. Currently unused; reserved for the
    /// account settings "Reset onboarding" affordance once it ships.
    static func clearAll() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: - Private

    private static func loadSet() -> Set<UUID> {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return [] }
        guard let raw = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(raw)
    }

    private static func save(set: Set<UUID>) {
        guard let data = try? JSONEncoder().encode(Array(set)) else { return }
        let updateQuery: [CFString: Any] = baseQuery()
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        var addQuery = baseQuery()
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}


// =============================================================================
