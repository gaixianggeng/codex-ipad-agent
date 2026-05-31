import Foundation
import Security

enum TokenStoreError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "保存 Token 失败：\(status)"
        case .deleteFailed(let status):
            return "删除 Token 失败：\(status)"
        }
    }
}

struct TokenStore {
    private let service = "com.gaixiaotongxue.CodexAgentPad"
    private let account = "agentd-token"

    func load() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func save(_ token: String) throws {
        try delete(allowMissing: true)
        var item = baseQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError.saveFailed(status)
        }
    }

    func delete(allowMissing: Bool = false) throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound && allowMissing {
            return
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.deleteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
