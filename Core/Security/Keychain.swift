import Foundation
import Security

/// Generic-password Keychain storage. Credentials use one item per adapter id.
enum Keychain {
    static let credentialsService = "com.skrrtin69.mediadeck.credentials"
    static let pinService = "com.skrrtin69.mediadeck.pin"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Couldn't access the secure Keychain (code \(status): \(msg))."
        }
    }

    static func set(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func get(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    // MARK: Credentials

    static func credentials(for adapterID: String) throws -> Credentials? {
        guard let d = try get(service: credentialsService, account: adapterID) else { return nil }
        return try JSONDecoder().decode(Credentials.self, from: d)
    }

    static func setCredentials(_ c: Credentials?, for adapterID: String) throws {
        if let c = c {
            try set(try JSONEncoder().encode(c), service: credentialsService, account: adapterID)
        } else {
            try delete(service: credentialsService, account: adapterID)
        }
    }
}
