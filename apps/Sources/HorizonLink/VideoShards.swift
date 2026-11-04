import Foundation

public enum VideoShards {
    public static let maxBlockData = 48

    public static func shardSize(datagramBudget: Int, overhead: Int) -> Int {
        datagramBudget - overhead - VideoShardHeader.size
    }

    public static func shardCount(frameBytes: Int, shardSize: Int) -> Int {
        max(1, (frameBytes + shardSize - 1) / shardSize)
    }

    public static func blockSizes(shardCount: Int) -> [Int] {
        let blocks = blockCount(shardCount: shardCount)
        return (0..<blocks).map { blockSize($0, shardCount: shardCount, blockCount: blocks) }
    }

    static func blockCount(shardCount: Int) -> Int {
        (shardCount + maxBlockData - 1) / maxBlockData
    }

    static func blockSize(_ block: Int, shardCount: Int, blockCount: Int) -> Int {
        shardCount / blockCount + (block < shardCount % blockCount ? 1 : 0)
    }

    public static func precedes(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) < 0
    }
}

public struct VideoShardHeader: Equatable, Sendable {
    public static let size = 16

    public var frame: UInt32
    public var block: UInt8
    public var blockCount: UInt8
    public var index: UInt8
    public var dataCount: UInt8
    public var parityCount: UInt8
    public var flags: UInt8
    public var generation: UInt16
    public var frameBytes: UInt32

    public init(
        frame: UInt32, block: UInt8, blockCount: UInt8, index: UInt8, dataCount: UInt8, parityCount: UInt8, flags: UInt8,
        generation: UInt16, frameBytes: UInt32
    ) {
        self.frame = frame
        self.block = block
        self.blockCount = blockCount
        self.index = index
        self.dataCount = dataCount
        self.parityCount = parityCount
        self.flags = flags
        self.generation = generation
        self.frameBytes = frameBytes
    }

    public init(_ reader: inout ByteReader) throws {
        self = try reader.bytes(Self.size).withUnsafeBytes { raw in
            VideoShardHeader(
                frame: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)), block: raw[4],
                blockCount: raw[5], index: raw[6], dataCount: raw[7], parityCount: raw[8], flags: raw[9],
                generation: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 10, as: UInt16.self)),
                frameBytes: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            )
        }
    }

    public var isParity: Bool { index >= dataCount }

    public func encode(into writer: inout ByteWriter) {
        writer.u32(frame)
        writer.u8(block)
        writer.u8(blockCount)
        writer.u8(index)
        writer.u8(dataCount)
        writer.u8(parityCount)
        writer.u8(flags)
        writer.u16(generation)
        writer.u32(frameBytes)
    }
}

public struct OutgoingFrame: Sendable {
    public let frame: UInt32
    public let flags: UInt8
    public let generation: UInt16
    public let shardSize: Int
    public let frameBytes: Int
    public let dataDatagrams: [Data]
    private var blocks: [Block]

    private struct Block: Sendable {
        let code: ReedSolomon
        let data: [Data]
        let initialParity: Int
        var nextParity: Int
    }

    public init(
        frame: UInt32, flags: UInt8, generation: UInt16, payload: Data, shardSize: Int, parityRatio: Double, minimumParity: Int
    ) {
        precondition(shardSize > 0, "a video shard needs at least one byte")
        let sizes = VideoShards.blockSizes(shardCount: VideoShards.shardCount(frameBytes: payload.count, shardSize: shardSize))
        precondition(
            sizes.count <= Int(UInt8.max) && payload.count <= Int(UInt32.max),
            "a \(payload.count)-byte frame does not fit 255 blocks of \(shardSize)-byte shards"
        )
        self.frame = frame
        self.flags = flags
        self.generation = generation
        self.shardSize = shardSize
        frameBytes = payload.count
        var offset = payload.startIndex
        var perBlock: [[Data]] = []
        var blocks: [Block] = []
        for (block, dataCount) in sizes.enumerated() {
            let code = try! ReedSolomon(dataCount: dataCount)
            let wanted = Int((Double(dataCount) * parityRatio - 1e-9).rounded(.up))
            let parity = min(code.maxParityCount, max(0, minimumParity, wanted))
            var datagrams: [Data] = []
            datagrams.reserveCapacity(dataCount)
            for index in 0..<dataCount {
                let end = min(offset + shardSize, payload.endIndex)
                var writer = ByteWriter(capacity: VideoShardHeader.size + shardSize)
                VideoShardHeader(
                    frame: frame, block: UInt8(block), blockCount: UInt8(sizes.count), index: UInt8(index),
                    dataCount: UInt8(dataCount), parityCount: UInt8(parity), flags: flags, generation: generation,
                    frameBytes: UInt32(payload.count)
                ).encode(into: &writer)
                writer.bytes(payload[offset..<end])
                if end - offset < shardSize { writer.zeros(shardSize - (end - offset)) }
                datagrams.append(writer.data)
                offset = end
            }
            perBlock.append(datagrams)
            blocks.append(Block(
                code: code, data: datagrams.map { $0.dropFirst(VideoShardHeader.size) }, initialParity: parity, nextParity: parity
            ))
        }
        self.blocks = blocks
        dataDatagrams = Self.interleave(perBlock)
    }

    public var blockCount: Int { blocks.count }

    public func initialParityDatagrams() -> [Data] {
        Self.interleave(blocks.indices.map { parityDatagrams(block: $0, rows: 0..<blocks[$0].initialParity) })
    }

    public mutating func extraParityDatagrams(block: Int, count: Int) -> [Data] {
        guard blocks.indices.contains(block), count > 0 else { return [] }
        let start = blocks[block].nextParity
        let end = start + min(count, blocks[block].code.maxParityCount - start)
        blocks[block].nextParity = end
        return parityDatagrams(block: block, rows: start..<end)
    }

    private func parityDatagrams(block: Int, rows: Range<Int>) -> [Data] {
        guard !rows.isEmpty else { return [] }
        let state = blocks[block]
        let shards = state.code.parity(indices: rows, data: state.data)
        return zip(rows, shards).map { row, shard in
            var writer = ByteWriter(capacity: VideoShardHeader.size + shardSize)
            VideoShardHeader(
                frame: frame, block: UInt8(block), blockCount: UInt8(blocks.count), index: UInt8(state.code.dataCount + row),
                dataCount: UInt8(state.code.dataCount), parityCount: UInt8(state.initialParity), flags: flags,
                generation: generation, frameBytes: UInt32(frameBytes)
            ).encode(into: &writer)
            writer.bytes(shard)
            return writer.data
        }
    }

    private static func interleave(_ lists: [[Data]]) -> [Data] {
        let rounds = lists.map(\.count).max() ?? 0
        var result: [Data] = []
        result.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        for round in 0..<rounds {
            for list in lists where round < list.count { result.append(list[round]) }
        }
        return result
    }
}

public struct CompletedFrame: Equatable, Sendable {
    public let frame: UInt32
    public let flags: UInt8
    public let generation: UInt16
    public let payload: Data
    public let recoveredShards: Int

    public init(frame: UInt32, flags: UInt8, generation: UInt16, payload: Data, recoveredShards: Int) {
        self.frame = frame
        self.flags = flags
        self.generation = generation
        self.payload = payload
        self.recoveredShards = recoveredShards
    }
}

public struct FrameAssembler: Sendable {
    public let maxFrames: Int
    private var frames: [UInt32: PartialFrame] = [:]
    private var completed: [UInt32] = []
    private var floor: UInt32?

    public init(maxFrames: Int = 8) {
        self.maxFrames = max(1, maxFrames)
    }

    public var partialFrames: [UInt32] {
        frames.keys.sorted(by: VideoShards.precedes)
    }

    public mutating func add(_ datagram: Data) throws -> CompletedFrame? {
        var reader = ByteReader(datagram)
        let header = try VideoShardHeader(&reader)
        let shardSize = reader.remaining
        try Self.validate(header, shardSize: shardSize)
        let number = header.frame
        if let floor {
            if VideoShards.precedes(number, floor) { return nil }
            if number &- floor > 1 << 30 { self.floor = number &- 1 << 30 }
        }
        if completed.contains(number) { return nil }
        if frames[number] == nil {
            frames[number] = PartialFrame(header, shardSize: shardSize)
            if frames.count > maxFrames, let oldest = frames.keys.min(by: VideoShards.precedes) {
                frames[oldest] = nil
                if oldest == number { return nil }
            }
        }
        guard try frames[number]!.add(header, shard: datagram.dropFirst(VideoShardHeader.size)) else { return nil }
        let state = frames.removeValue(forKey: number)!
        completed.append(number)
        if completed.count > max(32, maxFrames * 4) { completed.removeFirst() }
        var payload = Data(capacity: state.frameBytes)
        for block in state.blocks {
            for shard in block.data ?? [] where payload.count < state.frameBytes {
                payload.append(shard.prefix(state.frameBytes - payload.count))
            }
        }
        return CompletedFrame(
            frame: number, flags: state.flags, generation: state.generation, payload: payload, recoveredShards: state.recovered
        )
    }

    public func missing(frame: UInt32) -> [(block: Int, needed: Int)] {
        guard let state = frames[frame] else { return [] }
        return state.blocks.indices.compactMap { index in
            let block = state.blocks[index]
            return block.data == nil ? (block: index, needed: block.dataCount - block.shards.count) : nil
        }
    }

    public mutating func drop(framesBefore frame: UInt32) {
        frames = frames.filter { !VideoShards.precedes($0.key, frame) }
        completed.removeAll { VideoShards.precedes($0, frame) }
        if floor.map({ VideoShards.precedes($0, frame) }) ?? true { floor = frame }
    }

    private static func validate(_ header: VideoShardHeader, shardSize: Int) throws {
        func invalid(_ detail: String) -> WireError {
            .invalid("block \(header.block) of frame \(header.frame) \(detail)")
        }
        guard shardSize > 0 else { throw invalid("carries an empty shard") }
        guard header.dataCount > 0 else { throw invalid("has no data shards") }
        guard header.block < header.blockCount else { throw invalid("is outside its \(header.blockCount) blocks") }
        guard Int(header.dataCount) + Int(header.parityCount) <= ReedSolomon.maxShards else {
            throw invalid("declares \(header.dataCount) data and \(header.parityCount) parity shards")
        }
        let shards = VideoShards.shardCount(frameBytes: Int(header.frameBytes), shardSize: shardSize)
        let blocks = VideoShards.blockCount(shardCount: shards)
        guard blocks == Int(header.blockCount),
              VideoShards.blockSize(Int(header.block), shardCount: shards, blockCount: blocks) == Int(header.dataCount)
        else {
            throw invalid(
                "declares \(header.blockCount) blocks and \(header.dataCount) data shards, which do not fit \(header.frameBytes) bytes in \(shardSize)-byte shards"
            )
        }
    }
}

private struct PartialFrame: Sendable {
    struct Block: Sendable {
        let dataCount: Int
        var parityCount: UInt8?
        var shards: [Int: Data] = [:]
        var data: [Data]?
    }

    let flags: UInt8
    let generation: UInt16
    let frameBytes: Int
    let shardSize: Int
    var blocks: [Block]
    var incomplete: Int
    var recovered = 0

    init(_ header: VideoShardHeader, shardSize: Int) {
        flags = header.flags
        generation = header.generation
        frameBytes = Int(header.frameBytes)
        self.shardSize = shardSize
        let count = Int(header.blockCount)
        let shards = VideoShards.shardCount(frameBytes: frameBytes, shardSize: shardSize)
        blocks = (0..<count).map { Block(dataCount: VideoShards.blockSize($0, shardCount: shards, blockCount: count)) }
        incomplete = count
    }

    mutating func add(_ header: VideoShardHeader, shard: Data) throws -> Bool {
        guard header.flags == flags, header.generation == generation, Int(header.frameBytes) == frameBytes,
              Int(header.blockCount) == blocks.count, shard.count == shardSize
        else { throw WireError.invalid("frame \(header.frame) changed its header between shards") }
        let index = Int(header.block)
        if let parity = blocks[index].parityCount, parity != header.parityCount {
            throw WireError.invalid("block \(index) of frame \(header.frame) changed its parity count")
        }
        blocks[index].parityCount = header.parityCount
        guard blocks[index].data == nil, blocks[index].shards[Int(header.index)] == nil else { return false }
        blocks[index].shards[Int(header.index)] = shard
        let dataCount = blocks[index].dataCount
        guard blocks[index].shards.count == dataCount else { return false }
        let shards = blocks[index].shards
        let lost = (0..<dataCount).count { shards[$0] == nil }
        blocks[index].data = lost == 0
            ? (0..<dataCount).map { shards[$0]! }
            : try ReedSolomon(dataCount: dataCount).reconstruct(shards, shardSize: shardSize)
        blocks[index].shards = [:]
        recovered += lost
        incomplete -= 1
        return incomplete == 0
    }
}
