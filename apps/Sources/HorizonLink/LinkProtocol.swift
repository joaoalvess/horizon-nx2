import Foundation

public enum LinkProtocol {
    public static let version: UInt16 = 1
    public static let serviceType = "_horizonhub._tcp"
    public static let datagramBudget = 1200
    public static let maxClearMessage = 4096
    public static let maxSecureMessage = NoiseCipherState.maxMessageSize
    public static let clientKeySize = 32
    public static let hubIdSize = 8
}

public enum MediaChannel: UInt8, Sendable {
    case hello = 1
    case video = 2
    case audio = 3
    case feedback = 4
    case nack = 5
    case ping = 6
    case pong = 7
    case decoded = 8
    case pad = 9
}

public struct LinkFramer: Sendable {
    public var limit: Int
    private var buffer = Data()

    public init(limit: Int) {
        self.limit = limit
    }

    public static func frame(_ body: Data) -> Data {
        var writer = ByteWriter(capacity: body.count + 4)
        writer.u32(UInt32(body.count))
        writer.bytes(body)
        return writer.data
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        var reader = ByteReader(buffer.prefix(4))
        let length = Int(try reader.u32())
        guard length <= limit else { throw WireError.invalid("a \(length)-byte message is over the \(limit)-byte limit") }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
        if buffer.isEmpty { buffer = Data() }
        return body
    }
}

public struct ClientHello: Equatable, Sendable {
    public var version: UInt16
    public var name: String
    public var clientKey: Data

    public init(version: UInt16 = LinkProtocol.version, name: String, clientKey: Data) {
        self.version = version
        self.name = name
        self.clientKey = clientKey
    }
}

public struct HubHello: Equatable, Sendable {
    public var version: UInt16
    public var name: String
    public var hubId: Data
    public var paired: Bool

    public init(version: UInt16 = LinkProtocol.version, name: String, hubId: Data, paired: Bool) {
        self.version = version
        self.name = name
        self.hubId = hubId
        self.paired = paired
    }
}

public enum ClearMessage: Equatable, Sendable {
    case clientHello(ClientHello)
    case hubHello(HubHello)
    case pairCommit(Data)
    case pairHubKey(key: Data, nonce: Data)
    case pairReveal(key: Data, nonce: Data)
    case pairResult(accepted: Bool, reason: String)
    case handshake(Data)
    case refused(String)

    public func encoded() -> Data {
        var writer = ByteWriter()
        switch self {
        case .clientHello(let hello):
            writer.u8(1)
            writer.u16(hello.version)
            writer.bytes(hello.clientKey.prefix(LinkProtocol.clientKeySize))
            writer.bytes(Data(hello.name.utf8.prefix(200)))
        case .hubHello(let hello):
            writer.u8(2)
            writer.u16(hello.version)
            writer.bytes(hello.hubId.prefix(LinkProtocol.hubIdSize))
            writer.u8(hello.paired ? 1 : 0)
            writer.bytes(Data(hello.name.utf8.prefix(200)))
        case .pairCommit(let commitment):
            writer.u8(3)
            writer.bytes(commitment)
        case .pairHubKey(let key, let nonce):
            writer.u8(4)
            writer.bytes(key)
            writer.bytes(nonce)
        case .pairReveal(let key, let nonce):
            writer.u8(5)
            writer.bytes(key)
            writer.bytes(nonce)
        case .pairResult(let accepted, let reason):
            writer.u8(6)
            writer.u8(accepted ? 1 : 0)
            writer.bytes(Data(reason.utf8.prefix(500)))
        case .handshake(let message):
            writer.u8(7)
            writer.bytes(message)
        case .refused(let reason):
            writer.u8(8)
            writer.bytes(Data(reason.utf8.prefix(500)))
        }
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        switch try reader.u8() {
        case 1:
            let version = try reader.u16()
            let key = try reader.bytes(LinkProtocol.clientKeySize)
            self = .clientHello(ClientHello(version: version, name: String(decoding: reader.rest(), as: UTF8.self), clientKey: key))
        case 2:
            let version = try reader.u16()
            let hubId = try reader.bytes(LinkProtocol.hubIdSize)
            let paired = try reader.u8() != 0
            self = .hubHello(HubHello(version: version, name: String(decoding: reader.rest(), as: UTF8.self), hubId: hubId, paired: paired))
        case 3:
            self = .pairCommit(try reader.bytes(32))
        case 4:
            self = .pairHubKey(key: try reader.bytes(32), nonce: try reader.bytes(Pairing.nonceSize))
        case 5:
            self = .pairReveal(key: try reader.bytes(32), nonce: try reader.bytes(Pairing.nonceSize))
        case 6:
            let accepted = try reader.u8() != 0
            self = .pairResult(accepted: accepted, reason: String(decoding: reader.rest(), as: UTF8.self))
        case 7:
            self = .handshake(reader.rest())
        case 8:
            self = .refused(String(decoding: reader.rest(), as: UTF8.self))
        case let other:
            throw WireError.invalid("unknown clear message \(other)")
        }
    }
}

public struct LinkProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var nick: String

    public init(id: String, name: String, nick: String) {
        self.id = id
        self.name = name
        self.nick = nick
    }
}

public struct LinkGame: Equatable, Sendable, Identifiable {
    public enum Status: UInt8, Sendable {
        case available = 0
        case running = 1
        case blocked = 2
        case busy = 3
        case unavailable = 4
    }

    public var id: String
    public var title: String
    public var status: Status
    public var detail: String

    public init(id: String, title: String, status: Status, detail: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

public struct LinkState: Equatable, Sendable {
    public var game: String?
    public var title: String?
    public var profile: String?
    public var streaming: Bool
    public var paused: Bool

    public init(game: String? = nil, title: String? = nil, profile: String? = nil, streaming: Bool = false, paused: Bool = false) {
        self.game = game
        self.title = title
        self.profile = profile
        self.streaming = streaming
        self.paused = paused
    }
}

public struct Welcome: Equatable, Sendable {
    public var udpPort: UInt16
    public var sessionId: UInt32
    public var hubName: String

    public init(udpPort: UInt16, sessionId: UInt32, hubName: String) {
        self.udpPort = udpPort
        self.sessionId = sessionId
        self.hubName = hubName
    }
}

public enum ControlMessage: Equatable, Sendable {
    case welcome(Welcome)
    case catalog(profiles: [LinkProfile], games: [LinkGame])
    case state(LinkState)
    case attach(DMStream.Attach)
    case detach(pause: Bool)
    case open(profile: String, game: String)
    case close
    case pads(DMStream.Pads)
    case bitrate(UInt32)
    case notice(String)
    case stats(String)
    case keepalive

    public func encoded() -> Data {
        var writer = ByteWriter()
        switch self {
        case .welcome(let welcome):
            writer.u8(1)
            writer.u16(welcome.udpPort)
            writer.u32(welcome.sessionId)
            writer.string(welcome.hubName)
        case .catalog(let profiles, let games):
            writer.u8(2)
            writer.u16(UInt16(clamping: profiles.count))
            for profile in profiles.prefix(Int(UInt16.max)) {
                writer.string(profile.id)
                writer.string(profile.name)
                writer.string(profile.nick)
            }
            writer.u16(UInt16(clamping: games.count))
            for game in games.prefix(Int(UInt16.max)) {
                writer.string(game.id)
                writer.string(game.title)
                writer.u8(game.status.rawValue)
                writer.string(game.detail)
            }
        case .state(let state):
            writer.u8(3)
            writer.u8((state.streaming ? 1 : 0) | (state.paused ? 2 : 0) | (state.game != nil ? 4 : 0))
            writer.string(state.game ?? "")
            writer.string(state.title ?? "")
            writer.string(state.profile ?? "")
        case .attach(let attach):
            writer.u8(4)
            writer.u16(attach.refreshHz)
            writer.u16(attach.width)
            writer.u16(attach.height)
            writer.u32(attach.codec)
            writer.u32(attach.bitrateKbps)
        case .detach(let pause):
            writer.u8(5)
            writer.u8(pause ? 1 : 0)
        case .open(let profile, let game):
            writer.u8(6)
            writer.string(profile)
            writer.string(game)
        case .close:
            writer.u8(7)
        case .pads(let pads):
            writer.u8(8)
            writer.u32(pads.mask)
            for player in 0..<DMStream.players {
                writer.u8(player < pads.styles.count ? pads.styles[player] : 0)
            }
        case .bitrate(let kbps):
            writer.u8(9)
            writer.u32(kbps)
        case .notice(let text):
            writer.u8(10)
            writer.string(text)
        case .stats(let text):
            writer.u8(11)
            writer.string(text)
        case .keepalive:
            writer.u8(12)
        }
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        switch try reader.u8() {
        case 1:
            self = .welcome(Welcome(udpPort: try reader.u16(), sessionId: try reader.u32(), hubName: try reader.string()))
        case 2:
            let profiles = try (0..<Int(try reader.u16())).map { _ in
                LinkProfile(id: try reader.string(), name: try reader.string(), nick: try reader.string())
            }
            let games = try (0..<Int(try reader.u16())).map { _ in
                let id = try reader.string()
                let title = try reader.string()
                let status = LinkGame.Status(rawValue: try reader.u8()) ?? .unavailable
                return LinkGame(id: id, title: title, status: status, detail: try reader.string())
            }
            self = .catalog(profiles: profiles, games: games)
        case 3:
            let flags = try reader.u8()
            let game = try reader.string()
            let title = try reader.string()
            let profile = try reader.string()
            let running = flags & 4 != 0
            self = .state(LinkState(
                game: running ? game : nil, title: running ? title : nil, profile: running ? profile : nil,
                streaming: flags & 1 != 0, paused: flags & 2 != 0
            ))
        case 4:
            self = .attach(DMStream.Attach(
                refreshHz: try reader.u16(), width: try reader.u16(), height: try reader.u16(), codec: try reader.u32(),
                bitrateKbps: try reader.u32()
            ))
        case 5:
            self = .detach(pause: try reader.u8() != 0)
        case 6:
            self = .open(profile: try reader.string(), game: try reader.string())
        case 7:
            self = .close
        case 8:
            let mask = try reader.u32()
            self = .pads(DMStream.Pads(mask: mask, styles: try (0..<DMStream.players).map { _ in try reader.u8() }))
        case 9:
            self = .bitrate(try reader.u32())
        case 10:
            self = .notice(try reader.string())
        case 11:
            self = .stats(try reader.string())
        case 12:
            self = .keepalive
        case let other:
            throw WireError.invalid("unknown control message \(other)")
        }
    }
}

public struct FrameEnvelope: Equatable, Sendable {
    public var presentNs: UInt64
    public var frameNumber: UInt64
    public var ltrToken: Int64
    public var parameterSets: [Data]
    public var accessUnit: Data

    public init(presentNs: UInt64, frameNumber: UInt64, ltrToken: Int64, parameterSets: [Data] = [], accessUnit: Data) {
        self.presentNs = presentNs
        self.frameNumber = frameNumber
        self.ltrToken = ltrToken
        self.parameterSets = parameterSets
        self.accessUnit = accessUnit
    }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: accessUnit.count + 64)
        writer.u64(presentNs)
        writer.u64(frameNumber)
        writer.i64(ltrToken)
        writer.u8(UInt8(clamping: parameterSets.count))
        for set in parameterSets.prefix(255) {
            writer.u16(UInt16(clamping: set.count))
            writer.bytes(set.prefix(Int(UInt16.max)))
        }
        writer.bytes(accessUnit)
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        presentNs = try reader.u64()
        frameNumber = try reader.u64()
        ltrToken = try reader.i64()
        parameterSets = try (0..<Int(try reader.u8())).map { _ in try reader.bytes(Int(try reader.u16())) }
        accessUnit = reader.rest()
    }
}

public enum VideoFlags {
    public static let sync: UInt8 = 1 << 0
    public static let refresh: UInt8 = 1 << 1
    public static let config: UInt8 = 1 << 2
}

public struct AudioPacket: Equatable, Sendable {
    public var hostTimeNs: UInt64
    public var sequence: UInt32
    public var samples: Data

    public init(hostTimeNs: UInt64, sequence: UInt32, samples: Data) {
        self.hostTimeNs = hostTimeNs
        self.sequence = sequence
        self.samples = samples
    }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: samples.count + 12)
        writer.u64(hostTimeNs)
        writer.u32(sequence)
        writer.bytes(samples)
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        hostTimeNs = try reader.u64()
        sequence = try reader.u32()
        samples = reader.rest()
        guard samples.count % 4 == 0 else { throw WireError.invalid("audio samples are not whole stereo frames") }
    }
}

public struct FeedbackPacket: Equatable, Sendable {
    public var lastCompleteFrame: UInt32
    public var lastDecodedFrame: UInt32
    public var refreshRequest: UInt32
    public var receivedShards: UInt32
    public var recoveredShards: UInt32
    public var lostFrames: UInt32
    public var decodeP95Us: UInt32
    public var ltrAcks: [Int64]

    public init(
        lastCompleteFrame: UInt32 = 0, lastDecodedFrame: UInt32 = 0, refreshRequest: UInt32 = 0, receivedShards: UInt32 = 0,
        recoveredShards: UInt32 = 0, lostFrames: UInt32 = 0, decodeP95Us: UInt32 = 0, ltrAcks: [Int64] = []
    ) {
        self.lastCompleteFrame = lastCompleteFrame
        self.lastDecodedFrame = lastDecodedFrame
        self.refreshRequest = refreshRequest
        self.receivedShards = receivedShards
        self.recoveredShards = recoveredShards
        self.lostFrames = lostFrames
        self.decodeP95Us = decodeP95Us
        self.ltrAcks = ltrAcks
    }

    public static let maxAcks = 32

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: 40 + ltrAcks.count * 8)
        writer.u32(lastCompleteFrame)
        writer.u32(lastDecodedFrame)
        writer.u32(refreshRequest)
        writer.u32(receivedShards)
        writer.u32(recoveredShards)
        writer.u32(lostFrames)
        writer.u32(decodeP95Us)
        let acks = ltrAcks.suffix(Self.maxAcks)
        writer.u8(UInt8(acks.count))
        acks.forEach { writer.i64($0) }
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        lastCompleteFrame = try reader.u32()
        lastDecodedFrame = try reader.u32()
        refreshRequest = try reader.u32()
        receivedShards = try reader.u32()
        recoveredShards = try reader.u32()
        lostFrames = try reader.u32()
        decodeP95Us = try reader.u32()
        let count = Int(try reader.u8())
        guard count <= Self.maxAcks else { throw WireError.invalid("too many LTR acks") }
        ltrAcks = try (0..<count).map { _ in try reader.i64() }
    }
}

public struct NackPacket: Equatable, Sendable {
    public struct Need: Equatable, Sendable {
        public var block: UInt8
        public var count: UInt8

        public init(block: UInt8, count: UInt8) {
            self.block = block
            self.count = count
        }
    }

    public var frame: UInt32
    public var needs: [Need]

    public init(frame: UInt32, needs: [Need]) {
        self.frame = frame
        self.needs = needs
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.u32(frame)
        writer.u8(UInt8(clamping: needs.count))
        for need in needs.prefix(255) {
            writer.u8(need.block)
            writer.u8(need.count)
        }
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        frame = try reader.u32()
        needs = try (0..<Int(try reader.u8())).map { _ in Need(block: try reader.u8(), count: try reader.u8()) }
    }
}

public struct PingPacket: Equatable, Sendable {
    public var sequence: UInt32
    public var clientSendNs: UInt64

    public init(sequence: UInt32, clientSendNs: UInt64) {
        self.sequence = sequence
        self.clientSendNs = clientSendNs
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.u32(sequence)
        writer.u64(clientSendNs)
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        sequence = try reader.u32()
        clientSendNs = try reader.u64()
    }
}

public struct PongPacket: Equatable, Sendable {
    public var sequence: UInt32
    public var clientSendNs: UInt64
    public var hubReceiveNs: UInt64
    public var hubSendNs: UInt64

    public init(sequence: UInt32, clientSendNs: UInt64, hubReceiveNs: UInt64, hubSendNs: UInt64) {
        self.sequence = sequence
        self.clientSendNs = clientSendNs
        self.hubReceiveNs = hubReceiveNs
        self.hubSendNs = hubSendNs
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.u32(sequence)
        writer.u64(clientSendNs)
        writer.u64(hubReceiveNs)
        writer.u64(hubSendNs)
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        sequence = try reader.u32()
        clientSendNs = try reader.u64()
        hubReceiveNs = try reader.u64()
        hubSendNs = try reader.u64()
    }

    public func sample(clientReceiveNs: UInt64) -> ClockSample {
        ClockSample(clientSendNs: clientSendNs, hubReceiveNs: hubReceiveNs, hubSendNs: hubSendNs, clientReceiveNs: clientReceiveNs)
    }
}

public struct DecodedPacket: Equatable, Sendable {
    public var frame: UInt32
    public var decodedNs: UInt64

    public init(frame: UInt32, decodedNs: UInt64) {
        self.frame = frame
        self.decodedNs = decodedNs
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.u32(frame)
        writer.u64(decodedNs)
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        frame = try reader.u32()
        decodedNs = try reader.u64()
    }
}

public struct PadPacket: Equatable, Sendable {
    public var sequence: UInt32
    public var pad: DMStream.Pad

    public init(sequence: UInt32, pad: DMStream.Pad) {
        self.sequence = sequence
        self.pad = pad
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.u32(sequence)
        writer.u16(pad.motion == nil ? 0 : 1)
        writer.bytes(DMStream.encode(.pad(pad), sentNs: 0).dropFirst(DMStream.headerSize))
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        sequence = try reader.u32()
        let flags = try reader.u16()
        guard case .pad(let pad) = try DMStream.decode(
            type: DMStream.Kind.pad.rawValue, flags: flags, payload: reader.rest(), direction: .fromHub
        ) else { throw WireError.invalid("not a pad") }
        self.pad = pad
    }
}

public struct HelloPacket: Equatable, Sendable {
    public var sessionId: UInt32

    public init(sessionId: UInt32) {
        self.sessionId = sessionId
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.u32(sessionId)
        return writer.data
    }

    public init(_ data: Data) throws {
        var reader = ByteReader(data)
        sessionId = try reader.u32()
    }
}

extension ByteWriter {
    public mutating func string(_ value: String) {
        let bytes = Data(value.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(bytes.count))
        self.bytes(bytes)
    }
}

extension ByteReader {
    public mutating func string() throws -> String {
        String(decoding: try bytes(Int(try u16())), as: UTF8.self)
    }
}
