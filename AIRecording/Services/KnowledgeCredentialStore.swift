import Foundation
import Security

protocol KnowledgeCredentialLoading: Sendable {
    func dashScopeAPIKey() -> String
    func embeddingAPIKey() -> String
    func rerankAPIKey() -> String
    /// 严格读取:仅新账户,不带旧账户回退(openai 供应商不得把旧阿里云 Key 发给第三方端点)。
    func strictEmbeddingAPIKey() -> String
    func strictRerankAPIKey() -> String
}

protocol KnowledgeCredentialStoreProtocol: KnowledgeCredentialLoading {
    func saveEmbeddingAPIKey(_ value: String) throws
    func saveRerankAPIKey(_ value: String) throws
}

struct KnowledgeCredentialStore: KnowledgeCredentialStoreProtocol, Sendable {
    static let service = "com.airecording.knowledge"
    private static let legacyAccount = "dashscope-api-key"
    private static let embeddingAccount = "embedding-api-key"
    private static let rerankAccount = "rerank-api-key"

    private let readAccount: @Sendable (String) -> String?
    private let writeAccount: @Sendable (String, String?) throws -> Void

    /// `read`/`write` 为测试 seam:按账户读写,value 为 nil 表示删除。默认实现走系统钥匙串。
    init(
        read: @escaping @Sendable (String) -> String? = { Self.secItemRead(account: $0) },
        write: @escaping @Sendable (String, String?) throws -> Void = { try Self.secItemWrite(account: $0, value: $1) }
    ) {
        self.readAccount = read
        self.writeAccount = write
    }

    func saveEmbeddingAPIKey(_ value: String) throws {
        try write(account: Self.embeddingAccount, value: value)
    }

    func saveRerankAPIKey(_ value: String) throws {
        try write(account: Self.rerankAccount, value: value)
    }

    /// 旧单账户,保留只读(KnowledgeServiceManager 的 DASHSCOPE_API_KEY 解析兼容用)。
    func dashScopeAPIKey() -> String {
        read(account: Self.legacyAccount)
    }

    /// 新账户为空时回退读旧账户 `dashscope-api-key`(只读回退,不做迁移)。
    func embeddingAPIKey() -> String {
        let value = read(account: Self.embeddingAccount)
        return value.isEmpty ? read(account: Self.legacyAccount) : value
    }

    /// 新账户为空时回退读旧账户 `dashscope-api-key`(只读回退,不做迁移)。
    func rerankAPIKey() -> String {
        let value = read(account: Self.rerankAccount)
        return value.isEmpty ? read(account: Self.legacyAccount) : value
    }

    /// 严格读取:仅新账户,无旧账户回退。
    func strictEmbeddingAPIKey() -> String {
        read(account: Self.embeddingAccount)
    }

    /// 严格读取:仅新账户,无旧账户回退。
    func strictRerankAPIKey() -> String {
        read(account: Self.rerankAccount)
    }

    private func read(account: String) -> String {
        readAccount(account) ?? ""
    }

    private func write(account: String, value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeAccount(account, normalized.isEmpty ? nil : normalized)
    }

    private static func secItemRead(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func secItemWrite(account: String, value: String?) throws {
        let query = baseQuery(account: account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KnowledgeCredentialError.keychain(status)
            }
            return
        }

        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KnowledgeCredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw KnowledgeCredentialError.keychain(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KnowledgeCredentialError: Error, Equatable {
    case keychain(OSStatus)
}
