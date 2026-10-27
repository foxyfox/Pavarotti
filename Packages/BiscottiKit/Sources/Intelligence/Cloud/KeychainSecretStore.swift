import Foundation
import Security

/// Pavarotti: API keys in the login keychain, as generic passwords of the service
/// `de.foxagon.pavarotti.llm`.
public struct KeychainSecretStore: SecretStoring {
    public static let service = "de.foxagon.pavarotti.llm"

    public struct Failure: LocalizedError {
        public let status: OSStatus

        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The keychain refused the API key: \(message)"
        }
    }

    public init() {}

    public func secret(for account: String) -> String? {
        var query = Self.query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String?, for account: String) throws {
        let query = Self.query(for: account)
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Failure(status: deleted) }
        guard let secret, !secret.isEmpty else { return }

        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "Pavarotti \(account) API key"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    private static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
