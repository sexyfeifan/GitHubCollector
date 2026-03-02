import Foundation
import Security

/// Minimal Keychain helper for storing secrets (GitHub/OpenAI tokens).
/// Keys are scoped under service `com.sexyfeifan.GitHubCollector`.
struct KeychainStore {
    static let service = "com.sexyfeifan.GitHubCollector"

    static func set(_ value: String, for key: String) {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}

