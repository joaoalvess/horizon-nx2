import Foundation
import Testing
import HorizonLink

private let linkShardSize = VideoShards.shardSize(datagramBudget: 1200, overhead: 28)

private func header(_ datagram: Data) throws -> VideoShardHeader {
    var reader = ByteReader(datagram)
    return try VideoShardHeader(&reader)
}

private func position(_ datagram: Data) throws -> [Int] {
    let value = try header(datagram)
    return [Int(value.block), Int(value.index)]
}

private func datagram(_ header: VideoShardHeader, shard: Data) -> Data {
    var writer = ByteWriter()
    header.encode(into: &writer)
    writer.bytes(shard)
    return writer.data
}

private func outgoing(
    _ payload: Data, frame: UInt32 = 7, shardSize: Int = linkShardSize, parityRatio: Double = 0.2, minimumParity: Int = 2
) -> OutgoingFrame {
    OutgoingFrame(
        frame: frame, flags: 0b101, generation: 0x1234, payload: payload, shardSize: shardSize, parityRatio: parityRatio,
        minimumParity: minimumParity
    )
}

private func byBlock(_ datagrams: [Data]) throws -> [Int: [Data]] {
    var blocks: [Int: [Data]] = [:]
    for datagram in datagrams { blocks[Int(try header(datagram).block), default: []].append(datagram) }
    return blocks
}

private func deliver(_ datagrams: [Data], to assembler: inout FrameAssembler) throws -> [CompletedFrame] {
    try datagrams.compactMap { try assembler.add($0) }
}

private func interleavedPositions(_ counts: [Int], offsets: [Int]) -> [[Int]] {
    (0..<(counts.max() ?? 0)).flatMap { round in
        counts.indices.filter { round < counts[$0] }.map { [$0, offsets[$0] + round] }
    }
}

struct VideoShardsTests {
    @Test func theHeaderIsSixteenLittleEndianBytes() throws {
        let value = VideoShardHeader(
            frame: 0x0102_0304, block: 5, blockCount: 6, index: 50, dataCount: 48, parityCount: 10, flags: 0b111,
            generation: 0xA0B0, frameBytes: 0x0005_1000
        )
        var writer = ByteWriter()
        value.encode(into: &writer)
        #expect(VideoShardHeader.size == 16)
        #expect(Array(writer.data) == [4, 3, 2, 1, 5, 6, 50, 48, 10, 7, 0xB0, 0xA0, 0, 0x10, 5, 0])
        var reader = ByteReader(writer.data)
        #expect(try VideoShardHeader(&reader) == value)
        #expect(value.isParity)
        var short = ByteReader(writer.data.prefix(15))
        #expect(throws: WireError.truncated) { try VideoShardHeader(&short) }
    }

    @Test func theLinkBudgetLeaves1156ByteShards() {
        #expect(linkShardSize == 1156)
    }

    static let frameLayouts: [(Int, [Int])] = [
        (1, [1]), (1156, [1]), (47 * 1156, [47]), (48 * 1156, [48]), (49 * 1156, [25, 24]),
        (162 * 1024, [48, 48, 48]), (321 * 1024, [48, 48, 48, 47, 47, 47]),
    ]

    @Test(arguments: frameLayouts)
    func framesAreCutIntoInterleavedBalancedBlocks(bytes: Int, sizes: [Int]) throws {
        var random = FECRandom(seed: UInt64(bytes))
        let payload = random.data(bytes)
        let frame = outgoing(payload)
        #expect(VideoShards.blockSizes(shardCount: VideoShards.shardCount(frameBytes: bytes, shardSize: 1156)) == sizes)
        #expect(frame.blockCount == sizes.count)
        let parityCounts = sizes.map { max(2, Int((Double($0) * 0.2).rounded(.up))) }
        let data = frame.dataDatagrams
        #expect(data.count == sizes.reduce(0, +))
        #expect(data.allSatisfy { $0.count == VideoShardHeader.size + 1156 })
        #expect(try data.map(position) == interleavedPositions(sizes, offsets: sizes.map { _ in 0 }))
        for datagram in data {
            let value = try header(datagram)
            #expect(value.frame == 7 && value.flags == 0b101 && value.generation == 0x1234)
            #expect(Int(value.blockCount) == sizes.count && value.frameBytes == UInt32(bytes))
            #expect(Int(value.dataCount) == sizes[Int(value.block)])
            #expect(Int(value.parityCount) == parityCounts[Int(value.block)])
        }
        let last = try #require(try data.first { try position($0) == [sizes.count - 1, sizes[sizes.count - 1] - 1] })
        #expect(last.suffix(sizes.reduce(0, +) * 1156 - bytes).allSatisfy { $0 == 0 })
        let parity = frame.initialParityDatagrams()
        #expect(parity.count == parityCounts.reduce(0, +))
        #expect(try parity.map(position) == interleavedPositions(parityCounts, offsets: sizes))
        #expect(try parity.allSatisfy { try header($0).isParity })

        var assembler = FrameAssembler()
        let plain = try deliver(data, to: &assembler)
        #expect(plain == [CompletedFrame(frame: 7, flags: 0b101, generation: 0x1234, payload: payload, recoveredShards: 0)])

        var parityFirst = FrameAssembler()
        let rebuilt = try deliver(parity + data, to: &parityFirst)
        let recovered = zip(sizes, parityCounts).reduce(0) { $0 + min($1.0, $1.1) }
        #expect(rebuilt == [CompletedFrame(frame: 7, flags: 0b101, generation: 0x1234, payload: payload, recoveredShards: recovered)])
    }

    @Test func anEmptyFrameStillTravelsAsOneShard() throws {
        let frame = outgoing(Data())
        #expect(frame.dataDatagrams.count == 1)
        var assembler = FrameAssembler()
        let done = try deliver(frame.initialParityDatagrams().suffix(1), to: &assembler)
        #expect(done.map(\.payload) == [Data()])
        #expect(done.map(\.recoveredShards) == [1])
    }

    @Test func randomLossWithinParityIsRecovered() throws {
        var random = FECRandom(seed: 11)
        let cases = [(162 * 1024, 1156), (321 * 1024, 1156)] + (0..<30).map { _ in (Int.random(in: 1...6000, using: &random), 40) }
        for (number, (bytes, shardSize)) in cases.enumerated() {
            let payload = random.data(bytes)
            let frame = outgoing(payload, frame: UInt32(number), shardSize: shardSize, parityRatio: 0.15, minimumParity: 1)
            var survivors: [Data] = []
            for shards in try byBlock(frame.dataDatagrams + frame.initialParityDatagrams()).values {
                let parityCount = Int(try header(shards[0]).parityCount)
                let losses = Int.random(in: 0...parityCount, using: &random)
                let lost = Set(Array(shards.indices).shuffled(using: &random).prefix(losses))
                for (index, shard) in shards.enumerated() where !lost.contains(index) { survivors.append(shard) }
            }
            let arrival = survivors.shuffled(using: &random)
            var used: [Int: [VideoShardHeader]] = [:]
            for datagram in arrival {
                let value = try header(datagram)
                if used[Int(value.block), default: []].count < Int(value.dataCount) { used[Int(value.block), default: []].append(value) }
            }
            let rebuilt = used.values.reduce(0) { $0 + $1.filter(\.isParity).count }
            var assembler = FrameAssembler()
            let done = try deliver(arrival, to: &assembler)
            #expect(done.map(\.payload) == [payload], "frame \(number) of \(bytes) bytes")
            #expect(done.map(\.recoveredShards) == [rebuilt])
        }
    }

    @Test func lossBeyondParityIsReportedAndExtraParityFixesIt() throws {
        var random = FECRandom(seed: 12)
        let payload = random.data(162 * 1024)
        var frame = outgoing(payload, frame: 40)
        let data = try frame.dataDatagrams.filter {
            let value = try header($0)
            return !(value.block == 1 && value.index < 12)
        }
        var assembler = FrameAssembler()
        #expect(try deliver(Array(data.prefix(48)), to: &assembler).isEmpty)
        #expect(assembler.missing(frame: 40).map { [$0.block, $0.needed] } == [[0, 28], [1, 40], [2, 28]])
        #expect(try deliver(Array(data.dropFirst(48)) + frame.initialParityDatagrams(), to: &assembler).isEmpty)
        #expect(assembler.missing(frame: 40).map { [$0.block, $0.needed] } == [[1, 2]])
        #expect(assembler.partialFrames == [40])
        let extra = frame.extraParityDatagrams(block: 1, count: 2)
        #expect(try extra.map { try header($0).index } == [58, 59])
        #expect(try extra.map { try header($0).parityCount } == [10, 10])
        let done = try deliver(extra, to: &assembler)
        #expect(done.map(\.payload) == [payload])
        #expect(done.map(\.recoveredShards) == [12])
        #expect(assembler.missing(frame: 40).isEmpty)
        #expect(assembler.partialFrames.isEmpty)
        #expect(try frame.extraParityDatagrams(block: 1, count: 1).map { try header($0).index } == [60])
        #expect(frame.extraParityDatagrams(block: 3, count: 1).isEmpty)
        #expect(frame.extraParityDatagrams(block: 0, count: 0).isEmpty)

        var tiny = outgoing(Data([9]), frame: 41)
        #expect(tiny.extraParityDatagrams(block: 0, count: .max).count == 253)
        #expect(tiny.extraParityDatagrams(block: 0, count: 1).isEmpty)
    }

    @Test func outOfOrderAndDuplicateShardsDecodeOnce() throws {
        var random = FECRandom(seed: 13)
        let payload = random.data(49 * 1156 - 100)
        let frame = outgoing(payload, frame: 3)
        let all = frame.dataDatagrams + frame.initialParityDatagrams()
        let stream = (all + all.shuffled(using: &random).prefix(30)).shuffled(using: &random)
        var assembler = FrameAssembler()
        let done = try deliver(stream, to: &assembler)
        #expect(done.map(\.payload) == [payload])
        #expect(try deliver(all, to: &assembler).isEmpty)
        #expect(assembler.partialFrames.isEmpty)
        #expect(assembler.missing(frame: 3).isEmpty)
    }

    @Test func frameNumbersWrapAround() throws {
        var random = FECRandom(seed: 14)
        let numbers: [UInt32] = [0xFFFF_FFFE, 0xFFFF_FFFF, 0, 1]
        let payloads = numbers.map { _ in random.data(500) }
        let frames = zip(numbers, payloads).map { outgoing($1, frame: $0, shardSize: 100) }
        let interleaved = (0..<5).flatMap { round in frames.map { $0.dataDatagrams[round] } }
        var assembler = FrameAssembler()
        #expect(try deliver(interleaved, to: &assembler).map(\.payload) == payloads)

        var small = FrameAssembler(maxFrames: 2)
        for frame in frames.prefix(3) { #expect(try small.add(frame.dataDatagrams[0]) == nil) }
        #expect(small.partialFrames == [0xFFFF_FFFF, 0])
        #expect(small.missing(frame: 0xFFFF_FFFE).isEmpty)
        #expect(small.missing(frame: 0).map(\.needed) == [4])
        small.drop(framesBefore: 0)
        #expect(small.partialFrames == [0])
        #expect(try small.add(frames[1].dataDatagrams[1]) == nil)
        #expect(small.partialFrames == [0])
        #expect(try small.add(frames[0].dataDatagrams[1]) == nil)
        #expect(try small.add(frames[3].dataDatagrams[0]) == nil)
        #expect(small.partialFrames == [0, 1])
        small.drop(framesBefore: 0xFFFF_FFF0)
        #expect(try deliver(frames[1].dataDatagrams, to: &small).isEmpty)
        #expect(small.partialFrames == [0, 1])
    }

    @Test func theAssemblerKeepsOnlyTheNewestPartialFrames() throws {
        var assembler = FrameAssembler()
        let frames = (100..<110).map { outgoing(Data(repeating: UInt8($0), count: 300), frame: UInt32($0), shardSize: 100) }
        for frame in frames { #expect(try assembler.add(frame.dataDatagrams[0]) == nil) }
        #expect(assembler.partialFrames == Array(102..<110))
        #expect(assembler.missing(frame: 101).isEmpty)
        #expect(try assembler.add(frames[0].dataDatagrams[1]) == nil)
        #expect(assembler.partialFrames == Array(102..<110))
        let done = try deliver(Array(frames[9].dataDatagrams.dropFirst()), to: &assembler)
        #expect(done.map(\.payload) == [Data(repeating: 109, count: 300)])
    }

    @Test func malformedShardsAreRejected() throws {
        let good = VideoShardHeader(
            frame: 1, block: 0, blockCount: 1, index: 0, dataCount: 3, parityCount: 2, flags: 0, generation: 0, frameBytes: 250
        )
        let shard = Data(count: 100)
        var assembler = FrameAssembler()
        var bad = good
        bad.dataCount = 0
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad = good
        bad.block = 1
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad = good
        bad.blockCount = 0
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad = good
        bad.dataCount = 2
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad = good
        bad.frameBytes = 301
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad = good
        bad.parityCount = 254
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        #expect(throws: WireError.self) { try assembler.add(datagram(good, shard: Data())) }
        #expect(throws: WireError.truncated) { try assembler.add(Data(count: 15)) }
        #expect(assembler.partialFrames.isEmpty)

        #expect(try assembler.add(datagram(good, shard: shard)) == nil)
        bad = good
        bad.index = 1
        bad.flags = 1
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad.flags = 0
        bad.generation = 9
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad.generation = 0
        bad.frameBytes = 201
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad.frameBytes = 250
        bad.parityCount = 3
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: shard)) }
        bad.parityCount = 2
        #expect(throws: WireError.self) { try assembler.add(datagram(bad, shard: Data(count: 125))) }
        #expect(assembler.missing(frame: 1).map(\.needed) == [2])
    }
}

@Suite(.serialized)
struct FECBenchmarks {
    private func median(_ runs: Int = 50, _ body: () throws -> Int) rethrows -> (Duration, Int) {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var sink = 0
        for _ in 0..<runs {
            let start = clock.now
            sink &+= try body()
            samples.append(clock.now - start)
        }
        return (samples.sorted()[runs / 2], sink)
    }

    private func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    @Test func a162KBFrameEncodesAndRebuildsInUnderAMillisecond() throws {
        var random = FECRandom(seed: 99)
        let payload = random.data(162 * 1024)
        let shardSize = VideoShards.shardSize(datagramBudget: 1200, overhead: 28)
        let (cut, _) = median {
            OutgoingFrame(
                frame: 1, flags: 0, generation: 0, payload: payload, shardSize: shardSize, parityRatio: 0.2, minimumParity: 2
            ).dataDatagrams.count
        }
        let frame = OutgoingFrame(
            frame: 1, flags: 0, generation: 0, payload: payload, shardSize: shardSize, parityRatio: 0.2, minimumParity: 2
        )
        let (encode, parityCount) = median { frame.initialParityDatagrams().count }
        #expect(parityCount == 50 * 30)

        let code = try ReedSolomon(dataCount: 48)
        let data = (0..<48).map { _ in random.data(shardSize) }
        var shards: [Int: Data] = [:]
        for (row, shard) in code.parity(indices: 0..<10, data: data).enumerated() { shards[48 + row] = shard }
        for column in Array(0..<48).shuffled(using: &random).dropFirst(10) { shards[column] = data[column] }
        #expect(try code.reconstruct(shards, shardSize: shardSize) == data)
        let (rebuild, _) = try median { try code.reconstruct(shards, shardSize: shardSize).count }

        let wire = try frame.dataDatagrams.filter {
            var reader = ByteReader($0)
            let header = try VideoShardHeader(&reader)
            return !(header.block == 0 && header.index % 4 == 0 && header.index < 40)
        } + frame.initialParityDatagrams()
        let (assemble, completed) = try median {
            var assembler = FrameAssembler()
            return try wire.compactMap { try assembler.add($0) }.count
        }
        #expect(completed == 50)

        print(String(
            format: "FEC 162 KB median of 50: cut %.1f us, initial parity %.1f us, rebuild 10 of 48 %.1f us, assemble with 10 lost %.1f us",
            microseconds(cut), microseconds(encode), microseconds(rebuild), microseconds(assemble)
        ))
        #if !DEBUG
        #expect(encode < .milliseconds(1))
        #expect(rebuild < .milliseconds(1))
        #endif
    }
}
