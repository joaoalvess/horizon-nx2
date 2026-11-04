import CryptoKit
import Foundation
import Testing
@testable import HorizonLink

private enum CacophonyKK {
    static let protocolName = "Noise_KK_25519_ChaChaPoly_SHA256"
    static let prologue = hex("4a6f686e2047616c74")
    static let initiatorStatic = hex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1")
    static let initiatorEphemeral = hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")
    static let initiatorRemoteStatic = hex("31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62")
    static let responderStatic = hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")
    static let responderEphemeral = hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")
    static let responderRemoteStatic = hex("6bc3822a2aa7f4e6981d6538692b3cdf3e6df9eea6ed269eb41d93c22757b75a")
    static let handshakeHash = hex("24c6b51ecb76277140ca018b5985bc9f03de321dae2d34dcae433dafef0131d9")
    static let messages: [(payload: Data, ciphertext: Data)] = [
        (
            hex("4c756477696720766f6e204d69736573"),
            hex("ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79440177015efc1fe7a37c629af7120a96274e6ab7afcc9261901d0e09ae32a5bb96")
        ),
        (
            hex("4d757272617920526f746862617264"),
            hex("95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843b274d3429adc47ca093ba63ef90f8da89fda108db471dccfa4894aa7b00003")
        ),
        (hex("462e20412e20486179656b"), hex("966b05bc69ec01b8454d3160a214e6f24a3d884eb31ec2408af63f")),
        (hex("4361726c204d656e676572"), hex("0ad887fba4f611bbb4afe44ba3556b8164332ca7d5934634d63d80")),
        (hex("4a65616e2d426170746973746520536179"), hex("012b28ae646ae7830e2c5472cb023eab071c1db3d8413ec69b513b83832f974c2d")),
        (
            hex("457567656e2042f6686d20766f6e2042617765726b"),
            hex("bb3e6a48160d9c5971d37f975727294e0d868342db31832e54d07191ab0ca3c3703b5ed3d9")
        ),
    ]

    static func hex(_ text: String) -> Data {
        let digits = Array(text.utf8)
        return Data(stride(from: 0, to: digits.count - 1, by: 2).compactMap { index in
            UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)
        })
    }

    static func key(_ raw: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }
}

private struct Pair {
    let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
    let responderStatic = Curve25519.KeyAgreement.PrivateKey()
    let prologue = Data("horizon link v1".utf8)

    func initiator(remote: Curve25519.KeyAgreement.PublicKey? = nil) -> NoiseHandshake {
        NoiseHandshake(
            role: .initiator, localStatic: initiatorStatic, remoteStatic: remote ?? responderStatic.publicKey, prologue: prologue
        )
    }

    func responder(remote: Curve25519.KeyAgreement.PublicKey? = nil) -> NoiseHandshake {
        NoiseHandshake(
            role: .responder, localStatic: responderStatic, remoteStatic: remote ?? initiatorStatic.publicKey, prologue: prologue
        )
    }
}

private func keyBytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

struct NoiseTests {
    @Test func theProtocolNameFillsTheFirstHash() {
        #expect(Noise.initialHash(protocolName: NoiseHandshake.protocolName) == Data(NoiseHandshake.protocolName.utf8))
        #expect(Noise.initialHash(protocolName: "Noise_NN") == Data("Noise_NN".utf8) + Data(count: 24))
        let long = "Noise_XXfallback+psk0_25519_ChaChaPoly_SHA256"
        #expect(Noise.initialHash(protocolName: long) == Data(SHA256.hash(data: Data(long.utf8))))
    }

    @Test func theCacophonyVectorMatchesByteForByte() throws {
        #expect(NoiseHandshake.protocolName == CacophonyKK.protocolName)
        #expect(CacophonyKK.handshakeHash.count == 32)
        let initiatorStatic = try CacophonyKK.key(CacophonyKK.initiatorStatic)
        let responderStatic = try CacophonyKK.key(CacophonyKK.responderStatic)
        #expect(responderStatic.publicKey.rawRepresentation == CacophonyKK.initiatorRemoteStatic)
        #expect(initiatorStatic.publicKey.rawRepresentation == CacophonyKK.responderRemoteStatic)
        var initiator = NoiseHandshake(
            role: .initiator, localStatic: initiatorStatic, remoteStatic: responderStatic.publicKey, prologue: CacophonyKK.prologue,
            localEphemeral: try CacophonyKK.key(CacophonyKK.initiatorEphemeral)
        )
        var responder = NoiseHandshake(
            role: .responder, localStatic: responderStatic, remoteStatic: initiatorStatic.publicKey, prologue: CacophonyKK.prologue,
            localEphemeral: try CacophonyKK.key(CacophonyKK.responderEphemeral)
        )
        let vectors = CacophonyKK.messages

        let first = try initiator.writeMessage(payload: vectors[0].payload)
        #expect(first == vectors[0].ciphertext)
        #expect(try responder.readMessage(first) == vectors[0].payload)
        let second = try responder.writeMessage(payload: vectors[1].payload)
        #expect(second == vectors[1].ciphertext)
        #expect(try initiator.readMessage(second) == vectors[1].payload)
        #expect(initiator.isFinished && responder.isFinished)

        var initiatorSession = try initiator.split()
        var responderSession = try responder.split()
        #expect(initiatorSession.handshakeHash == CacophonyKK.handshakeHash)
        #expect(responderSession.handshakeHash == CacophonyKK.handshakeHash)

        for (index, vector) in vectors.enumerated().dropFirst(2) {
            if index.isMultiple(of: 2) {
                #expect(try initiatorSession.sender.encrypt(vector.payload) == vector.ciphertext)
                #expect(try responderSession.receiver.decrypt(vector.ciphertext) == vector.payload)
            } else {
                #expect(try responderSession.sender.encrypt(vector.payload) == vector.ciphertext)
                #expect(try initiatorSession.receiver.decrypt(vector.ciphertext) == vector.payload)
            }
        }
    }

    @Test func randomKeysCompleteAHandshakeAndCarryTrafficBothWays() throws {
        let pair = Pair()
        var initiator = pair.initiator()
        var responder = pair.responder()
        #expect(initiator.isFinished == false)
        #expect(try responder.readMessage(try initiator.writeMessage(payload: Data("hello hub".utf8))) == Data("hello hub".utf8))
        #expect(responder.isFinished == false)
        #expect(try initiator.readMessage(try responder.writeMessage()) == Data())
        var client = try initiator.split()
        var hub = try responder.split()
        #expect(client.handshakeHash == hub.handshakeHash)
        #expect(client.handshakeHash.count == 32)

        for round in 0..<20 {
            let ad = Data([UInt8(round)])
            let up = Data(repeating: UInt8(round), count: round * 37)
            let sealed = try client.sender.encrypt(up, ad: ad)
            #expect(sealed.count == up.count + NoiseCipherState.tagSize)
            #expect(try hub.receiver.decrypt(sealed, ad: ad) == up)
            let down = Data("frame \(round)".utf8)
            #expect(try client.receiver.decrypt(try hub.sender.encrypt(down)) == down)
        }

        let crossed = try client.sender.encrypt(Data("mine".utf8))
        #expect(throws: NoiseError.authenticationFailed) { try client.receiver.decrypt(crossed) }
        #expect(throws: NoiseError.authenticationFailed) { try hub.receiver.decrypt(crossed, ad: Data([9])) }
    }

    @Test func datagramKeysPairUpAndDifferFromTheControlKeys() throws {
        let pair = Pair()
        var initiator = pair.initiator()
        var responder = pair.responder()
        _ = try responder.readMessage(try initiator.writeMessage())
        _ = try initiator.readMessage(try responder.writeMessage())
        let client = try initiator.split()
        let hub = try responder.split()
        let clientKeys = client.datagramKeys()
        let hubKeys = hub.datagramKeys()
        #expect(keyBytes(clientKeys.send) == keyBytes(hubKeys.receive))
        #expect(keyBytes(clientKeys.receive) == keyBytes(hubKeys.send))
        #expect(keyBytes(clientKeys.send) != keyBytes(clientKeys.receive))
        #expect(keyBytes(clientKeys.send).count == 32)
        let control = [client.sendKey, client.receiveKey].map(keyBytes)
        #expect(control.contains(keyBytes(clientKeys.send)) == false)
        #expect(control.contains(keyBytes(clientKeys.receive)) == false)
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: client.sendKey, salt: client.handshakeHash, info: Data("horizon datagram".utf8), outputByteCount: 32
        )
        #expect(keyBytes(clientKeys.send) == keyBytes(expected))
    }

    @Test func theWrongRemoteStaticFailsTheHandshake() throws {
        let pair = Pair()
        let stranger = Curve25519.KeyAgreement.PrivateKey().publicKey

        var initiator = pair.initiator(remote: stranger)
        var responder = pair.responder()
        let first = try initiator.writeMessage()
        #expect(throws: NoiseError.authenticationFailed) { try responder.readMessage(first) }
        #expect(throws: NoiseError.handshakeFailed) { try responder.writeMessage() }
        #expect(throws: NoiseError.handshakeFailed) { try responder.split() }

        var trusting = pair.initiator()
        var suspicious = pair.responder(remote: stranger)
        #expect(throws: NoiseError.authenticationFailed) { try suspicious.readMessage(try trusting.writeMessage()) }
        #expect(suspicious.isFinished == false)
    }

    @Test func aTamperedMessageFails() throws {
        let pair = Pair()
        var initiator = pair.initiator()
        let first = try initiator.writeMessage(payload: Data("pad".utf8))
        #expect(first.count == 32 + 3 + 16)
        for position in [0, 31, 32, 34, first.count - 1] {
            var tampered = first
            tampered[position] ^= 0x80
            var responder = pair.responder()
            #expect(throws: NoiseError.self) { try responder.readMessage(tampered) }
            #expect(throws: NoiseError.handshakeFailed) { try responder.readMessage(first) }
        }
        var short = pair.responder()
        #expect(throws: NoiseError.truncated) { try short.readMessage(first.prefix(40)) }

        var responder = pair.responder()
        _ = try responder.readMessage(first)
        let second = try responder.writeMessage()
        var tampered = second
        tampered[40] ^= 1
        var copy = initiator
        #expect(throws: NoiseError.authenticationFailed) { try copy.readMessage(tampered) }
        #expect(throws: NoiseError.handshakeFailed) { try copy.readMessage(second) }
        _ = try initiator.readMessage(second)
        var client = try initiator.split()
        var hub = try responder.split()

        let sealed = try client.sender.encrypt(Data("transport".utf8))
        var broken = sealed
        broken[broken.count - 1] ^= 1
        #expect(throws: NoiseError.authenticationFailed) { try hub.receiver.decrypt(broken) }
        #expect(throws: NoiseError.truncated) { try hub.receiver.decrypt(sealed.prefix(15)) }
        #expect(try hub.receiver.decrypt(sealed) == Data("transport".utf8))
    }

    @Test func callsOutOfOrderThrow() throws {
        let pair = Pair()
        var initiator = pair.initiator()
        var responder = pair.responder()
        #expect(throws: NoiseError.outOfOrder) { try initiator.readMessage(Data(count: 64)) }
        #expect(throws: NoiseError.outOfOrder) { try responder.writeMessage() }
        #expect(throws: NoiseError.outOfOrder) { try initiator.split() }
        let first = try initiator.writeMessage()
        #expect(throws: NoiseError.outOfOrder) { try initiator.writeMessage() }
        _ = try responder.readMessage(first)
        #expect(throws: NoiseError.outOfOrder) { try responder.readMessage(first) }
        #expect(throws: NoiseError.outOfOrder) { try responder.split() }
        _ = try initiator.readMessage(try responder.writeMessage())
        #expect(throws: NoiseError.outOfOrder) { try initiator.writeMessage() }
        #expect(throws: NoiseError.outOfOrder) { try responder.readMessage(first) }
        _ = try initiator.split()
        #expect(throws: NoiseError.outOfOrder) { try initiator.split() }
        #expect(initiator.isFinished)
    }

    @Test func oversizedMessagesAreRefusedWithoutBreakingTheHandshake() throws {
        let pair = Pair()
        var initiator = pair.initiator()
        let limit = NoiseCipherState.maxMessageSize - NoiseHandshake.messageOverhead
        #expect(throws: NoiseError.messageTooLarge) { try initiator.writeMessage(payload: Data(count: limit + 1)) }
        let first = try initiator.writeMessage(payload: Data(count: limit))
        #expect(first.count == NoiseCipherState.maxMessageSize)
        var responder = pair.responder()
        #expect(throws: NoiseError.messageTooLarge) { try responder.readMessage(first + Data([0])) }
        var fresh = pair.responder()
        #expect(try fresh.readMessage(first).count == limit)
    }

    @Test func aReplayedFirstMessageReachesAFreshResponderButCannotCompleteASession() throws {
        let pair = Pair()
        var initiator = pair.initiator()
        var genuine = pair.responder()
        let first = try initiator.writeMessage(payload: Data("attach".utf8))
        _ = try genuine.readMessage(first)
        _ = try initiator.readMessage(try genuine.writeMessage())
        var client = try initiator.split()
        var hub = try genuine.split()

        var replayed = pair.responder()
        #expect(try replayed.readMessage(first) == Data("attach".utf8))
        let answer = try replayed.writeMessage()
        var victim = initiator
        #expect(throws: NoiseError.outOfOrder) { try victim.readMessage(answer) }
        var impostorHub = try replayed.split()
        #expect(impostorHub.handshakeHash != hub.handshakeHash)

        let sealed = try client.sender.encrypt(Data("pad".utf8))
        #expect(throws: NoiseError.authenticationFailed) { try impostorHub.receiver.decrypt(sealed) }
        #expect(try hub.receiver.decrypt(sealed) == Data("pad".utf8))
        let fromImpostor = try impostorHub.sender.encrypt(Data("rumble".utf8))
        #expect(throws: NoiseError.authenticationFailed) { try client.receiver.decrypt(fromImpostor) }
    }

    @Test func nonceExhaustionThrows() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = NoiseCipherState(key: key, nonce: .max - 1)
        var receiver = NoiseCipherState(key: key, nonce: .max - 1)
        let last = try sender.encrypt(Data("last".utf8))
        #expect(try receiver.decrypt(last) == Data("last".utf8))
        #expect(throws: NoiseError.nonceExhausted) { try sender.encrypt(Data()) }
        #expect(throws: NoiseError.nonceExhausted) { try receiver.decrypt(last) }
    }
}
