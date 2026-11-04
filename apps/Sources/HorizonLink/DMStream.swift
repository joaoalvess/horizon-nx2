import Foundation

public enum DMStream {
    public static let version: UInt32 = 1
    public static let headerSize = 16
    public static let maxPayload = 8 << 20
    public static let maxSocketPath = 103
    public static let players = 8

    public enum Codec: UInt32, Sendable, CaseIterable {
        case avc1 = 0x6176_6331
        case hvc1 = 0x6876_6331
    }

    public enum Direction: Sendable {
        case fromHost
        case fromHub
    }

    public enum Kind: UInt16, Sendable {
        case hello = 1
        case videoConfig = 2
        case videoFrame = 3
        case audio = 4
        case stats = 5
        case rumble = 6
        case attachResult = 7
        case attach = 16
        case detach = 17
        case pad = 18
        case ltrAck = 19
        case refresh = 20
        case bitrate = 21
        case pads = 22
    }

    public struct FrameFlags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let sync = FrameFlags(rawValue: 1 << 0)
        public static let refresh = FrameFlags(rawValue: 1 << 1)
    }

    public enum Button {
        public static let a: UInt64 = 1 << 0
        public static let b: UInt64 = 1 << 1
        public static let x: UInt64 = 1 << 2
        public static let y: UInt64 = 1 << 3
        public static let leftStick: UInt64 = 1 << 4
        public static let rightStick: UInt64 = 1 << 5
        public static let l: UInt64 = 1 << 6
        public static let r: UInt64 = 1 << 7
        public static let zl: UInt64 = 1 << 8
        public static let zr: UInt64 = 1 << 9
        public static let plus: UInt64 = 1 << 10
        public static let minus: UInt64 = 1 << 11
        public static let left: UInt64 = 1 << 12
        public static let up: UInt64 = 1 << 13
        public static let right: UInt64 = 1 << 14
        public static let down: UInt64 = 1 << 15
        public static let shake: UInt64 = 1 << 63
        public static let stickMax: Int16 = 32767
    }

    public static let styleProController: UInt8 = 1

    public struct Header: Equatable, Sendable {
        public var length: UInt32
        public var type: UInt16
        public var flags: UInt16
        public var sentNs: UInt64

        public init(length: UInt32, type: UInt16, flags: UInt16, sentNs: UInt64) {
            self.length = length
            self.type = type
            self.flags = flags
            self.sentNs = sentNs
        }

        public init(_ data: Data) throws {
            var reader = ByteReader(data)
            length = try reader.u32()
            type = try reader.u16()
            flags = try reader.u16()
            sentNs = try reader.u64()
        }
    }

    public struct HostHello: Equatable, Sendable {
        public var version: UInt32
        public var titleId: UInt64
        public var width: UInt16
        public var height: UInt16
        public var audioRate: UInt32
        public var channels: UInt8
        public var codecs: [UInt32]
        public var build: String

        public init(
            version: UInt32 = DMStream.version, titleId: UInt64, width: UInt16, height: UInt16, audioRate: UInt32 = 48000,
            channels: UInt8 = 2, codecs: [UInt32], build: String
        ) {
            self.version = version
            self.titleId = titleId
            self.width = width
            self.height = height
            self.audioRate = audioRate
            self.channels = channels
            self.codecs = codecs
            self.build = build
        }
    }

    public struct VideoFrame: Equatable, Sendable {
        public var presentNs: UInt64
        public var frameNumber: UInt64
        public var ltrToken: Int64
        public var flags: FrameFlags
        public var accessUnit: Data

        public init(presentNs: UInt64, frameNumber: UInt64, ltrToken: Int64 = -1, flags: FrameFlags = [], accessUnit: Data) {
            self.presentNs = presentNs
            self.frameNumber = frameNumber
            self.ltrToken = ltrToken
            self.flags = flags
            self.accessUnit = accessUnit
        }
    }

    public struct Audio: Equatable, Sendable {
        public var hostTimeNs: UInt64
        public var frameCount: UInt32
        public var samples: Data

        public init(hostTimeNs: UInt64, frameCount: UInt32, samples: Data) {
            self.hostTimeNs = hostTimeNs
            self.frameCount = frameCount
            self.samples = samples
        }
    }

    public struct Attach: Equatable, Sendable {
        public var refreshHz: UInt16
        public var width: UInt16
        public var height: UInt16
        public var codec: UInt32
        public var bitrateKbps: UInt32

        public init(refreshHz: UInt16, width: UInt16, height: UInt16, codec: UInt32, bitrateKbps: UInt32) {
            self.refreshHz = refreshHz
            self.width = width
            self.height = height
            self.codec = codec
            self.bitrateKbps = bitrateKbps
        }
    }

    public struct AttachResult: Equatable, Sendable {
        public var ok: Bool
        public var width: UInt16
        public var height: UInt16
        public var codec: UInt32
        public var reason: String

        public init(ok: Bool, width: UInt16, height: UInt16, codec: UInt32, reason: String = "") {
            self.ok = ok
            self.width = width
            self.height = height
            self.codec = codec
            self.reason = reason
        }
    }

    public struct Motion: Equatable, Sendable {
        public var acceleration: SIMD3<Float>
        public var rotation: SIMD3<Float>

        public init(acceleration: SIMD3<Float>, rotation: SIMD3<Float>) {
            self.acceleration = acceleration
            self.rotation = rotation
        }
    }

    public struct Pad: Equatable, Sendable {
        public var player: UInt8
        public var buttons: UInt64
        public var leftX: Int16
        public var leftY: Int16
        public var rightX: Int16
        public var rightY: Int16
        public var motion: Motion?

        public init(
            player: UInt8, buttons: UInt64 = 0, leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0,
            motion: Motion? = nil
        ) {
            self.player = player
            self.buttons = buttons
            self.leftX = leftX
            self.leftY = leftY
            self.rightX = rightX
            self.rightY = rightY
            self.motion = motion
        }
    }

    public struct Pads: Equatable, Sendable {
        public var mask: UInt32
        public var styles: [UInt8]

        public init(mask: UInt32, styles: [UInt8]) {
            self.mask = mask
            self.styles = styles
        }
    }

    public enum Message: Equatable, Sendable {
        case hostHello(HostHello)
        case videoConfig([Data])
        case videoFrame(VideoFrame)
        case audio(Audio)
        case stats(String)
        case rumble(Data)
        case attachResult(AttachResult)
        case hubHello(UInt32)
        case attach(Attach)
        case detach(pause: Bool)
        case pad(Pad)
        case ltrAck([Int64])
        case refresh
        case bitrate(UInt32)
        case pads(Pads)
        case unknown(type: UInt16, flags: UInt16, payload: Data)

        public var kind: Kind? {
            switch self {
            case .hostHello, .hubHello: .hello
            case .videoConfig: .videoConfig
            case .videoFrame: .videoFrame
            case .audio: .audio
            case .stats: .stats
            case .rumble: .rumble
            case .attachResult: .attachResult
            case .attach: .attach
            case .detach: .detach
            case .pad: .pad
            case .ltrAck: .ltrAck
            case .refresh: .refresh
            case .bitrate: .bitrate
            case .pads: .pads
            case .unknown: nil
            }
        }
    }

    public static func encode(_ message: Message, sentNs: UInt64 = LinkClock.nowNs()) -> Data {
        var payload = ByteWriter()
        var flags: UInt16 = 0
        let type: UInt16
        switch message {
        case .hostHello(let hello):
            type = Kind.hello.rawValue
            payload.u32(hello.version)
            payload.u64(hello.titleId)
            payload.u16(hello.width)
            payload.u16(hello.height)
            payload.u32(hello.audioRate)
            payload.u8(hello.channels)
            payload.u8(UInt8(clamping: hello.codecs.count))
            payload.zeros(2)
            hello.codecs.prefix(255).forEach { payload.u32($0) }
            payload.bytes(Data(hello.build.utf8))
        case .videoConfig(let sets):
            type = Kind.videoConfig.rawValue
            for set in sets {
                payload.u16(UInt16(clamping: set.count))
                payload.bytes(set.prefix(Int(UInt16.max)))
            }
        case .videoFrame(let frame):
            type = Kind.videoFrame.rawValue
            flags = frame.flags.rawValue
            payload.u64(frame.presentNs)
            payload.u64(frame.frameNumber)
            payload.i64(frame.ltrToken)
            payload.bytes(frame.accessUnit)
        case .audio(let audio):
            type = Kind.audio.rawValue
            payload.u64(audio.hostTimeNs)
            payload.u32(audio.frameCount)
            payload.bytes(audio.samples)
        case .stats(let text):
            type = Kind.stats.rawValue
            payload.bytes(Data(text.utf8))
        case .rumble(let data):
            type = Kind.rumble.rawValue
            payload.bytes(data)
        case .attachResult(let result):
            type = Kind.attachResult.rawValue
            payload.u8(result.ok ? 1 : 0)
            payload.u8(0)
            payload.u16(result.width)
            payload.u16(result.height)
            payload.u16(0)
            payload.u32(result.codec)
            payload.bytes(Data(result.reason.utf8))
        case .hubHello(let version):
            type = Kind.hello.rawValue
            payload.u32(version)
        case .attach(let attach):
            type = Kind.attach.rawValue
            payload.u16(attach.refreshHz)
            payload.u16(attach.width)
            payload.u16(attach.height)
            payload.u16(0)
            payload.u32(attach.codec)
            payload.u32(attach.bitrateKbps)
        case .detach(let pause):
            type = Kind.detach.rawValue
            flags = pause ? 1 : 0
        case .pad(let pad):
            type = Kind.pad.rawValue
            payload.u8(pad.player)
            payload.zeros(7)
            payload.u64(pad.buttons)
            payload.i16(pad.leftX)
            payload.i16(pad.leftY)
            payload.i16(pad.rightX)
            payload.i16(pad.rightY)
            if let motion = pad.motion {
                flags = 1
                for value in [motion.acceleration.x, motion.acceleration.y, motion.acceleration.z,
                              motion.rotation.x, motion.rotation.y, motion.rotation.z] {
                    payload.f32(value)
                }
            }
        case .ltrAck(let tokens):
            type = Kind.ltrAck.rawValue
            let count = min(tokens.count, Int(UInt16.max))
            payload.u16(UInt16(count))
            tokens.prefix(count).forEach { payload.i64($0) }
        case .refresh:
            type = Kind.refresh.rawValue
        case .bitrate(let kbps):
            type = Kind.bitrate.rawValue
            payload.u32(kbps)
        case .pads(let pads):
            type = Kind.pads.rawValue
            payload.u32(pads.mask)
            for player in 0..<players {
                payload.u8(player < pads.styles.count ? pads.styles[player] : 0)
            }
        case .unknown(let unknownType, let unknownFlags, let data):
            type = unknownType
            flags = unknownFlags
            payload.bytes(data)
        }
        var out = ByteWriter(capacity: headerSize + payload.data.count)
        out.u32(UInt32(payload.data.count))
        out.u16(type)
        out.u16(flags)
        out.u64(sentNs)
        out.bytes(payload.data)
        return out.data
    }

    public static func decode(type: UInt16, flags: UInt16, payload: Data, direction: Direction) throws -> Message {
        var reader = ByteReader(payload)
        switch (Kind(rawValue: type), direction) {
        case (.hello, .fromHost):
            let version = try reader.u32()
            let titleId = try reader.u64()
            let width = try reader.u16()
            let height = try reader.u16()
            let audioRate = try reader.u32()
            let channels = try reader.u8()
            let count = Int(try reader.u8())
            try reader.skip(2)
            let codecs = try (0..<count).map { _ in try reader.u32() }
            let build = String(decoding: reader.rest(), as: UTF8.self)
            return .hostHello(HostHello(
                version: version, titleId: titleId, width: width, height: height, audioRate: audioRate, channels: channels,
                codecs: codecs, build: build
            ))
        case (.hello, .fromHub):
            return .hubHello(try reader.u32())
        case (.videoConfig, .fromHost):
            var sets: [Data] = []
            while reader.remaining > 0 {
                let length = Int(try reader.u16())
                sets.append(try reader.bytes(length))
            }
            return .videoConfig(sets)
        case (.videoFrame, .fromHost):
            let present = try reader.u64()
            let number = try reader.u64()
            let token = try reader.i64()
            return .videoFrame(VideoFrame(
                presentNs: present, frameNumber: number, ltrToken: token, flags: FrameFlags(rawValue: flags), accessUnit: reader.rest()
            ))
        case (.audio, .fromHost):
            let time = try reader.u64()
            let count = try reader.u32()
            let samples = reader.rest()
            guard samples.count == Int(count) * 4 else { throw WireError.invalid("AUDIO carries \(samples.count) bytes for \(count) frames") }
            return .audio(Audio(hostTimeNs: time, frameCount: count, samples: samples))
        case (.stats, .fromHost):
            return .stats(String(decoding: reader.rest(), as: UTF8.self))
        case (.rumble, .fromHost):
            return .rumble(reader.rest())
        case (.attachResult, .fromHost):
            let ok = try reader.u8() != 0
            try reader.skip(1)
            let width = try reader.u16()
            let height = try reader.u16()
            try reader.skip(2)
            let codec = try reader.u32()
            return .attachResult(AttachResult(
                ok: ok, width: width, height: height, codec: codec, reason: String(decoding: reader.rest(), as: UTF8.self)
            ))
        case (.attach, .fromHub):
            let refresh = try reader.u16()
            let width = try reader.u16()
            let height = try reader.u16()
            try reader.skip(2)
            let codec = try reader.u32()
            let kbps = try reader.u32()
            return .attach(Attach(refreshHz: refresh, width: width, height: height, codec: codec, bitrateKbps: kbps))
        case (.detach, .fromHub):
            return .detach(pause: flags & 1 != 0)
        case (.pad, .fromHub):
            let player = try reader.u8()
            try reader.skip(7)
            var pad = Pad(
                player: player, buttons: try reader.u64(), leftX: try reader.i16(), leftY: try reader.i16(),
                rightX: try reader.i16(), rightY: try reader.i16()
            )
            if flags & 1 != 0 {
                let values = try (0..<6).map { _ in try reader.f32() }
                pad.motion = Motion(
                    acceleration: SIMD3(values[0], values[1], values[2]), rotation: SIMD3(values[3], values[4], values[5])
                )
            }
            return .pad(pad)
        case (.ltrAck, .fromHub):
            let count = Int(try reader.u16())
            return .ltrAck(try (0..<count).map { _ in try reader.i64() })
        case (.refresh, .fromHub):
            return .refresh
        case (.bitrate, .fromHub):
            return .bitrate(try reader.u32())
        case (.pads, .fromHub):
            let mask = try reader.u32()
            return .pads(Pads(mask: mask, styles: try (0..<players).map { _ in try reader.u8() }))
        default:
            return .unknown(type: type, flags: flags, payload: payload)
        }
    }

    public struct Parser: Sendable {
        public let direction: Direction
        private var buffer = Data()
        private var offset = 0

        public init(direction: Direction) {
            self.direction = direction
        }

        public var buffered: Int { buffer.count - offset }

        public mutating func append(_ data: Data) {
            if offset > 0, offset >= buffer.count / 2 {
                buffer = buffer.subdata(in: buffer.startIndex + offset..<buffer.endIndex)
                offset = 0
            }
            buffer.append(data)
        }

        public mutating func next() throws -> (header: Header, message: Message)? {
            let start = buffer.startIndex + offset
            guard buffer.endIndex - start >= headerSize else { return nil }
            let header = try Header(buffer.subdata(in: start..<start + headerSize))
            guard header.length <= UInt32(maxPayload) else {
                throw WireError.invalid("a \(header.length)-byte payload is over the \(maxPayload)-byte limit")
            }
            let total = headerSize + Int(header.length)
            guard buffer.endIndex - start >= total else { return nil }
            let payload = buffer.subdata(in: start + headerSize..<start + total)
            offset += total
            if offset == buffer.count {
                buffer = Data()
                offset = 0
            }
            let message = try DMStream.decode(type: header.type, flags: header.flags, payload: payload, direction: direction)
            return (header, message)
        }
    }
}
