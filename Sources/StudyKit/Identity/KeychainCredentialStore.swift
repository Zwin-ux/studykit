#if canImport(Security)
import Foundation
import Security

/// Keeps the Apple user identifier in the Keychain. Pass the shared access group
/// (`<TeamID>.com.bonelli.study`) so Nursebook and One More Shift read the same sign-in.
public struct KeychainCredentialStore: CredentialStore {
    public struct Failure: Error, Equatable { public let status: OSStatus }
    private let service: String
    private let accessGroup: String?
    private let account = "apple-user-id"

    public init(service: String = "com.bonelli.study.identity", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func load() throws -> StudyUser? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data, let id = String(data: data, encoding: .utf8), !id.isEmpty else { return nil }
        return StudyUser(id: id)
    }

    public func save(_ user: StudyUser) throws {
        let data = Data(user.id.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Readable after first unlock so a background sync can attribute events; never leaves the device set.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
#endif
