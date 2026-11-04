import Foundation
import HorizonLink

public struct PairedClient: Codable, Sendable, Equatable, Identifiable {
    public var key: Data
    public var name: String
    public var pairedAt: Date
    public var lastSeen: Date?

    public var id: Data { key }

    public init(key: Data, name: String, pairedAt: Date = Date(), lastSeen: Date? = nil) {
        self.key = key
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }
}

public final class PairingStore: @unchecked Sendable {
    public static let keychain = Keychain(service: "dev.joaoalvess.horizon.hub", account: "link-identity")

    public let file: String
    private let lock = NSLock()
    private var clients: [PairedClient]

    public init(file: String) {
        self.file = file
        let data = FileManager.default.contents(atPath: file)
        clients = data.flatMap { try? Self.decoder.decode([PairedClient].self, from: $0) } ?? []
    }

    public static func identity(keychain: Keychain = PairingStore.keychain) throws -> LinkIdentity {
        if let stored = try keychain.read(interactive: false) {
            guard let raw = Data(base64Encoded: stored) else { throw GamesError.unavailable("the link identity in the keychain is not base64") }
            return try LinkIdentity(rawRepresentation: raw)
        }
        let identity = LinkIdentity()
        try keychain.create(identity.rawRepresentation.base64EncodedString(), label: "HorizonHub: game hub identity")
        return identity
    }

    public var all: [PairedClient] { lock.withLock { clients } }

    public func isPaired(_ key: Data) -> Bool { lock.withLock { clients.contains { $0.key == key } } }

    public func client(_ key: Data) -> PairedClient? { lock.withLock { clients.first { $0.key == key } } }

    public func add(key: Data, name: String) throws {
        try lock.withLock {
            clients.removeAll { $0.key == key }
            clients.append(PairedClient(key: key, name: name))
            try save()
        }
    }

    public func remove(key: Data) throws {
        try lock.withLock {
            clients.removeAll { $0.key == key }
            try save()
        }
    }

    public func touch(key: Data, at date: Date = Date()) {
        lock.withLock {
            guard let index = clients.firstIndex(where: { $0.key == key }) else { return }
            clients[index].lastSeen = date
            try? save()
        }
    }

    private func save() throws {
        let directory = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(clients)
        let temporary = file + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw GamesError.unavailable("\(temporary) could not be written")
        }
        guard rename(temporary, file) == 0 else { throw GamesError.unavailable("\(file) could not be replaced: \(GuardState.errorText())") }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
