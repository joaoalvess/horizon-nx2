import CryptoKit
import Foundation

public enum DatagramError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncated
    case unsupportedVersion(UInt8)
    case invalidHeader
    case replayed
    case authenticationFailed
    case counterExhausted

    public var description: String {
        switch self {
        case .truncated: "datagram truncated"
        case .unsupportedVersion(let version): "datagram version \(version) is not supported"
        case .invalidHeader: "datagram header has reserved bits set"
        case .replayed: "datagram replayed or outside the replay window"
        case .authenticationFailed: "datagram failed authentication"
        case .counterExhausted: "datagram counter exhausted"
        }
    }
}

public struct DatagramSealer: Sendable {
    public static let version: UInt8 = 1
    public static let headerSize = 12
    public static let overhead = 28

    private let key: SymmetricKey
    private(set) var counter: UInt64

    public init(key: SymmetricKey) {
        self.init(key: key, counter: 0)
    }

    init(key: SymmetricKey, counter: UInt64) {
        self.key = key
        self.counter = counter
    }

    public mutating func seal(_ plaintext: Data, channel: UInt8) throws -> Data {
        guard counter < .max else { throw DatagramError.counterExhausted }
        var writer = ByteWriter(capacity: Self.overhead + plaintext.count)
        writer.u8(Self.version)
        writer.u8(channel)
        writer.u16(0)
        writer.u64(counter)
        let sealed = try Noise.seal(plaintext, key: key, counter: counter, ad: writer.data)
        writer.bytes(sealed)
        counter += 1
        return writer.data
    }
}

public struct DatagramOpener: Sendable {
    private let key: SymmetricKey
    private var window: ReplayWindow

    public init(key: SymmetricKey, windowSize: Int = 1024) {
        self.key = key
        window = ReplayWindow(size: windowSize)
    }

    public mutating func open(_ datagram: Data) throws -> (channel: UInt8, plaintext: Data) {
        guard datagram.count >= DatagramSealer.overhead else { throw DatagramError.truncated }
        var reader = ByteReader(datagram)
        let header = try reader.bytes(DatagramSealer.headerSize)
        var fields = ByteReader(header)
        let version = try fields.u8()
        let channel = try fields.u8()
        let reserved = try fields.u16()
        let counter = try fields.u64()
        guard version == DatagramSealer.version else { throw DatagramError.unsupportedVersion(version) }
        guard reserved == 0 else { throw DatagramError.invalidHeader }
        guard window.canAccept(counter) else { throw DatagramError.replayed }
        let plaintext: Data
        do {
            plaintext = try Noise.open(reader.rest(), key: key, counter: counter, ad: header)
        } catch {
            throw DatagramError.authenticationFailed
        }
        window.accept(counter)
        return (channel, plaintext)
    }
}
