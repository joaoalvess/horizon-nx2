import Foundation
import Testing
@testable import HorizonLink

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

struct MediaRun {
    struct Arrival {
        let at: UInt64
        let datagram: Data
    }

    var sender = VideoSender()
    var receiver = VideoReceiver()
    var random = SeededRandom(state: 7)
    var oneWayNs: UInt64 = 3_000_000
    var spacingNs: UInt64 = 20_000
    var frameIntervalNs: UInt64 = 16_666_667
    var lose: (inout SeededRandom, Int) -> Bool = { _, _ in false }
    var delivered: [ReceivedVideo] = []
    var nacks = 0
    var refreshes = 0
    private var queue: [Arrival] = []
    private var sentDatagrams = 0
    private var refreshPending = false
    private var dmFrame: UInt64 = 0

    mutating func send(_ datagrams: [Data], at start: UInt64) {
        for (index, datagram) in datagrams.enumerated() {
            let lost = lose(&random, sentDatagrams)
            sentDatagrams += 1
            if lost { continue }
            queue.append(Arrival(at: start + oneWayNs + UInt64(index) * spacingNs, datagram: datagram))
        }
        queue.sort { $0.at < $1.at }
    }

    mutating func handle(_ outputs: [VideoReceiver.Output], at now: UInt64) {
        for output in outputs {
            switch output {
            case .deliver(let video): delivered.append(video)
            case .nack(let nack):
                nacks += 1
                send(sender.repair(nack), at: now + oneWayNs)
            case .refresh:
                refreshes += 1
                sender.resendConfiguration()
                refreshPending = true
            }
        }
    }

    mutating func frame(size: Int, sync: Bool = false) -> DMStream.VideoFrame {
        dmFrame += 1
        var flags: DMStream.FrameFlags = []
        if sync { flags.insert(.sync) }
        if refreshPending, !sync {
            flags.insert(.refresh)
            refreshPending = false
        }
        let body = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &random) })
        return DMStream.VideoFrame(presentNs: dmFrame, frameNumber: dmFrame, flags: flags, accessUnit: body)
    }

    mutating func run(frames: Int, sizes: (Int) -> Int, syncAt: Set<Int> = [0], configure: [Int: [Data]] = [:], feedFrom: Int = 0) {
        var now: UInt64 = 1_000_000_000
        let end = now + UInt64(frames + 6) * frameIntervalNs
        var nextFrameAt = now
        var produced = 0
        if configure[0] == nil { sender.configure([Data([0x67, 1]), Data([0x68, 1])]) }
        while now < end {
            if produced < frames, now >= nextFrameAt {
                if let sets = configure[produced] { sender.configure(sets) }
                let packet = sender.packetize(frame(size: sizes(produced), sync: syncAt.contains(produced)))
                if produced >= feedFrom { send(packet.data + packet.parity, at: now) }
                produced += 1
                nextFrameAt += frameIntervalNs
            }
            while let first = queue.first, first.at <= now {
                queue.removeFirst()
                handle(receiver.receive(first.datagram, now: first.at), at: first.at)
            }
            handle(receiver.tick(now: now), at: now)
            now += 500_000
        }
    }
}

struct MediaPlaneTests {
    @Test func aCleanLinkDeliversEveryFrameInOrder() {
        var run = MediaRun()
        run.run(frames: 120, sizes: { $0 == 0 ? 320_000 : 20_000 + ($0 % 7) * 9_000 })
        #expect(run.delivered.count == 120)
        #expect(run.delivered.map(\.envelope.frameNumber) == Array(1...120))
        #expect(run.nacks == 0)
        #expect(run.refreshes == 0)
        #expect(run.delivered.first?.parameterSets == [Data([0x67, 1]), Data([0x68, 1])])
        #expect(run.delivered.first?.isSync == true)
    }

    @Test func randomLossIsRepairedWithoutARefresh() {
        var run = MediaRun()
        run.lose = { random, _ in Double.random(in: 0..<1, using: &random) < 0.03 }
        run.run(frames: 300, sizes: { $0 == 0 ? 320_000 : 47_000 + ($0 % 11) * 4_000 })
        #expect(run.delivered.count == 300)
        #expect(run.delivered.map(\.envelope.frameNumber) == Array(1...300))
        #expect(run.refreshes == 0)
        #expect(run.receiver.stats.recoveredShards > 0)
    }

    @Test func aWholeLostFrameIsAskedForAgain() {
        var sender = VideoSender()
        sender.configure([Data([1])])
        var receiver = VideoReceiver()
        let first = sender.packetize(DMStream.VideoFrame(presentNs: 1, frameNumber: 1, flags: [.sync], accessUnit: Data(count: 30_000)))
        let lost = sender.packetize(DMStream.VideoFrame(presentNs: 2, frameNumber: 2, accessUnit: Data(repeating: 2, count: 30_000)))
        let third = sender.packetize(DMStream.VideoFrame(presentNs: 3, frameNumber: 3, accessUnit: Data(repeating: 3, count: 30_000)))
        var outputs: [VideoReceiver.Output] = []
        for datagram in first.data + first.parity { outputs += receiver.receive(datagram, now: 1_000) }
        for datagram in third.data { outputs += receiver.receive(datagram, now: 2_000) }
        let nack = outputs.compactMap { if case .nack(let nack) = $0 { nack } else { nil } }
        #expect(nack == [NackPacket(frame: lost.frame, needs: [])])
        for datagram in sender.repair(NackPacket(frame: lost.frame, needs: [])) { outputs += receiver.receive(datagram, now: 3_000) }
        let frames = outputs.compactMap { if case .deliver(let video) = $0 { video.envelope.frameNumber } else { nil } }
        #expect(frames == [1, 2, 3])
    }

    @Test func aLossBurstAsksForARefreshAndResumesAtIt() {
        var run = MediaRun()
        run.lose = { _, index in index >= 400 && index < 520 }
        run.run(frames: 120, sizes: { $0 == 0 ? 120_000 : 30_000 })
        #expect(run.refreshes >= 1)
        let numbers = run.delivered.map(\.envelope.frameNumber)
        #expect(numbers == numbers.sorted())
        #expect(run.receiver.stats.lostFrames > 0)
        let resumed = run.delivered.first { frame in
            frame.envelope.frameNumber > 1 && !numbers.contains(frame.envelope.frameNumber - 1)
        }
        #expect(resumed?.isRefresh == true)
        #expect((numbers.last ?? 0) >= 118)
    }

    @Test func aNewConfigurationTravelsWithItsSyncFrame() {
        var run = MediaRun()
        let second = [Data([0x67, 2]), Data([0x68, 2])]
        run.run(frames: 60, sizes: { _ in 25_000 }, syncAt: [0, 30], configure: [30: second])
        #expect(run.delivered.count == 60)
        #expect(run.delivered[29].parameterSets == [Data([0x67, 1]), Data([0x68, 1])])
        #expect(run.delivered[30].parameterSets == second)
        #expect(run.delivered[31].parameterSets == second)
        #expect(run.delivered[30].generation == run.delivered[29].generation &+ 1)
    }

    @Test func joiningMidStreamWaitsForARefresh() {
        var run = MediaRun()
        run.run(frames: 60, sizes: { _ in 25_000 }, feedFrom: 10)
        #expect(run.refreshes >= 1)
        #expect(run.delivered.first?.isRefresh == true)
        #expect(run.delivered.first?.parameterSets == [Data([0x67, 1]), Data([0x68, 1])])
        #expect(run.receiver.stats.droppedFrames > 0)
    }

    @Test func garbageShardsAreCountedAndIgnored() {
        var receiver = VideoReceiver()
        var random = SeededRandom(state: 3)
        for _ in 0..<2000 {
            let data = Data((0..<Int.random(in: 0..<80, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) })
            _ = receiver.receive(data, now: 1)
        }
        _ = receiver.tick(now: 1_000_000_000)
        #expect(receiver.stats.deliveredFrames == 0)
    }
}
