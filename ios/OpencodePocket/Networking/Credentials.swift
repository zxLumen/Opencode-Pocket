import Foundation
import Security

/// Stores the server URL + username in UserDefaults and the password in the Keychain.
enum Credentials {
    private static let urlKey = "opencode.pocket.baseURL"
    private static let userKey = "opencode.pocket.username"
    private static let service = "cn.zxlumen.opencodepocket"
    private static let account = "server-password"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    static var username: String {
        get { UserDefaults.standard.string(forKey: userKey) ?? "opencode" }
        set { UserDefaults.standard.set(newValue, forKey: userKey) }
    }

    static var password: String {
        get { (try? readKeychain()) ?? "" }
        set { try? writeKeychain(newValue) }
    }

    static var isConfigured: Bool { !baseURL.isEmpty && !password.isEmpty }

    private static func writeKeychain(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { throw NSError(domain: service, code: Int(status)) }
    }

    private static func readKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
