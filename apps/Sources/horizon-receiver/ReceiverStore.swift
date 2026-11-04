import Foundation
import HorizonLink

final class ReceiverStore: @unchecked Sendable {
    struct KnownHub: Codable {
        var id: String
        var key: String
        var name: String
        var pairedAt: Date
    }

    let directory: String
    private let lock = NSLock()
    private var hubs: [KnownHub]

    init() throws {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw OptionError(message: "no Application Support folder")
        }
        directory = support.appendingPathComponent("HorizonReceiver").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory + "/hubs.json"
        if let data = FileManager.default.contents(atPath: path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            hubs = (try? decoder.decode([KnownHub].self, from: data)) ?? []
        } else {
            hubs = []
        }
    }

    func identity() throws -> LinkIdentity {
        let path = directory + "/identity"
        if let data = FileManager.default.contents(atPath: path) {
            guard let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OptionError(message: "\(path) is not a valid key; delete the file to make a new one and pair again")
            }
            chmod(path, 0o600)
            return try LinkIdentity(rawRepresentation: raw)
        }
        let identity = LinkIdentity()
        try write(Data(identity.rawRepresentation.base64EncodedString().utf8), to: path)
        return identity
    }

    func key(for hubId: Data) -> Data? {
        let id = Self.hex(hubId)
        return lock.withLock { hubs.first { $0.id == id } }.flatMap { Data(base64Encoded: $0.key) }
    }

    func remember(hubId: Data, key: Data, name: String) throws {
        let id = Self.hex(hubId)
        let data = try lock.withLock { () -> Data in
            hubs.removeAll { $0.id == id }
            hubs.append(KnownHub(id: id, key: key.base64EncodedString(), name: name, pairedAt: Date()))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(hubs)
        }
        try write(data, to: directory + "/hubs.json")
    }

    private func write(_ data: Data, to path: String) throws {
        let temporary = path + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw OptionError(message: "could not write \(temporary)")
        }
        guard rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw OptionError(message: "could not write \(path): \(reason)")
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
