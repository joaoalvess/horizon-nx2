import Foundation
import HorizonLink
import Security

struct KnownHub: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var key: Data
    var name: String
    var lastUsed: Date
}

struct IdentityError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String { "the Keychain returned \(status)" }
}

final class HubStore: @unchecked Sendable {
    private static let hubsKey = "known-hubs"
    private static let service = "dev.joaoalvess.horizon.tv"
    private static let account = "link-identity"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var hubs: [KnownHub]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hubs = defaults.data(forKey: Self.hubsKey).flatMap { try? JSONDecoder().decode([KnownHub].self, from: $0) } ?? []
    }

    var all: [KnownHub] { lock.withLock { hubs.sorted { $0.lastUsed > $1.lastUsed } } }

    func key(for hubId: Data) -> Data? {
        let id = Self.hex(hubId)
        return lock.withLock { hubs.first { $0.id == id }?.key }
    }

    func remember(hubId: Data, key: Data, name: String) {
        let id = Self.hex(hubId)
        lock.withLock {
            hubs.removeAll { $0.id == id }
            hubs.append(KnownHub(id: id, key: key, name: name, lastUsed: Date()))
            save()
        }
    }

    func touch(_ id: String) {
        lock.withLock {
            guard let index = hubs.firstIndex(where: { $0.id == id }) else { return }
            hubs[index].lastUsed = Date()
            save()
        }
    }

    func forget(_ id: String) {
        lock.withLock {
            hubs.removeAll { $0.id == id }
            save()
        }
    }

    func identity() throws -> LinkIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try LinkIdentity(rawRepresentation: data) }
        guard status == errSecItemNotFound else { throw IdentityError(status: status) }
        let identity = LinkIdentity()
        let entry: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: identity.rawRepresentation,
        ]
        let added = SecItemAdd(entry as CFDictionary, nil)
        guard added == errSecSuccess else { throw IdentityError(status: added) }
        return identity
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func save() {
        guard let data = try? JSONEncoder().encode(hubs) else { return }
        defaults.set(data, forKey: Self.hubsKey)
    }
}
