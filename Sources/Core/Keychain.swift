// Keychain.swift — API tokens in the macOS login keychain, one item per account.
//
// Service is always "roost"; the account attribute is the Account's UUID. That
// keeps the key stable when the user renames an account or moves it to a new
// host, and means two accounts on the same host never collide.
//
// Nothing here ever logs or returns a token in an error message.

import Foundation
import Security

/// Why a token couldn't be read. The distinction matters more than it looks:
/// "no token saved" and "macOS refused to hand it over" have completely
/// different fixes, and collapsing both into nil produced an "expired or
/// revoked token" message that sent the user to GitHub to debug a problem that
/// never left this machine.
enum KeychainError: LocalizedError {
    case missing
    case denied(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "No token saved for this account. Paste one in Settings."
        case .denied(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "macOS blocked access to the saved token (\(detail)). An ad-hoc signed build gets a new code identity every time it is rebuilt, and the Keychain treats that as a different app — run ./setup-signing.sh once, then re-paste the token."
        }
    }
}

enum Keychain {
    static let service = "roost"

    /// Reads the token, reporting *why* when it can't.
    static func read(for accountID: UUID) -> Result<String, KeychainError> {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { return .failure(.missing) }
            return .success(token)
        case errSecItemNotFound:
            return .failure(.missing)
        default:
            // errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            // the item is there, we just weren't allowed to have it.
            return .failure(.denied(status))
        }
    }

    static func token(for accountID: UUID) -> String? {
        try? read(for: accountID).get()
    }

    /// Stores (or replaces) the token. An empty string deletes instead, so the
    /// settings form can treat "cleared the field" as "forget this token".
    @discardableResult
    static func setToken(_ token: String, for accountID: UUID) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteToken(for: accountID)
            return true
        }

        let data = Data(trimmed.utf8)
        // Try an in-place update first; it preserves the item's ACL, so macOS
        // doesn't re-prompt for access after every token rotation.
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery(accountID) as CFDictionary, update as CFDictionary) == errSecSuccess {
            return true
        }

        // The update can fail for two very different reasons: there is no item
        // yet, or there is one whose ACL names a previous build of this app and
        // this binary isn't on it. Both are fixed the same way — drop whatever
        // is there and write a fresh item owned by the current binary. Bailing
        // out on the second case would leave the user unable to save a token at
        // all, with no way to tell why.
        deleteToken(for: accountID)

        var attrs = baseQuery(accountID)
        attrs[kSecValueData as String] = data
        // Tokens are only needed while the user is logged in and the app is
        // running; no need to make them available before first unlock.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken(for accountID: UUID) {
        SecItemDelete(baseQuery(accountID) as CFDictionary)
    }

    private static func baseQuery(_ accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}
