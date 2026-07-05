import Cocoa
import CoreLocation
import LocalAuthentication
import Security
import WebKit

// MARK: - Password vault (Keychain)
//
// Login credentials live only in the login keychain as kSecClassInternetPassword
// items, keyed by host. Local-to-this-device (kSecAttrAccessibleWhenUnlocked-
// ThisDeviceOnly) — no iCloud sync in this tier, no keychain-access-groups
// entitlement, so it works on an ad-hoc-signed build. This is the only path a
// third-party macOS WKWebView has: Safari's native AutoFill and the system
// Passwords app are not vended to us.
enum Vault {
    struct Credential { let username: String; let password: String }

    private static func query(host: String, account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    /// Upsert a credential for host+username.
    @discardableResult
    static func save(host: String, username: String, password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let base = query(host: host, account: username)
        let update = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// All stored credentials for a host. Done in two steps because the macOS
    /// file keychain rejects kSecMatchLimitAll combined with kSecReturnData
    /// (errSecParam): first list the accounts (attributes only), then fetch each
    /// password with a single-item query.
    static func lookup(host: String) -> [Credential] {
        var q = query(host: host)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item -> Credential? in
            guard let acct = item[kSecAttrAccount as String] as? String,
                  let pw = password(host: host, account: acct) else { return nil }
            return Credential(username: acct, password: pw)
        }
    }

    /// Fetch a single password value for host+account.
    private static func password(host: String, account: String) -> String? {
        var q = query(host: host, account: account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(host: String, username: String) {
        SecItemDelete(query(host: host, account: username) as CFDictionary)
    }

    /// Every stored login (host + username), for the settings Passwords list.
    /// Attributes only — passwords are fetched on demand behind auth.
    static func allEntries() -> [(host: String, username: String)] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item -> (String, String)? in
            guard let host = item[kSecAttrServer as String] as? String,
                  let acct = item[kSecAttrAccount as String] as? String else { return nil }
            return (host, acct)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
    }

    /// Public single-password read (settings reveal, gated by Touch ID upstream).
    static func reveal(host: String, username: String) -> String? {
        password(host: host, account: username)
    }
}
