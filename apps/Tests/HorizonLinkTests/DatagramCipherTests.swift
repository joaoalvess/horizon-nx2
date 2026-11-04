import CryptoKit
import Foundation
import Testing
@testable import HorizonLink

struct DatagramCipherTests {
    private let key = SymmetricKey(size: .bits256)

    private func datagrams(_ count: Int, from start: UInt64 = 0, channel: UInt8 = 2) throws -> [Data] {
        var sealer = DatagramSealer(key: key, counter: start)
        return try (0..<count).map { index in try sealer.seal(Data("packet \(start + UInt64(index))".utf8), channel: channel) }
    }

    private func sessions() throws -> (client: NoiseSession, hub: NoiseSession) {
        let clientStatic = Curve25519.KeyAgreement.PrivateKey()
        let hubStatic = Curve25519.KeyAgreement.PrivateKey()
        var initiator = NoiseHandshake(role: .initiator, localStatic: clientStatic, remoteStatic: hubStatic.publicKey, prologue: Data())
        var responder = NoiseHandshake(role: .responder, localStatic: hubStatic, remoteStatic: clientStatic.publicKey, prologue: Data())
        _ = try responder.readMessage(try initiator.writeMessage())
        _ = try initiator.readMessage(try responder.writeMessage())
        return (try initiator.split(), try responder.split())
    }

    @Test func aDatagramSurvivesARoundTrip() throws {
        var sealer = DatagramSealer(key: key)
        var opener = DatagramOpener(key: key)
        for (counter, size) in [0, 1, 1200, 65000].enumerated() {
            let plaintext = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let channel = UInt8(counter * 3)
            let datagram = try sealer.seal(plaintext, channel: channel)
            #expect(datagram.count == plaintext.count + DatagramSealer.overhead)
            var expectedHeader = ByteWriter()
            expectedHeader.u8(1)
            expectedHeader.u8(channel)
            expectedHeader.u16(0)
            expectedHeader.u64(UInt64(counter))
            #expect(datagram.prefix(DatagramSealer.headerSize) == expectedHeader.data)
            let opened = try opener.open(datagram)
            #expect(opened.channel == channel)
            #expect(opened.plaintext == plaintext)
        }
        let slice = try sealer.seal(Data("sliced".utf8), channel: 9)
        let embedded = (Data([0xEE, 0xEE]) + slice).dropFirst(2)
        #expect(try opener.open(embedded).plaintext == Data("sliced".utf8))
    }

    @Test func everyTamperedByteIsRejected() throws {
        let datagram = try datagrams(1)[0]
        var opener = DatagramOpener(key: key)
        for position in 0..<datagram.count {
            var tampered = datagram
            tampered[position] ^= 0x01
            let expected: DatagramError = switch position {
            case 0: .unsupportedVersion(0)
            case 2, 3: .invalidHeader
            default: .authenticationFailed
            }
            #expect(throws: expected) { try opener.open(tampered) }
        }
        #expect(try opener.open(datagram).plaintext == Data("packet 0".utf8))
    }

    @Test func shortDatagramsAreRejected() throws {
        let datagram = try datagrams(1)[0]
        var opener = DatagramOpener(key: key)
        for length in [0, 1, DatagramSealer.headerSize, DatagramSealer.overhead - 1] {
            #expect(throws: DatagramError.truncated) { try opener.open(datagram.prefix(length)) }
        }
        var sealer = DatagramSealer(key: key)
        let empty = try sealer.seal(Data(), channel: 0)
        #expect(empty.count == DatagramSealer.overhead)
        #expect(try opener.open(empty).plaintext == Data())
    }

    @Test func aDuplicateIsRejected() throws {
        let sent = try datagrams(3)
        var opener = DatagramOpener(key: key)
        for datagram in sent { _ = try opener.open(datagram) }
        for datagram in sent {
            #expect(throws: DatagramError.replayed) { try opener.open(datagram) }
        }
    }

    @Test func reorderingInsideTheWindowIsAccepted() throws {
        let sent = try datagrams(556)
        var opener = DatagramOpener(key: key, windowSize: 256)
        var generator = SplitMix(seed: 7)
        var order: [Int] = []
        for start in stride(from: 0, to: 300, by: 150) {
            var block = Array(start..<start + 150)
            for index in block.indices.reversed() where index > 0 {
                block.swapAt(index, Int(generator.next() % UInt64(index + 1)))
            }
            order += block
        }
        order += (300..<556).reversed()
        #expect(order != Array(sent.indices))
        for index in order {
            #expect(try opener.open(sent[index]).plaintext == Data("packet \(index)".utf8))
        }
        for datagram in sent {
            #expect(throws: DatagramError.replayed) { try opener.open(datagram) }
        }
    }

    @Test func aTooOldCounterIsRejected() throws {
        let sent = try datagrams(200)
        var opener = DatagramOpener(key: key, windowSize: 64)
        _ = try opener.open(sent[199])
        #expect(throws: DatagramError.replayed) { try opener.open(sent[135]) }
        #expect(throws: DatagramError.replayed) { try opener.open(sent[0]) }
        #expect(try opener.open(sent[136]).plaintext == Data("packet 136".utf8))
    }

    @Test func aJumpPastTheWindowSlidesIt() throws {
        var opener = DatagramOpener(key: key, windowSize: 1024)
        let early = try datagrams(1024)
        for datagram in early { _ = try opener.open(datagram) }

        let near = try datagrams(1, from: 1700)[0]
        _ = try opener.open(near)
        #expect(throws: DatagramError.replayed) { try opener.open(early[700]) }
        #expect(throws: DatagramError.replayed) { try opener.open(early[676]) }
        #expect(throws: DatagramError.replayed) { try opener.open(early[1023]) }

        let jump: UInt64 = 1700 + 4 * 1024 + 17
        let late = try datagrams(1, from: jump)[0]
        _ = try opener.open(late)
        #expect(throws: DatagramError.replayed) { try opener.open(late) }
        #expect(throws: DatagramError.replayed) { try opener.open(near) }
        let window = try datagrams(1023, from: jump - 1023)
        for datagram in window.shuffled() { _ = try opener.open(datagram) }
        #expect(throws: DatagramError.replayed) { try opener.open(try datagrams(1, from: jump - 1024)[0]) }
        #expect(try opener.open(try datagrams(1, from: jump + 1)[0]).plaintext == Data("packet \(jump + 1)".utf8))
    }

    @Test func aForgedHugeCounterDoesNotMoveTheWindow() throws {
        let sent = try datagrams(10)
        var opener = DatagramOpener(key: key, windowSize: 64)
        for index in sent.indices where index != 3 { _ = try opener.open(sent[index]) }

        var forged = try datagrams(1, from: 1_000_000)[0]
        forged[forged.count - 1] ^= 1
        #expect(throws: DatagramError.authenticationFailed) { try opener.open(forged) }
        var rewritten = sent[9]
        rewritten.replaceSubrange(4..<12, with: withUnsafeBytes(of: (UInt64.max - 1).littleEndian) { Data($0) })
        #expect(throws: DatagramError.authenticationFailed) { try opener.open(rewritten) }
        let stranger = SymmetricKey(size: .bits256)
        var foreign = DatagramSealer(key: stranger, counter: 500_000)
        #expect(throws: DatagramError.authenticationFailed) { try opener.open(try foreign.seal(Data("x".utf8), channel: 0)) }

        #expect(try opener.open(sent[3]).plaintext == Data("packet 3".utf8))
        #expect(throws: DatagramError.replayed) { try opener.open(sent[5]) }
        #expect(try opener.open(try datagrams(1, from: 10)[0]).plaintext == Data("packet 10".utf8))
    }

    @Test func counterExhaustionThrows() throws {
        var sealer = DatagramSealer(key: key, counter: .max - 1)
        var opener = DatagramOpener(key: key)
        let last = try sealer.seal(Data("last".utf8), channel: 1)
        #expect(try opener.open(last).plaintext == Data("last".utf8))
        #expect(throws: DatagramError.counterExhausted) { try sealer.seal(Data(), channel: 1) }
    }

    @Test func noiseDatagramKeysInteroperateOneWayEach() throws {
        let (client, hub) = try sessions()
        let clientKeys = client.datagramKeys()
        let hubKeys = hub.datagramKeys()
        var clientSealer = DatagramSealer(key: clientKeys.send)
        var hubSealer = DatagramSealer(key: hubKeys.send)
        var clientOpener = DatagramOpener(key: clientKeys.receive)
        var hubOpener = DatagramOpener(key: hubKeys.receive)

        let pad = try clientSealer.seal(Data("pad".utf8), channel: 4)
        let video = try hubSealer.seal(Data("video".utf8), channel: 1)
        #expect(throws: DatagramError.authenticationFailed) { try clientOpener.open(pad) }
        #expect(throws: DatagramError.authenticationFailed) { try hubOpener.open(video) }
        let up = try hubOpener.open(pad)
        #expect(up.channel == 4 && up.plaintext == Data("pad".utf8))
        let down = try clientOpener.open(video)
        #expect(down.channel == 1 && down.plaintext == Data("video".utf8))
    }
}

struct ReplayWindowTests {
    @Test func theSizeRoundsUpToWholeWords() {
        #expect(ReplayWindow(size: 1).size == 64)
        #expect(ReplayWindow(size: 64).size == 64)
        #expect(ReplayWindow(size: 65).size == 128)
        #expect(ReplayWindow(size: 1000).size == 1024)
        #expect(ReplayWindow(size: 0).size == 64)
    }

    @Test func checkingDoesNotCommit() {
        var window = ReplayWindow(size: 128)
        #expect(window.canAccept(5))
        #expect(window.canAccept(5))
        window.accept(5)
        #expect(window.canAccept(5) == false)
        #expect(window.canAccept(4))
        #expect(window.canAccept(6))
    }

    @Test func theWindowCoversExactlyItsSize() {
        var window = ReplayWindow(size: 128)
        window.accept(10_000)
        #expect(window.canAccept(10_000 - 127))
        #expect(window.canAccept(10_000 - 128) == false)
        window.accept(10_000 - 128)
        #expect(window.canAccept(10_000 - 127))
        window.accept(10_000 - 127)
        #expect(window.canAccept(10_000 - 127) == false)
    }

    @Test func everyCounterAfterARandomWalkIsSeenOnce() {
        var window = ReplayWindow(size: 256)
        var seen = Set<UInt64>()
        var highest: UInt64 = 0
        var generator = SplitMix(seed: 42)
        for _ in 0..<20_000 {
            let step = generator.next() % 600
            let counter = generator.next() % 4 == 0 ? highest + step : highest &- min(highest, step % 300)
            let expected = !seen.contains(counter) && (counter >= highest || highest - counter < 256)
            #expect(window.canAccept(counter) == expected)
            if expected {
                window.accept(counter)
                seen.insert(counter)
                highest = max(highest, counter)
            }
        }
    }
}

private struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
