import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case wrongCommitment
    case outOfOrder
    case badKey
}

public enum Pairing {
    public static let codeDigits = 6
    public static let nonceSize = 32

    public static func newNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func commitment(clientKey: Data, nonce: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("horizon pair commit".utf8))
        hash.update(data: clientKey)
        hash.update(data: nonce)
        return Data(hash.finalize())
    }

    public static func code(clientKey: Data, hubKey: Data, clientNonce: Data, hubNonce: Data) -> String {
        var hash = SHA256()
        hash.update(data: Data("horizon pair sas".utf8))
        hash.update(data: clientKey)
        hash.update(data: hubKey)
        hash.update(data: clientNonce)
        hash.update(data: hubNonce)
        let digest = Array(hash.finalize())
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let text = String(value)
        return String(repeating: "0", count: codeDigits - text.count) + text
    }

    public static func sameCode(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func normalized(_ typed: String) -> String {
        String(typed.filter(\.isASCII).filter(\.isNumber))
    }
}

public struct HubPairingCeremony: Sendable {
    public let hubKey: Data
    public private(set) var hubNonce: Data?
    public private(set) var code: String?
    public private(set) var clientKey: Data?
    private var commitment: Data?

    public init(hubKey: Curve25519.KeyAgreement.PublicKey) {
        self.hubKey = hubKey.rawRepresentation
    }

    public mutating func receiveCommitment(_ commitment: Data) throws -> (hubKey: Data, hubNonce: Data) {
        guard self.commitment == nil, commitment.count == SHA256.byteCount else { throw PairingError.outOfOrder }
        self.commitment = commitment
        let nonce = Pairing.newNonce()
        hubNonce = nonce
        return (hubKey, nonce)
    }

    public mutating func receiveReveal(clientKey: Data, clientNonce: Data) throws -> String {
        guard let commitment, let hubNonce, code == nil else { throw PairingError.outOfOrder }
        guard clientKey.count == 32, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKey)) != nil else {
            throw PairingError.badKey
        }
        guard Pairing.commitment(clientKey: clientKey, nonce: clientNonce) == commitment else { throw PairingError.wrongCommitment }
        let code = Pairing.code(clientKey: clientKey, hubKey: hubKey, clientNonce: clientNonce, hubNonce: hubNonce)
        self.clientKey = clientKey
        self.code = code
        return code
    }

    public func matches(_ typed: String) -> Bool {
        guard let code else { return false }
        return Pairing.sameCode(code, Pairing.normalized(typed))
    }
}

public struct ClientPairingCeremony: Sendable {
    public let clientKey: Data
    public let clientNonce: Data
    public private(set) var hubKey: Data?
    public private(set) var code: String?

    public init(clientKey: Curve25519.KeyAgreement.PublicKey, clientNonce: Data = Pairing.newNonce()) {
        self.clientKey = clientKey.rawRepresentation
        self.clientNonce = clientNonce
    }

    public var commitment: Data { Pairing.commitment(clientKey: clientKey, nonce: clientNonce) }

    public mutating func receiveHub(key: Data, nonce: Data) throws -> String {
        guard hubKey == nil else { throw PairingError.outOfOrder }
        guard key.count == 32, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil, nonce.count == Pairing.nonceSize else {
            throw PairingError.badKey
        }
        hubKey = key
        let code = Pairing.code(clientKey: clientKey, hubKey: key, clientNonce: clientNonce, hubNonce: nonce)
        self.code = code
        return code
    }
}
