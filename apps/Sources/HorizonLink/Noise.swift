import CryptoKit
import Foundation

public enum NoiseRole: Sendable {
    case initiator
    case responder
}

public enum NoiseError: Error, Equatable, Sendable, CustomStringConvertible {
    case outOfOrder
    case handshakeFailed
    case truncated
    case invalidPublicKey
    case authenticationFailed
    case messageTooLarge
    case nonceExhausted

    public var description: String {
        switch self {
        case .outOfOrder: "Noise call out of order"
        case .handshakeFailed: "the Noise handshake already failed"
        case .truncated: "Noise message truncated"
        case .invalidPublicKey: "invalid Curve25519 public key"
        case .authenticationFailed: "Noise message failed authentication"
        case .messageTooLarge: "Noise message over \(NoiseCipherState.maxMessageSize) bytes"
        case .nonceExhausted: "Noise nonce exhausted"
        }
    }
}

enum Noise {
    static let hashSize = 32
    static let keySize = 32

    static func initialHash(protocolName: String) -> Data {
        let name = Data(protocolName.utf8)
        guard name.count <= hashSize else { return Data(SHA256.hash(data: name)) }
        return name + Data(count: hashSize - name.count)
    }

    static func hash(_ first: Data, _ second: Data) -> Data {
        var hash = SHA256()
        hash.update(data: first)
        hash.update(data: second)
        return Data(hash.finalize())
    }

    static func hmac(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func hkdf(chainingKey: Data, input: Data) -> (Data, Data) {
        let temp = hmac(key: chainingKey, input)
        let first = hmac(key: temp, Data([1]))
        let second = hmac(key: temp, first + Data([2]))
        return (first, second)
    }

    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var writer = ByteWriter(capacity: 12)
        writer.u32(0)
        writer.u64(counter)
        return try ChaChaPoly.Nonce(data: writer.data)
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, counter: UInt64, ad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(counter), authenticating: ad)
        return box.ciphertext + box.tag
    }

    static func open(_ ciphertext: Data, key: SymmetricKey, counter: UInt64, ad: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce(counter), ciphertext: ciphertext.dropLast(NoiseCipherState.tagSize), tag: ciphertext.suffix(NoiseCipherState.tagSize)
        )
        return try ChaChaPoly.open(box, using: key, authenticating: ad)
    }
}

public struct NoiseCipherState: Sendable {
    public static let maxMessageSize = 65535
    public static let tagSize = 16

    private let key: SymmetricKey?
    private(set) var nonce: UInt64

    init(key: SymmetricKey? = nil, nonce: UInt64 = 0) {
        self.key = key
        self.nonce = nonce
    }

    public mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return plaintext }
        guard plaintext.count <= Self.maxMessageSize - Self.tagSize else { throw NoiseError.messageTooLarge }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let ciphertext = try Noise.seal(plaintext, key: key, counter: nonce, ad: ad)
        nonce += 1
        return ciphertext
    }

    public mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count <= Self.maxMessageSize else { throw NoiseError.messageTooLarge }
        guard ciphertext.count >= Self.tagSize else { throw NoiseError.truncated }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let plaintext: Data
        do {
            plaintext = try Noise.open(ciphertext, key: key, counter: nonce, ad: ad)
        } catch {
            throw NoiseError.authenticationFailed
        }
        nonce += 1
        return plaintext
    }
}

struct NoiseSymmetricState: Sendable {
    private(set) var cipher = NoiseCipherState()
    private(set) var chainingKey: Data
    private(set) var hash: Data

    init(protocolName: String) {
        hash = Noise.initialHash(protocolName: protocolName)
        chainingKey = hash
    }

    mutating func mixHash(_ data: Data) {
        hash = Noise.hash(hash, data)
    }

    mutating func mixKey(_ input: Data) {
        let (chainingKey, key) = Noise.hkdf(chainingKey: chainingKey, input: input)
        self.chainingKey = chainingKey
        cipher = NoiseCipherState(key: SymmetricKey(data: key))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(plaintext, ad: hash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ciphertext, ad: hash)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (SymmetricKey, SymmetricKey) {
        let (first, second) = Noise.hkdf(chainingKey: chainingKey, input: Data())
        return (SymmetricKey(data: first), SymmetricKey(data: second))
    }
}

public struct NoiseHandshake: Sendable {
    public static let protocolName = "Noise_KK_25519_ChaChaPoly_SHA256"
    static let messageOverhead = Noise.keySize + NoiseCipherState.tagSize

    private enum Key: Sendable {
        case ephemeral
        case `static`
    }

    private enum Token: Sendable {
        case e
        case dh(initiator: Key, responder: Key)
    }

    private static let pattern: [[Token]] = [
        [.e, .dh(initiator: .ephemeral, responder: .static), .dh(initiator: .static, responder: .static)],
        [.e, .dh(initiator: .ephemeral, responder: .ephemeral), .dh(initiator: .static, responder: .ephemeral)],
    ]

    public let role: NoiseRole
    private var symmetric: NoiseSymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let localEphemeral: Curve25519.KeyAgreement.PrivateKey
    private let remoteStatic: Curve25519.KeyAgreement.PublicKey
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private var messageIndex = 0
    private var failed = false
    private var didSplit = false

    public init(
        role: NoiseRole, localStatic: Curve25519.KeyAgreement.PrivateKey, remoteStatic: Curve25519.KeyAgreement.PublicKey,
        prologue: Data, localEphemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) {
        self.role = role
        self.localStatic = localStatic
        self.localEphemeral = localEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
        self.remoteStatic = remoteStatic
        symmetric = NoiseSymmetricState(protocolName: Self.protocolName)
        symmetric.mixHash(prologue)
        let initiatorStatic = role == .initiator ? localStatic.publicKey : remoteStatic
        let responderStatic = role == .initiator ? remoteStatic : localStatic.publicKey
        symmetric.mixHash(initiatorStatic.rawRepresentation)
        symmetric.mixHash(responderStatic.rawRepresentation)
    }

    public var isFinished: Bool { !failed && messageIndex == Self.pattern.count }

    public mutating func writeMessage(payload: Data = Data()) throws -> Data {
        try checkTurn(writing: true)
        guard payload.count <= NoiseCipherState.maxMessageSize - Self.messageOverhead else { throw NoiseError.messageTooLarge }
        do {
            var writer = ByteWriter(capacity: payload.count + Self.messageOverhead)
            for token in Self.pattern[messageIndex] {
                switch token {
                case .e:
                    let key = localEphemeral.publicKey.rawRepresentation
                    writer.bytes(key)
                    symmetric.mixHash(key)
                case .dh(let initiator, let responder):
                    symmetric.mixKey(try agreement(initiator: initiator, responder: responder))
                }
            }
            writer.bytes(try symmetric.encryptAndHash(payload))
            messageIndex += 1
            return writer.data
        } catch {
            failed = true
            throw error
        }
    }

    public mutating func readMessage(_ message: Data) throws -> Data {
        try checkTurn(writing: false)
        do {
            guard message.count <= NoiseCipherState.maxMessageSize else { throw NoiseError.messageTooLarge }
            var reader = ByteReader(message)
            for token in Self.pattern[messageIndex] {
                switch token {
                case .e:
                    guard reader.remaining >= Noise.keySize else { throw NoiseError.truncated }
                    let key = try reader.bytes(Noise.keySize)
                    remoteEphemeral = try Self.publicKey(key)
                    symmetric.mixHash(key)
                case .dh(let initiator, let responder):
                    symmetric.mixKey(try agreement(initiator: initiator, responder: responder))
                }
            }
            let payload = try symmetric.decryptAndHash(reader.rest())
            messageIndex += 1
            return payload
        } catch {
            failed = true
            throw error
        }
    }

    public mutating func split() throws -> NoiseSession {
        guard !failed else { throw NoiseError.handshakeFailed }
        guard isFinished, !didSplit else { throw NoiseError.outOfOrder }
        didSplit = true
        let (first, second) = symmetric.split()
        return role == .initiator
            ? NoiseSession(handshakeHash: symmetric.hash, sendKey: first, receiveKey: second)
            : NoiseSession(handshakeHash: symmetric.hash, sendKey: second, receiveKey: first)
    }

    private func checkTurn(writing: Bool) throws {
        guard !failed else { throw NoiseError.handshakeFailed }
        let initiatorWrites = messageIndex.isMultiple(of: 2)
        guard messageIndex < Self.pattern.count, writing == (initiatorWrites == (role == .initiator)) else {
            throw NoiseError.outOfOrder
        }
    }

    private func agreement(initiator: Key, responder: Key) throws -> Data {
        let local = role == .initiator ? initiator : responder
        let remote = role == .initiator ? responder : initiator
        let privateKey = local == .ephemeral ? localEphemeral : localStatic
        guard let publicKey = remote == .ephemeral ? remoteEphemeral : remoteStatic else { throw NoiseError.outOfOrder }
        do {
            return try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        } catch {
            throw NoiseError.invalidPublicKey
        }
    }

    private static func publicKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        } catch {
            throw NoiseError.invalidPublicKey
        }
    }
}

public struct NoiseSession: Sendable {
    static let datagramInfo = Data("horizon datagram".utf8)

    public let handshakeHash: Data
    public var sender: NoiseCipherState
    public var receiver: NoiseCipherState
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey

    init(handshakeHash: Data, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.handshakeHash = handshakeHash
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        sender = NoiseCipherState(key: sendKey)
        receiver = NoiseCipherState(key: receiveKey)
    }

    public func datagramKeys() -> (send: SymmetricKey, receive: SymmetricKey) {
        (datagramKey(from: sendKey), datagramKey(from: receiveKey))
    }

    private func datagramKey(from key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: handshakeHash, info: Self.datagramInfo, outputByteCount: Noise.keySize)
    }
}
