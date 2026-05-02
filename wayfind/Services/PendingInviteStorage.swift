//
//  PendingInviteStorage.swift
//  wayfind
//
//  Keychain-backed buffer for an invite token captured BEFORE the user is
//  signed in. The flow:
//
//    1. User taps a `wayfind://invite/<token>` link from Messages.
//    2. App is signed-out — `InviteAcceptView` opens, user taps Join.
//    3. We call `set(token:)` to persist the token in Keychain.
//    4. We push the user to the sign-in flow.
//    5. After auth, `AuthViewModel.applySession` surfaces the token via
//       a small drain helper (see `wayfindApp.swift`) and the root view
//       re-presents `InviteAcceptView` — this time signed-in — which
//       calls `acceptInvite` and on success calls `clear()`.
//
//  Why Keychain and not UserDefaults: invite tokens are sensitive
//  collaboration credentials that grant write access to a trip. They
//  should not roam to other apps via App Group defaults or sync to
//  iCloud unintentionally. Keychain with `kSecAttrAccessibleAfterFirstUnlock`
//  is the standard iOS pattern for "unlock-bound device-local secret".
//
//  CRITICAL: this storage is NOT cleared on sign-out. A user could sign
//  out mid-accept-flow (e.g. they signed into the wrong account, want to
//  switch). The token must survive across the auth state change so the
//  fresh sign-in flow can resume the join.
//

import Foundation
import Security

enum PendingInviteStorage {
    private static let service = "wayfind.invites"
    private static let account = "wayfind.pending_invite_token"

    /// Persist the invite token. Overwrites any existing value (if a user
    /// taps a second invite link before resolving the first one, the
    /// newest wins — matches how Messages "Open Link" behaves elsewhere).
    static func set(token: String) {
        guard let data = token.data(using: .utf8) else { return }
        // Try to update first; fall back to add if no row yet exists.
        // This avoids the SecItemAdd → errSecDuplicateItem → SecItemUpdate
        // dance.
        let updateAttributes: [CFString: Any] = [kSecValueData: data]
        let updateQuery: [CFString: Any] = baseQuery()
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        var addQuery = baseQuery()
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Read the persisted invite token, if any.
    static func get() -> String? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the persisted invite token. Called on successful accept (and
    /// only on successful accept — explicit decline paths should also
    /// call this to avoid the user being prompted again on next launch).
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
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
