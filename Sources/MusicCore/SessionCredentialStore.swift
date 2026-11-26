import Foundation
import Security

/// 钥匙串中的会话记录。QQ 登录使用 value 封装账号资料和音乐会话凭据。
public struct StoredSessionCredential: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var expiresAt: Date
    public var secure: Bool

    public init(name: String, value: String, expiresAt: Date, secure: Bool) {
        self.name = name
        self.value = value
        self.expiresAt = expiresAt
        self.secure = secure
    }
}

public enum SessionCredentialStoreError: Error {
    case unavailable
    case invalidData
}

/// 方法同步执行，让认证 actor 可以原子地处理注销及迟到响应。
public protocol SessionCredentialStore: Sendable {
    func load(origin: String) throws -> StoredSessionCredential?
    func save(_ credential: StoredSessionCredential, origin: String) throws
    func delete(origin: String) throws
}

public struct KeychainSessionCredentialStore: SessionCredentialStore {
    private let service: String

    public init(service: String = "local.ipplemusic.application-session.v1") { self.service = service }

    private func query(origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin,
         kSecAttrSynchronizable as String: false]
    }

    public func load(origin: String) throws -> StoredSessionCredential? {
        var query = query(origin: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SessionCredentialStoreError.unavailable }
        guard let data = result as? Data,
            let credential = try? JSONDecoder().decode(StoredSessionCredential.self, from: data)
        else { throw SessionCredentialStoreError.invalidData }
        return credential
    }

    public func save(_ credential: StoredSessionCredential, origin: String) throws {
        let data = try JSONEncoder().encode(credential)
        let query = query(origin: origin)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SessionCredentialStoreError.unavailable
            }
        } else if status != errSecSuccess {
            throw SessionCredentialStoreError.unavailable
        }
    }

    public func delete(origin: String) throws {
        let status = SecItemDelete(query(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionCredentialStoreError.unavailable
        }
    }
}
