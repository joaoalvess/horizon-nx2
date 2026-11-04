import CryptoKit
import Foundation
import Testing
@testable import HorizonLink

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { moment } }

    func advance(_ seconds: TimeInterval) { lock.withLock { moment += seconds } }
}

final class PairedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Data: Data] = [:]

    func add(_ key: Data, id: Data = Data()) { lock.withLock { keys[key] = id } }

    func contains(_ key: Data) -> Bool { lock.withLock { keys[key] != nil } }

    func hub(_ id: Data) -> Data? { lock.withLock { keys.first { $0.value == id }?.key } }
}

struct LinkPair {
    let clock = Clock()
    let gate: PairingGate
    let clients = PairedKeys()
    let hubs = PairedKeys()
    var hub: HubLink
    var client: ClientLink
    var hubEvents: [HubLink.Event] = []
    var clientEvents: [ClientLink.Event] = []

    init(hubIdentity: LinkIdentity = LinkIdentity(), clientIdentity: LinkIdentity = LinkIdentity()) {
        let clock = self.clock
        gate = PairingGate { clock.now }
        let clients = self.clients
        let hubs = self.hubs
        hub = HubLink(identity: hubIdentity, hubName: "MacBook Air", gate: gate) { clients.contains($0) }
        client = ClientLink(identity: clientIdentity, name: "Apple TV") { hubs.hub($0) }
    }

    mutating func deliver(fromClient events: [ClientLink.Event]) throws {
        clientEvents += events
        for case .send(let body) in events { try deliver(fromHub: hub.receive(body)) }
    }

    mutating func deliver(fromHub events: [HubLink.Event]) throws {
        hubEvents += events
        for case .send(let body) in events { try deliver(fromClient: client.receive(body)) }
    }

    var shownCode: String? {
        clientEvents.compactMap { if case .showCode(let code) = $0 { code } else { nil } }.last
    }

    var hubKeys: LinkKeys? { hubEvents.compactMap { if case .established(let keys) = $0 { keys } else { nil } }.last }
    var clientKeys: LinkKeys? { clientEvents.compactMap { if case .established(let keys) = $0 { keys } else { nil } }.last }

    mutating func rememberPairing() {
        for case .paired(let key, _) in hubEvents { clients.add(key) }
        for case .paired(let id, let key, _) in clientEvents { hubs.add(key, id: id) }
    }
}

struct LinkSessionTests {
    @Test func pairingWithTheRightCodeEstablishesTheLink() throws {
        var pair = LinkPair()
        pair.gate.open()
        try pair.deliver(fromClient: pair.client.start())
        #expect(pair.clientEvents.contains { if case .needsPairing("MacBook Air") = $0 { true } else { false } })
        try pair.deliver(fromClient: pair.client.pair())
        #expect(pair.hub.isAwaitingCode)
        let code = try #require(pair.shownCode)
        try pair.deliver(fromHub: pair.hub.submitCode(code))
        pair.rememberPairing()
        #expect(pair.hub.isEstablished)
        #expect(pair.client.isEstablished)
        #expect(!pair.gate.isOpen)

        let hubKeys = try #require(pair.hubKeys)
        let clientKeys = try #require(pair.clientKeys)
        #expect(hubKeys.handshakeHash == clientKeys.handshakeHash)
        #expect(hubKeys.peerKey == pair.client.identity.publicKey)
        #expect(clientKeys.peerKey == pair.hub.identity.publicKey)
        var sealer = DatagramSealer(key: clientKeys.send)
        var opener = DatagramOpener(key: hubKeys.receive)
        let datagram = try sealer.seal(Data("hi".utf8), channel: MediaChannel.hello.rawValue)
        #expect(try opener.open(datagram).plaintext == Data("hi".utf8))

        let welcome = ControlMessage.welcome(Welcome(udpPort: 50000, sessionId: 7, hubName: "MacBook Air"))
        #expect(try pair.client.receive(pair.hub.seal(welcome)).count == 1)
        let events = try pair.hub.receive(pair.client.seal(.open(profile: "joao", game: "dk")))
        guard case .control(.open(profile: "joao", game: "dk")) = events.first else {
            Issue.record("the hub did not get the open request")
            return
        }
    }

    @Test func aPairedClientReconnectsWithoutACode() throws {
        let hubIdentity = LinkIdentity()
        let clientIdentity = LinkIdentity()
        var first = LinkPair(hubIdentity: hubIdentity, clientIdentity: clientIdentity)
        first.gate.open()
        try first.deliver(fromClient: first.client.start())
        try first.deliver(fromClient: first.client.pair())
        try first.deliver(fromHub: first.hub.submitCode(try #require(first.shownCode)))
        first.rememberPairing()

        var second = LinkPair(hubIdentity: hubIdentity, clientIdentity: clientIdentity)
        for case .paired(let key, _) in first.hubEvents { second.clients.add(key) }
        for case .paired(let id, let key, _) in first.clientEvents { second.hubs.add(key, id: id) }
        try second.deliver(fromClient: second.client.start())
        #expect(second.hub.isEstablished)
        #expect(second.client.isEstablished)
        #expect(!second.clientEvents.contains { if case .needsPairing = $0 { true } else { false } })
    }

    @Test func aWrongCodeIsRefusedAndCountsAsAnAttempt() throws {
        var pair = LinkPair()
        pair.gate.open()
        try pair.deliver(fromClient: pair.client.start())
        try pair.deliver(fromClient: pair.client.pair())
        let code = try #require(pair.shownCode)
        let wrong = code == "000000" ? "111111" : "000000"
        try pair.deliver(fromHub: pair.hub.submitCode(wrong))
        #expect(!pair.hub.isEstablished)
        #expect(pair.clientEvents.contains { if case .pairingFailed = $0 { true } else { false } })
        #expect(pair.gate.remainingAttempts == 2)
        #expect(pair.gate.isOpen)
        try pair.deliver(fromClient: pair.client.pair())
        try pair.deliver(fromHub: pair.hub.submitCode(try #require(pair.shownCode)))
        #expect(pair.hub.isEstablished)
    }

    @Test func pairingNeedsTheWindowOpen() throws {
        var pair = LinkPair()
        try pair.deliver(fromClient: pair.client.start())
        #expect(throws: LinkError.refused("In HorizonHub on the Mac, choose TV › Pair a TV…, then try again")) {
            try pair.deliver(fromClient: pair.client.pair())
        }
        pair.gate.open()
        pair.clock.advance(PairingGate.window + 1)
        #expect(!pair.gate.isOpen)
    }

    @Test func theGateAllowsThreeCommitmentsAndOneCeremonyAtATime() throws {
        let clock = Clock()
        let gate = PairingGate { clock.now }
        gate.open()
        let first = try gate.begin()
        #expect(throws: LinkError.refused("Another device is pairing right now")) { try gate.begin() }
        gate.end(first, paired: false)
        gate.end(try gate.begin(), paired: false)
        let third = try gate.begin()
        clock.advance(PairingGate.ceremonyLimit + 1)
        #expect(throws: LinkError.refused("No attempts left: choose Pair a TV… on the Mac again")) { try gate.begin() }
        gate.end(third, paired: false)
        gate.open()
        #expect(gate.remainingAttempts == 3)
    }

    @Test func anUnpairedClientCannotHandshake() throws {
        var pair = LinkPair()
        let hubIdentity = pair.hub.identity
        pair.hubs.add(hubIdentity.publicKey, id: hubIdentity.hubId)
        _ = try pair.hub.receive(ClearMessage.clientHello(ClientHello(name: "x", clientKey: pair.client.identity.publicKey)).encoded())
        var initiator = NoiseHandshake(
            role: .initiator, localStatic: pair.client.identity.privateKey, remoteStatic: hubIdentity.privateKey.publicKey, prologue: Data()
        )
        let first = try initiator.writeMessage()
        #expect(throws: LinkError.refused("This device is not paired: in HorizonHub on the Mac, choose TV › Pair a TV…")) {
            try pair.hub.receive(ClearMessage.handshake(first).encoded())
        }
    }

    @Test func aHubWithAnotherKeyFailsTheHandshake() throws {
        var pair = LinkPair()
        pair.clients.add(pair.client.identity.publicKey)
        pair.hubs.add(LinkIdentity().publicKey, id: pair.hub.identity.hubId)
        #expect(throws: (any Error).self) { try pair.deliver(fromClient: pair.client.start()) }
        #expect(!pair.client.isEstablished)
    }

    @Test func aRevealWithAnotherKeyIsRejected() throws {
        var pair = LinkPair()
        pair.gate.open()
        _ = try pair.hub.receive(ClearMessage.clientHello(ClientHello(name: "x", clientKey: pair.client.identity.publicKey)).encoded())
        let other = ClientPairingCeremony(clientKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        _ = try pair.hub.receive(ClearMessage.pairCommit(other.commitment).encoded())
        #expect(throws: LinkError.self) {
            try pair.hub.receive(ClearMessage.pairReveal(key: other.clientKey, nonce: other.clientNonce).encoded())
        }
        #expect(pair.gate.remainingAttempts == 2)
        _ = try pair.gate.begin()
    }

    @Test func messagesOutOfOrderAreViolations() throws {
        var pair = LinkPair()
        #expect(throws: LinkError.self) { try pair.hub.receive(ClearMessage.pairCommit(Data(count: 32)).encoded()) }
        #expect(throws: LinkError.self) { try pair.client.receive(ClearMessage.pairResult(accepted: true, reason: "").encoded()) }
        #expect(throws: LinkError.self) { try pair.hub.seal(.keepalive) }
    }
}
