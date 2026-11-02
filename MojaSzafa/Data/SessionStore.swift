import Foundation
import Security

@MainActor
protocol SessionStore {
    func read() throws -> AuthSession?
    func write(_ session: AuthSession) throws
    func clear() throws
}

/// Per-installation, device-only credentials; never UserDefaults or iCloud.
@MainActor
struct KeychainSessionStore: SessionStore {
    let service: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "authentication-session"]
    }
    func read() throws -> AuthSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AuthError.storage }
        do { return try JSONDecoder().decode(AuthSession.self, from: data) }
        catch { throw AuthError.storage }
    }
    func write(_ session: AuthSession) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, new in new }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw AuthError.storage }
        } else if status != errSecSuccess { throw AuthError.storage }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthError.storage }
    }
}
