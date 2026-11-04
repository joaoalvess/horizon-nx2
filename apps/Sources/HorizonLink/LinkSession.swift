import CryptoKit
import Foundation

public enum LinkError: Error, Equatable, Sendable, CustomStringConvertible {
    case refused(String)
    case violation(String)
    case wrongVersion(UInt16)

    public var description: String {
        switch self {
        case .refused(let reason): reason
        case .violation(let text): "protocol violation: \(text)"
        case .wrongVersion(let version): "the other side speaks link version \(version), this one \(LinkProtocol.version)"
        }
    }
}

public struct LinkIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var hubId: Data { Self.hubId(of: publicKey) }

    public static func hubId(of publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(LinkProtocol.hubIdSize))
    }
}

public struct LinkKeys: Sendable {
    public let peerKey: Data
    public let peerName: String
    public let send: SymmetricKey
    public let receive: SymmetricKey
    public let handshakeHash: Data
}

enum LinkHandshake {
    static func prologue(client: ClientHello, hub: HubHello) -> Data {
        var data = Data("horizon link v1".utf8)
        data.append(ClearMessage.clientHello(client).encoded())
        data.append(ClearMessage.hubHello(hub).encoded())
        return data
    }

    static func publicKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        guard raw.count == LinkProtocol.clientKeySize, let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw LinkError.violation("a \(raw.count)-byte key is not a Curve25519 key")
        }
        return key
    }

    static func keys(_ session: NoiseSession, peerKey: Data, peerName: String) -> LinkKeys {
        let datagram = session.datagramKeys()
        return LinkKeys(
            peerKey: peerKey, peerName: peerName, send: datagram.send, receive: datagram.receive, handshakeHash: session.handshakeHash
        )
    }
}

public final class PairingGate: @unchecked Sendable {
    public static let window: TimeInterval = 120
    public static let attempts = 3
    public static let ceremonyLimit: TimeInterval = 90

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var openUntil: Date?
    private var used = 0
    private var active: (token: UUID, since: Date)?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func open() {
        lock.withLock {
            openUntil = now().addingTimeInterval(Self.window)
            used = 0
            active = nil
        }
    }

    public func close() {
        lock.withLock {
            openUntil = nil
            active = nil
        }
    }

    public var isOpen: Bool { lock.withLock { openUntil.map { now() < $0 } ?? false } }

    public var remainingAttempts: Int { lock.withLock { max(0, Self.attempts - used) } }

    public var deadline: Date? { lock.withLock { openUntil } }

    func begin() throws -> UUID {
        try lock.withLock {
            let moment = now()
            guard let until = openUntil, moment < until else {
                throw LinkError.refused("In HorizonHub on the Mac, choose TV › Pair a TV…, then try again")
            }
            if let current = active, moment.timeIntervalSince(current.since) < Self.ceremonyLimit {
                throw LinkError.refused("Another device is pairing right now")
            }
            guard used < Self.attempts else {
                throw LinkError.refused("No attempts left: choose Pair a TV… on the Mac again")
            }
            used += 1
            let token = UUID()
            active = (token, moment)
            return token
        }
    }

    func end(_ token: UUID, paired: Bool) {
        lock.withLock {
            guard active?.token == token else { return }
            active = nil
            if paired { openUntil = nil }
        }
    }
}

public struct HubLink: Sendable {
    public enum Event: Sendable {
        case send(Data)
        case codeNeeded(clientName: String)
        case paired(clientKey: Data, clientName: String)
        case pairingFailed(String)
        case established(LinkKeys)
        case control(ControlMessage)
    }

    private enum Phase: Sendable {
        case hello
        case ready
        case pairing(HubPairingCeremony, token: UUID, revealed: Bool)
        case established(NoiseSession)
    }

    public let identity: LinkIdentity
    public let hubName: String
    private let gate: PairingGate
    private let isPaired: @Sendable (Data) -> Bool
    private var phase = Phase.hello
    private var client: ClientHello?
    private var hello: HubHello?
    private var pairedHere = false

    public init(identity: LinkIdentity, hubName: String, gate: PairingGate, isPaired: @escaping @Sendable (Data) -> Bool) {
        self.identity = identity
        self.hubName = hubName
        self.gate = gate
        self.isPaired = isPaired
    }

    public var clientName: String? { client?.name }
    public var clientKey: Data? { client?.clientKey }

    public var isEstablished: Bool {
        if case .established = phase { true } else { false }
    }

    public var isAwaitingCode: Bool {
        if case .pairing(_, _, true) = phase { true } else { false }
    }

    public mutating func receive(_ body: Data) throws -> [Event] {
        if case .established(var session) = phase {
            let plain = try session.receiver.decrypt(body)
            phase = .established(session)
            return [.control(try ControlMessage(plain))]
        }
        let message = try ClearMessage(body)
        switch (phase, message) {
        case (.hello, .clientHello(let hello)):
            guard hello.version == LinkProtocol.version else { throw LinkError.wrongVersion(hello.version) }
            _ = try LinkHandshake.publicKey(hello.clientKey)
            client = hello
            let reply = HubHello(name: hubName, hubId: identity.hubId, paired: isPaired(hello.clientKey))
            self.hello = reply
            phase = .ready
            return [.send(ClearMessage.hubHello(reply).encoded())]
        case (.ready, .pairCommit(let commitment)):
            let token = try gate.begin()
            var ceremony = HubPairingCeremony(hubKey: identity.privateKey.publicKey)
            let reply: (hubKey: Data, hubNonce: Data)
            do { reply = try ceremony.receiveCommitment(commitment) } catch {
                gate.end(token, paired: false)
                throw error
            }
            phase = .pairing(ceremony, token: token, revealed: false)
            return [.send(ClearMessage.pairHubKey(key: reply.hubKey, nonce: reply.hubNonce).encoded())]
        case (.pairing(var ceremony, let token, false), .pairReveal(let key, let nonce)):
            do {
                guard key == client?.clientKey else { throw LinkError.violation("the revealed key is not the one in the hello") }
                _ = try ceremony.receiveReveal(clientKey: key, clientNonce: nonce)
            } catch {
                gate.end(token, paired: false)
                throw error
            }
            phase = .pairing(ceremony, token: token, revealed: true)
            return [.codeNeeded(clientName: client?.name ?? "")]
        case (.ready, .handshake(let first)):
            guard let client, let hello, pairedHere || isPaired(client.clientKey) else {
                throw LinkError.refused("This device is not paired: in HorizonHub on the Mac, choose TV › Pair a TV…")
            }
            var handshake = NoiseHandshake(
                role: .responder, localStatic: identity.privateKey, remoteStatic: try LinkHandshake.publicKey(client.clientKey),
                prologue: LinkHandshake.prologue(client: client, hub: hello)
            )
            _ = try handshake.readMessage(first)
            let second = try handshake.writeMessage()
            let session = try handshake.split()
            phase = .established(session)
            return [
                .send(ClearMessage.handshake(second).encoded()),
                .established(LinkHandshake.keys(session, peerKey: client.clientKey, peerName: client.name)),
            ]
        default:
            throw LinkError.violation("unexpected \(message) at this point")
        }
    }

    public mutating func submitCode(_ typed: String) -> [Event] {
        guard case .pairing(let ceremony, let token, true) = phase, let client else { return [] }
        let accepted = ceremony.matches(typed)
        gate.end(token, paired: accepted)
        phase = .ready
        guard accepted else {
            return [.pairingFailed("Wrong code"), .send(ClearMessage.pairResult(accepted: false, reason: "Wrong code").encoded())]
        }
        pairedHere = true
        return [
            .paired(clientKey: client.clientKey, clientName: client.name),
            .send(ClearMessage.pairResult(accepted: true, reason: "").encoded()),
        ]
    }

    public mutating func cancelPairing(_ reason: String = "Pairing canceled on the Mac") -> [Event] {
        guard case .pairing(_, let token, _) = phase else { return [] }
        gate.end(token, paired: false)
        phase = .ready
        return [.pairingFailed(reason), .send(ClearMessage.pairResult(accepted: false, reason: reason).encoded())]
    }

    public mutating func close() {
        if case .pairing(_, let token, _) = phase { gate.end(token, paired: false) }
        phase = .ready
    }

    public mutating func seal(_ message: ControlMessage) throws -> Data {
        guard case .established(var session) = phase else { throw LinkError.violation("the link is not established yet") }
        let data = try session.sender.encrypt(message.encoded())
        phase = .established(session)
        return data
    }
}

public struct ClientLink: Sendable {
    public enum Event: Sendable {
        case send(Data)
        case needsPairing(hubName: String)
        case showCode(String)
        case paired(hubId: Data, hubKey: Data, hubName: String)
        case pairingFailed(String)
        case established(LinkKeys)
        case control(ControlMessage)
    }

    private enum Phase: Sendable {
        case start
        case hello
        case choosing
        case committed(ClientPairingCeremony)
        case revealed(ClientPairingCeremony)
        case handshaking(NoiseHandshake, hubKey: Data)
        case established(NoiseSession)
    }

    public let identity: LinkIdentity
    public let name: String
    private let knownHub: @Sendable (Data) -> Data?
    private let sentHello: ClientHello
    private var phase = Phase.start
    private var hub: HubHello?

    public init(identity: LinkIdentity, name: String, knownHub: @escaping @Sendable (Data) -> Data?) {
        self.identity = identity
        self.name = name
        self.knownHub = knownHub
        sentHello = ClientHello(name: name, clientKey: identity.publicKey)
    }

    public var hubHello: HubHello? { hub }

    public var isEstablished: Bool {
        if case .established = phase { true } else { false }
    }

    public mutating func start() -> [Event] {
        phase = .hello
        return [.send(ClearMessage.clientHello(sentHello).encoded())]
    }

    public mutating func pair() -> [Event] {
        guard case .choosing = phase else { return [] }
        let ceremony = ClientPairingCeremony(clientKey: identity.privateKey.publicKey)
        phase = .committed(ceremony)
        return [.send(ClearMessage.pairCommit(ceremony.commitment).encoded())]
    }

    public mutating func receive(_ body: Data) throws -> [Event] {
        if case .established(var session) = phase {
            let plain = try session.receiver.decrypt(body)
            phase = .established(session)
            return [.control(try ControlMessage(plain))]
        }
        let message = try ClearMessage(body)
        if case .refused(let reason) = message { throw LinkError.refused(reason) }
        switch (phase, message) {
        case (.hello, .hubHello(let hello)):
            guard hello.version == LinkProtocol.version else { throw LinkError.wrongVersion(hello.version) }
            guard hello.hubId.count == LinkProtocol.hubIdSize else { throw LinkError.violation("a \(hello.hubId.count)-byte hub id") }
            hub = hello
            if hello.paired, let key = knownHub(hello.hubId) { return try beginHandshake(hubKey: key) }
            phase = .choosing
            return [.needsPairing(hubName: hello.name)]
        case (.committed(var ceremony), .pairHubKey(let key, let nonce)):
            guard LinkIdentity.hubId(of: key) == hub?.hubId else { throw LinkError.violation("the hub's key does not match its id") }
            _ = try LinkHandshake.publicKey(key)
            let code = try ceremony.receiveHub(key: key, nonce: nonce)
            phase = .revealed(ceremony)
            return [.showCode(code), .send(ClearMessage.pairReveal(key: ceremony.clientKey, nonce: ceremony.clientNonce).encoded())]
        case (.revealed(let ceremony), .pairResult(let accepted, let reason)):
            guard accepted, let key = ceremony.hubKey, let hub else {
                phase = .choosing
                return [.pairingFailed(reason.isEmpty ? "The Mac refused the pairing" : reason)]
            }
            return [.paired(hubId: hub.hubId, hubKey: key, hubName: hub.name)] + (try beginHandshake(hubKey: key))
        case (.handshaking(var handshake, let hubKey), .handshake(let second)):
            _ = try handshake.readMessage(second)
            let session = try handshake.split()
            phase = .established(session)
            return [.established(LinkHandshake.keys(session, peerKey: hubKey, peerName: hub?.name ?? ""))]
        default:
            throw LinkError.violation("unexpected \(message) at this point")
        }
    }

    public mutating func seal(_ message: ControlMessage) throws -> Data {
        guard case .established(var session) = phase else { throw LinkError.violation("the link is not established yet") }
        let data = try session.sender.encrypt(message.encoded())
        phase = .established(session)
        return data
    }

    private mutating func beginHandshake(hubKey: Data) throws -> [Event] {
        guard let hub else { throw LinkError.violation("no hub hello yet") }
        var handshake = NoiseHandshake(
            role: .initiator, localStatic: identity.privateKey, remoteStatic: try LinkHandshake.publicKey(hubKey),
            prologue: LinkHandshake.prologue(client: sentHello, hub: hub)
        )
        let first = try handshake.writeMessage()
        phase = .handshaking(handshake, hubKey: hubKey)
        return [.send(ClearMessage.handshake(first).encoded())]
    }
}
