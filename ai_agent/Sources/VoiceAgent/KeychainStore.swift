import Foundation
import Security

struct KeychainStore {
    private let service = "com.local.voiceagent.gemini"
    private let account = "api-key"

    func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        } else {
            var add = query
            add[kSecValueData as String] = data
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))" }
}
