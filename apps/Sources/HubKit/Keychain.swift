import Foundation
import Security

public struct Keychain: Sendable {
    public enum Failure: Error, Equatable {
        case status(OSStatus)
        case invalidData
    }

    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(interactive: Bool = true) throws -> String? {
        if !interactive { SecKeychainSetUserInteractionAllowed(false) }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw Failure.invalidData
        }
        return secret
    }

    public func create(_ secret: String, label: String) throws {
        var query = baseQuery
        query[kSecAttrLabel as String] = label
        query[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    public static func generateSecret(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw Failure.status(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
