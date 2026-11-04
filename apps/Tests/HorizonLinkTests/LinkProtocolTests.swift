import CryptoKit
import Foundation
import Testing
@testable import HorizonLink

struct LinkProtocolTests {
    @Test func clearMessagesSurviveARoundTrip() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let messages: [ClearMessage] = [
            .clientHello(ClientHello(name: "Living room Apple TV", clientKey: key)),
            .hubHello(HubHello(name: "MacBook Air", hubId: Data(repeating: 7, count: 8), paired: true)),
            .pairCommit(Data(repeating: 1, count: 32)),
            .pairHubKey(key: key, nonce: Data(repeating: 2, count: 32)),
            .pairReveal(key: key, nonce: Data(repeating: 3, count: 32)),
            .pairResult(accepted: false, reason: "wrong code"),
            .handshake(Data([1, 2, 3])),
            .refused("choose Pair a TV… in HorizonHub"),
        ]
        for message in messages { #expect(try ClearMessage(message.encoded()) == message) }
    }

    @Test func controlMessagesSurviveARoundTrip() throws {
        let messages: [ControlMessage] = [
            .welcome(Welcome(udpPort: 52000, sessionId: 0xDEAD_BEEF, hubName: "MacBook Air")),
            .catalog(
                profiles: [LinkProfile(id: "zoe", name: "Zoë", nick: "Zoe")],
                games: [
                    LinkGame(id: "mkw", title: "Mario Kart World", status: .running),
                    LinkGame(id: "dk", title: "DK", status: .blocked, detail: "GPU error"),
                ]
            ),
            .state(LinkState(game: "mkw", title: "Mario Kart World", profile: "zoe", streaming: true, paused: false)),
            .state(LinkState()),
            .attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 25000)),
            .detach(pause: true),
            .open(profile: "zoe", game: "dk"),
            .close,
            .pads(DMStream.Pads(mask: 3, styles: [1, 1, 0, 0, 0, 0, 0, 0])),
            .bitrate(20000),
            .notice("SSD disconnected"),
            .stats("rtt_ms=5.1"),
            .keepalive,
        ]
        for message in messages { #expect(try ControlMessage(message.encoded()) == message) }
    }

    @Test func mediaPacketsSurviveARoundTrip() throws {
        let envelope = FrameEnvelope(
            presentNs: 1, frameNumber: 2, ltrToken: -1, parameterSets: [Data([0x67]), Data([0x68, 1])],
            accessUnit: Data(repeating: 9, count: 100)
        )
        #expect(try FrameEnvelope(envelope.encoded()) == envelope)
        let audio = AudioPacket(hostTimeNs: 5, sequence: 6, samples: Data(repeating: 0, count: 960))
        #expect(try AudioPacket(audio.encoded()) == audio)
        let feedback = FeedbackPacket(
            lastCompleteFrame: 10, lastDecodedFrame: 9, refreshRequest: 2, receivedShards: 100, recoveredShards: 3, lostFrames: 1,
            decodeP95Us: 2100, ltrAcks: [4, 5]
        )
        #expect(try FeedbackPacket(feedback.encoded()) == feedback)
        let nack = NackPacket(frame: 77, needs: [.init(block: 0, count: 2), .init(block: 3, count: 1)])
        #expect(try NackPacket(nack.encoded()) == nack)
        let pong = PongPacket(sequence: 1, clientSendNs: 100, hubReceiveNs: 5_000, hubSendNs: 5_010)
        #expect(try PongPacket(pong.encoded()) == pong)
        #expect(try PingPacket(PingPacket(sequence: 3, clientSendNs: 4).encoded()) == PingPacket(sequence: 3, clientSendNs: 4))
        #expect(try DecodedPacket(DecodedPacket(frame: 8, decodedNs: 9).encoded()) == DecodedPacket(frame: 8, decodedNs: 9))
        let pad = PadPacket(
            sequence: 4,
            pad: DMStream.Pad(player: 0, buttons: DMStream.Button.a, leftX: 100, motion: .init(acceleration: SIMD3(0, 0, 1), rotation: .zero))
        )
        #expect(try PadPacket(pad.encoded()) == pad)
        #expect(try HelloPacket(HelloPacket(sessionId: 42).encoded()) == HelloPacket(sessionId: 42))
    }

    @Test func theFramerSplitsAndLimitsMessages() throws {
        var framer = LinkFramer(limit: 10)
        var bytes = LinkFramer.frame(Data([1, 2, 3]))
        bytes.append(LinkFramer.frame(Data([4])))
        framer.append(bytes.prefix(5))
        #expect(try framer.next() == nil)
        framer.append(bytes.dropFirst(5))
        #expect(try framer.next() == Data([1, 2, 3]))
        #expect(try framer.next() == Data([4]))
        #expect(try framer.next() == nil)
        framer.append(LinkFramer.frame(Data(repeating: 0, count: 11)))
        #expect(throws: WireError.self) { try framer.next() }
    }

    @Test func randomBytesNeverCrashTheParsers() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let data = Data((0..<Int.random(in: 0..<64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? ClearMessage(data)
            _ = try? ControlMessage(data)
            _ = try? FeedbackPacket(data)
            _ = try? NackPacket(data)
            _ = try? FrameEnvelope(data)
            _ = try? AudioPacket(data)
            _ = try? PadPacket(data)
            _ = try? PongPacket(data)
        }
    }
}

struct PairingTests {
    @Test func bothSidesDeriveTheSameCode() throws {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        var hub = HubPairingCeremony(hubKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        var client = ClientPairingCeremony(clientKey: clientKey.publicKey)
        let reply = try hub.receiveCommitment(client.commitment)
        let clientCode = try client.receiveHub(key: reply.hubKey, nonce: reply.hubNonce)
        let hubCode = try hub.receiveReveal(clientKey: client.clientKey, clientNonce: client.clientNonce)
        #expect(clientCode == hubCode)
        #expect(clientCode.count == 6)
        #expect(clientCode.allSatisfy { $0.isNumber })
        #expect(hub.matches(" \(clientCode.prefix(3)) \(clientCode.suffix(3)) "))
        #expect(hub.clientKey == clientKey.publicKey.rawRepresentation)
    }

    @Test func aManInTheMiddleCannotChooseTheHubsCode() throws {
        let attackerKey = Curve25519.KeyAgreement.PrivateKey()
        var hub = HubPairingCeremony(hubKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        var attackerAsClient = ClientPairingCeremony(clientKey: attackerKey.publicKey)
        var attackerAsHub = HubPairingCeremony(hubKey: attackerKey.publicKey)
        var client = ClientPairingCeremony(clientKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        let fake = try attackerAsHub.receiveCommitment(client.commitment)
        let tvCode = try client.receiveHub(key: fake.hubKey, nonce: fake.hubNonce)
        let real = try hub.receiveCommitment(attackerAsClient.commitment)
        _ = try attackerAsClient.receiveHub(key: real.hubKey, nonce: real.hubNonce)
        let hubCode = try hub.receiveReveal(clientKey: attackerAsClient.clientKey, clientNonce: attackerAsClient.clientNonce)
        #expect(hub.matches(tvCode) == (hubCode == tvCode))
    }

    @Test func aWrongRevealIsRejected() throws {
        var hub = HubPairingCeremony(hubKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        let client = ClientPairingCeremony(clientKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        _ = try hub.receiveCommitment(client.commitment)
        #expect(throws: PairingError.wrongCommitment) {
            try hub.receiveReveal(clientKey: client.clientKey, clientNonce: Pairing.newNonce())
        }
        #expect(throws: PairingError.outOfOrder) { try hub.receiveCommitment(client.commitment) }
    }

    @Test func codesAreSixDigitsWithLeadingZeros() {
        for _ in 0..<500 {
            let code = Pairing.code(clientKey: Pairing.newNonce(), hubKey: Pairing.newNonce(), clientNonce: Pairing.newNonce(), hubNonce: Pairing.newNonce())
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
        }
        #expect(Pairing.normalized("12 34-56") == "123456")
        #expect(Pairing.sameCode("123456", "123456"))
        #expect(!Pairing.sameCode("123456", "123457"))
        #expect(!Pairing.sameCode("123456", "12345"))
    }
}

struct ClockSyncTests {
    @Test func theOffsetComesFromTheFastestRoundTrip() throws {
        let trueOffset: Int64 = 3_600_000_000_000
        var generator = SystemRandomNumberGenerator()
        var sync = ClockSync(window: 10)
        let floor: UInt64 = 2_000_000
        var clientNow: UInt64 = 1_000_000_000
        for _ in 0..<50 {
            clientNow += 200_000_000
            let outboundQueue = Bool.random(using: &generator) ? UInt64.random(in: 0...20_000_000, using: &generator) : 0
            let inboundQueue = Bool.random(using: &generator) ? UInt64.random(in: 0...30_000_000, using: &generator) : 0
            let hubReceive = UInt64(Int64(clientNow + floor + outboundQueue) + trueOffset)
            let hubSend = hubReceive + 50_000
            let clientReceive = UInt64(Int64(hubSend) - trueOffset) + floor + inboundQueue
            sync.add(ClockSample(clientSendNs: clientNow, hubReceiveNs: hubReceive, hubSendNs: hubSend, clientReceiveNs: clientReceive))
        }
        let offset = try #require(sync.offsetNs)
        let roundTrip = try #require(sync.roundTripNs)
        #expect(abs(offset - trueOffset) < 1_000_000)
        #expect(roundTrip >= Int64(2 * floor))
        let hub = try #require(sync.hubTime(clientNs: 5_000_000_000))
        #expect(sync.clientTime(hubNs: hub) == 5_000_000_000)
    }

    @Test func oldSamplesLeaveTheWindow() {
        var sync = ClockSync(window: 1)
        sync.add(ClockSample(clientSendNs: 0, hubReceiveNs: 1_000, hubSendNs: 1_000, clientReceiveNs: 2_000))
        sync.add(ClockSample(clientSendNs: 5_000_000_000, hubReceiveNs: 5_000_010_000, hubSendNs: 5_000_010_000, clientReceiveNs: 5_000_020_000))
        #expect(sync.roundTripNs == 20_000)
    }
}
