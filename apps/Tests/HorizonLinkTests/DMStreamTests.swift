import Foundation
import Testing
@testable import HorizonLink

struct DMStreamTests {
    private func roundTrip(_ message: DMStream.Message, _ direction: DMStream.Direction) throws -> DMStream.Message {
        var parser = DMStream.Parser(direction: direction)
        parser.append(DMStream.encode(message, sentNs: 42))
        let decoded = try #require(try parser.next())
        #expect(decoded.header.sentNs == 42)
        #expect(parser.buffered == 0)
        return decoded.message
    }

    @Test func everyMessageSurvivesARoundTrip() throws {
        let fromHost: [DMStream.Message] = [
            .hostHello(.init(titleId: 0x0400_C3F0_0006_E000, width: 1920, height: 1080, codecs: [DMStream.Codec.avc1.rawValue, DMStream.Codec.hvc1.rawValue], build: "abc 2026-11-03")),
            .videoConfig([Data([0x67, 1, 2]), Data([0x68, 3])]),
            .videoFrame(.init(presentNs: 7, frameNumber: 9, ltrToken: 3, flags: [.sync, .refresh], accessUnit: Data([0, 0, 0, 1, 0x65]))),
            .audio(.init(hostTimeNs: 11, frameCount: 2, samples: Data(repeating: 1, count: 8))),
            .stats("encode_p50_ms=2.1 dropped=0"),
            .attachResult(.init(ok: true, width: 1280, height: 720, codec: DMStream.Codec.avc1.rawValue)),
            .attachResult(.init(ok: false, width: 1920, height: 1080, codec: DMStream.Codec.hvc1.rawValue, reason: "no encoder")),
        ]
        for message in fromHost { #expect(try roundTrip(message, .fromHost) == message) }
        let fromHub: [DMStream.Message] = [
            .hubHello(1),
            .attach(.init(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 25000)),
            .detach(pause: true),
            .detach(pause: false),
            .pad(.init(player: 1, buttons: DMStream.Button.a | DMStream.Button.zr, leftX: -32767, leftY: 12, rightX: 0, rightY: 32767)),
            .pad(.init(player: 0, motion: .init(acceleration: SIMD3(0, 0, -1), rotation: SIMD3(0.5, 0, 0)))),
            .ltrAck([1, 2, -1]),
            .refresh,
            .bitrate(18000),
            .pads(.init(mask: 0b11, styles: [1, 1, 0, 0, 0, 0, 0, 0])),
        ]
        for message in fromHub { #expect(try roundTrip(message, .fromHub) == message) }
    }

    @Test func attachAndPadsMatchTheProbeLayout() {
        let attach = DMStream.encode(.attach(.init(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 25000)), sentNs: 0)
        #expect(attach.count == DMStream.headerSize + 16)
        #expect(Array(attach.prefix(8)) == [16, 0, 0, 0, 16, 0, 0, 0])
        #expect(Array(attach.suffix(16)) == [60, 0, 0x80, 7, 0x38, 4, 0, 0, 0x31, 0x63, 0x76, 0x61, 0xA8, 0x61, 0, 0])
        let pads = DMStream.encode(.pads(.init(mask: 1, styles: [DMStream.styleProController])), sentNs: 0)
        #expect(Array(pads.suffix(12)) == [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func theParserWaitsForWholeMessagesAndSkipsUnknownTypes() throws {
        var bytes = DMStream.encode(.unknown(type: 99, flags: 0, payload: Data([1, 2, 3])), sentNs: 1)
        bytes.append(DMStream.encode(.stats("a=1"), sentNs: 2))
        var parser = DMStream.Parser(direction: .fromHost)
        parser.append(bytes.prefix(10))
        #expect(try parser.next() == nil)
        parser.append(bytes.dropFirst(10))
        let first = try #require(try parser.next())
        #expect(first.message == .unknown(type: 99, flags: 0, payload: Data([1, 2, 3])))
        let second = try #require(try parser.next())
        #expect(second.message == .stats("a=1"))
        #expect(try parser.next() == nil)
    }

    @Test func anOversizedPayloadIsRejected() {
        var writer = ByteWriter()
        writer.u32(UInt32(DMStream.maxPayload + 1))
        writer.u16(3)
        writer.u16(0)
        writer.u64(0)
        var parser = DMStream.Parser(direction: .fromHost)
        parser.append(writer.data)
        #expect(throws: WireError.self) { try parser.next() }
    }

    @Test func attachResultMatchesTheHostLayout() throws {
        var writer = ByteWriter()
        writer.u8(0)
        writer.u8(0)
        writer.u16(1920)
        writer.u16(1080)
        writer.u16(0)
        writer.u32(DMStream.Codec.avc1.rawValue)
        writer.bytes(Data("size 9000x1 out of range".utf8))
        let message = try DMStream.decode(type: 7, flags: 0, payload: writer.data, direction: .fromHost)
        #expect(message == .attachResult(.init(ok: false, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, reason: "size 9000x1 out of range")))
    }

    @Test func aShortAudioBlockIsRejected() {
        var writer = ByteWriter()
        writer.u64(1)
        writer.u32(240)
        writer.zeros(10)
        #expect(throws: WireError.self) {
            try DMStream.decode(type: DMStream.Kind.audio.rawValue, flags: 0, payload: writer.data, direction: .fromHost)
        }
    }
}
