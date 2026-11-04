import Foundation

public struct VideoSenderSettings: Sendable, Equatable {
    public var parityRatio: Double
    public var minimumParity: Int
    public var keptFrames: Int
    public var repairMargin: Int

    public init(parityRatio: Double = 0.1, minimumParity: Int = 1, keptFrames: Int = 6, repairMargin: Int = 1) {
        self.parityRatio = parityRatio
        self.minimumParity = minimumParity
        self.keptFrames = keptFrames
        self.repairMargin = repairMargin
    }
}

public struct VideoPacket: Sendable {
    public let frame: UInt32
    public let flags: UInt8
    public let payloadBytes: Int
    public let data: [Data]
    public let parity: [Data]
}

public struct VideoSender: Sendable {
    public static let defaultShardSize = VideoShards.shardSize(
        datagramBudget: LinkProtocol.datagramBudget, overhead: DatagramSealer.overhead
    )

    public let shardSize: Int
    public var settings: VideoSenderSettings
    public private(set) var generation: UInt16 = 0
    public private(set) var parameterSets: [Data] = []
    private var configPending = false
    private var nextFrame: UInt32 = 1
    private var kept: [OutgoingFrame] = []

    public init(shardSize: Int = VideoSender.defaultShardSize, settings: VideoSenderSettings = VideoSenderSettings()) {
        self.shardSize = shardSize
        self.settings = settings
    }

    public mutating func configure(_ sets: [Data]) {
        guard sets != parameterSets else { return }
        parameterSets = sets
        generation &+= 1
        configPending = true
    }

    public mutating func resendConfiguration() {
        configPending = true
    }

    public mutating func packetize(_ video: DMStream.VideoFrame) -> VideoPacket {
        var flags: UInt8 = 0
        if video.flags.contains(.sync) { flags |= VideoFlags.sync }
        if video.flags.contains(.refresh) { flags |= VideoFlags.refresh }
        let carriesConfig = !parameterSets.isEmpty && (configPending || flags != 0)
        if carriesConfig {
            flags |= VideoFlags.config
            configPending = false
        }
        let payload = FrameEnvelope(
            presentNs: video.presentNs, frameNumber: video.frameNumber, ltrToken: video.ltrToken,
            parameterSets: carriesConfig ? parameterSets : [], accessUnit: video.accessUnit
        ).encoded()
        let frame = nextFrame
        nextFrame &+= 1
        let outgoing = OutgoingFrame(
            frame: frame, flags: flags, generation: generation, payload: payload, shardSize: shardSize,
            parityRatio: settings.parityRatio, minimumParity: settings.minimumParity
        )
        kept.append(outgoing)
        if kept.count > settings.keptFrames { kept.removeFirst(kept.count - settings.keptFrames) }
        return VideoPacket(
            frame: frame, flags: flags, payloadBytes: payload.count, data: outgoing.dataDatagrams,
            parity: outgoing.initialParityDatagrams()
        )
    }

    public mutating func repair(_ nack: NackPacket) -> [Data] {
        guard let index = kept.firstIndex(where: { $0.frame == nack.frame }) else { return [] }
        let needs: [(block: Int, count: Int)]
        if nack.needs.isEmpty {
            let shards = VideoShards.shardCount(frameBytes: kept[index].frameBytes, shardSize: shardSize)
            needs = VideoShards.blockSizes(shardCount: shards).enumerated().map { (block: $0.offset, count: $0.element) }
        } else {
            needs = nack.needs.map { (block: Int($0.block), count: Int($0.count)) }
        }
        var datagrams: [Data] = []
        for need in needs {
            datagrams += kept[index].extraParityDatagrams(block: need.block, count: need.count + settings.repairMargin)
        }
        return datagrams
    }
}

public struct VideoReceiverSettings: Sendable, Equatable {
    public var nackDelayNs: UInt64
    public var nackIntervalNs: UInt64
    public var maxNacks: Int
    public var giveUpNs: UInt64
    public var refreshIntervalNs: UInt64
    public var maxFrames: Int

    public init(
        nackDelayNs: UInt64 = 3_000_000, nackIntervalNs: UInt64 = 8_000_000, maxNacks: Int = 3, giveUpNs: UInt64 = 30_000_000,
        refreshIntervalNs: UInt64 = 100_000_000, maxFrames: Int = 8
    ) {
        self.nackDelayNs = nackDelayNs
        self.nackIntervalNs = nackIntervalNs
        self.maxNacks = maxNacks
        self.giveUpNs = giveUpNs
        self.refreshIntervalNs = refreshIntervalNs
        self.maxFrames = maxFrames
    }
}

public struct ReceivedVideo: Sendable, Equatable {
    public let frame: UInt32
    public let flags: UInt8
    public let generation: UInt16
    public var parameterSets: [Data]
    public let envelope: FrameEnvelope
    public let recoveredShards: Int
    public let firstShardNs: UInt64
    public let completedNs: UInt64

    public var isSync: Bool { flags & VideoFlags.sync != 0 }
    public var isRefresh: Bool { flags & VideoFlags.refresh != 0 }
}

public struct VideoReceiverStats: Sendable, Equatable {
    public var receivedShards: UInt32 = 0
    public var recoveredShards: UInt32 = 0
    public var invalidShards: UInt32 = 0
    public var completeFrames: UInt32 = 0
    public var deliveredFrames: UInt32 = 0
    public var lostFrames: UInt32 = 0
    public var droppedFrames: UInt32 = 0
    public var nacks: UInt32 = 0
    public var refreshes: UInt32 = 0

    public init() {}
}

public struct VideoReceiver: Sendable {
    public enum Output: Sendable, Equatable {
        case deliver(ReceivedVideo)
        case nack(NackPacket)
        case refresh(UInt32)
    }

    private struct Pending: Sendable {
        var firstNs: UInt64
        var lastNs: UInt64
        var nacks = 0
        var lastNackNs: UInt64 = 0
        var seen: Bool
        var flags: UInt8 = 0
    }

    public var settings: VideoReceiverSettings
    public private(set) var stats = VideoReceiverStats()
    public private(set) var refreshRequest: UInt32 = 0
    public private(set) var lastComplete: UInt32 = 0
    private var assembler: FrameAssembler
    private var next: UInt32?
    private var newest: UInt32?
    private var pending: [UInt32: Pending] = [:]
    private var ready: [UInt32: ReceivedVideo] = [:]
    private var configs: [UInt16: [Data]] = [:]
    private var needsRefresh = true
    private var waitingSince: UInt64?
    private var refreshOutstanding = false
    private var lastRefreshNs: UInt64 = 0
    private static let trackedGap: UInt32 = 64

    public init(settings: VideoReceiverSettings = VideoReceiverSettings()) {
        self.settings = settings
        assembler = FrameAssembler(maxFrames: settings.maxFrames)
    }

    public var isWaitingForRefresh: Bool { needsRefresh }

    public mutating func receive(_ datagram: Data, now: UInt64) -> [Output] {
        var reader = ByteReader(datagram)
        guard let header = try? VideoShardHeader(&reader) else {
            stats.invalidShards += 1
            return []
        }
        let number = header.frame
        if let next, VideoShards.precedes(number, next) { return [] }
        stats.receivedShards += 1
        if waitingSince == nil, needsRefresh { waitingSince = now }
        if next == nil { next = number }
        var outputs: [Output] = []
        if let newest {
            if VideoShards.precedes(newest, number) {
                var missing = newest &+ 1
                if number &- missing > Self.trackedGap {
                    missing = number &- Self.trackedGap
                    outputs += skip(to: missing, now)
                }
                while missing != number {
                    if pending[missing] == nil, ready[missing] == nil { pending[missing] = Pending(firstNs: now, lastNs: now, seen: false) }
                    missing &+= 1
                }
                self.newest = number
                let behind = pending.keys.filter { VideoShards.precedes($0, number) && pending[$0]?.nacks == 0 }
                for frame in behind.sorted(by: VideoShards.precedes) { outputs.append(nack(frame, now)) }
            }
        } else {
            newest = number
        }
        if pending[number] == nil, ready[number] == nil {
            pending[number] = Pending(firstNs: now, lastNs: now, seen: true, flags: header.flags)
        } else if pending[number] != nil {
            pending[number]?.lastNs = now
            pending[number]?.seen = true
            pending[number]?.flags = header.flags
        }
        let completed: CompletedFrame?
        do { completed = try assembler.add(datagram) } catch {
            stats.invalidShards += 1
            return outputs
        }
        if let completed, let state = pending.removeValue(forKey: number) {
            stats.completeFrames += 1
            stats.recoveredShards += UInt32(completed.recoveredShards)
            lastComplete = number
            if let envelope = try? FrameEnvelope(completed.payload) {
                if completed.flags & VideoFlags.config != 0, !envelope.parameterSets.isEmpty {
                    configs[completed.generation] = envelope.parameterSets
                    let current = completed.generation
                    if configs.count > 4, let oldest = configs.keys.max(by: { current &- $0 < current &- $1 }) {
                        configs[oldest] = nil
                    }
                }
                ready[number] = ReceivedVideo(
                    frame: number, flags: completed.flags, generation: completed.generation, parameterSets: [],
                    envelope: envelope, recoveredShards: completed.recoveredShards, firstShardNs: state.firstNs, completedNs: now
                )
            } else {
                stats.invalidShards += 1
                pending[number] = state
            }
        }
        outputs += drain(now)
        return outputs
    }

    public mutating func tick(now: UInt64) -> [Output] {
        var outputs: [Output] = []
        for frame in pending.keys.sorted(by: VideoShards.precedes) {
            guard let state = pending[frame], state.nacks < settings.maxNacks else { continue }
            let due = state.nacks == 0
                ? now &- state.lastNs >= settings.nackDelayNs
                : now &- state.lastNackNs >= settings.nackIntervalNs
            if due { outputs.append(nack(frame, now)) }
        }
        while let number = next, let state = pending[number], now &- state.firstNs >= settings.giveUpNs {
            outputs += abandonHead(number, state: state, now: now)
            outputs += drain(now)
        }
        if needsRefresh, let since = waitingSince, now &- since >= settings.giveUpNs {
            outputs += requestRefresh(now)
        }
        return outputs
    }

    public mutating func requestRefresh(now: UInt64) -> [Output] {
        if !needsRefresh {
            needsRefresh = true
            waitingSince = now
        }
        return requestRefresh(now)
    }

    private mutating func nack(_ frame: UInt32, _ now: UInt64) -> Output {
        pending[frame]?.nacks += 1
        pending[frame]?.lastNackNs = now
        stats.nacks += 1
        let needs = pending[frame]?.seen == true
            ? assembler.missing(frame: frame).map { NackPacket.Need(block: UInt8($0.block), count: UInt8(clamping: $0.needed)) }
            : []
        return .nack(NackPacket(frame: frame, needs: needs))
    }

    private mutating func abandonHead(_ number: UInt32, state: Pending, now: UInt64) -> [Output] {
        pending[number] = nil
        stats.lostFrames += 1
        next = number &+ 1
        assembler.drop(framesBefore: number &+ 1)
        if state.flags & (VideoFlags.sync | VideoFlags.refresh) != 0 { refreshOutstanding = false }
        if !needsRefresh {
            needsRefresh = true
            waitingSince = now
        }
        return requestRefresh(now)
    }

    private mutating func skip(to first: UInt32, _ now: UInt64) -> [Output] {
        guard let head = next, VideoShards.precedes(head, first) else { return [] }
        let dropped = UInt32(ready.keys.filter { VideoShards.precedes($0, first) }.count)
        ready = ready.filter { !VideoShards.precedes($0.key, first) }
        pending = pending.filter { !VideoShards.precedes($0.key, first) }
        stats.droppedFrames += dropped
        stats.lostFrames &+= (first &- head) &- dropped
        next = first
        assembler.drop(framesBefore: first)
        refreshOutstanding = false
        if !needsRefresh {
            needsRefresh = true
            waitingSince = now
        }
        return requestRefresh(now)
    }

    private mutating func requestRefresh(_ now: UInt64) -> [Output] {
        if refreshOutstanding, now &- lastRefreshNs < settings.refreshIntervalNs { return [] }
        refreshRequest &+= 1
        lastRefreshNs = now
        refreshOutstanding = true
        stats.refreshes += 1
        return [.refresh(refreshRequest)]
    }

    private mutating func drain(_ now: UInt64) -> [Output] {
        var outputs: [Output] = []
        while let number = next, var video = ready.removeValue(forKey: number) {
            next = number &+ 1
            if needsRefresh {
                guard video.isSync || video.isRefresh, configs[video.generation] != nil else {
                    stats.droppedFrames += 1
                    continue
                }
                needsRefresh = false
                waitingSince = nil
                refreshOutstanding = false
            }
            guard let sets = configs[video.generation] else {
                stats.droppedFrames += 1
                needsRefresh = true
                waitingSince = now
                outputs += requestRefresh(now)
                continue
            }
            video.parameterSets = sets
            stats.deliveredFrames += 1
            outputs.append(.deliver(video))
        }
        return outputs
    }
}
