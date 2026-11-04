import Foundation
import Testing
@testable import HorizonPlayer

func packet(_ value: Int16 = 8192, frames: Int = 240) -> Data {
    var data = Data(capacity: frames * 4)
    for _ in 0..<frames * 2 {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

struct AudioJitterBufferTests {
    @Test func waitsForTheTargetBeforePlaying() {
        var buffer = AudioJitterBuffer()
        for sequence in 1...6 { buffer.push(packet(), sequence: UInt32(sequence)) }
        let early = buffer.pull(frames: 240)
        #expect(early.left.allSatisfy { $0 == 0 })
        #expect(buffer.stats.playing == false)
        for sequence in 7...8 { buffer.push(packet(), sequence: UInt32(sequence)) }
        #expect(buffer.stats.playing)
        let played = buffer.pull(frames: 240)
        #expect(played.left.allSatisfy { abs($0 - 0.25) < 1e-4 })
        #expect(played.right.allSatisfy { abs($0 - 0.25) < 1e-4 })
        #expect(buffer.stats.underruns == 0)
    }

    @Test func anUnderrunPlaysSilenceAndRaisesTheTarget() {
        var buffer = AudioJitterBuffer()
        for sequence in 1...8 { buffer.push(packet(), sequence: UInt32(sequence)) }
        _ = buffer.pull(frames: 1440)
        let starved = buffer.pull(frames: 960)
        #expect(starved.left.suffix(400).allSatisfy { $0 == 0 })
        #expect(buffer.stats.playing == false)
        buffer.push(packet(), sequence: 9)
        #expect(buffer.stats.underruns == 1)
        #expect(abs(buffer.stats.targetMs - 40) < 0.01)
        #expect(buffer.stats.playing == false)
    }

    @Test func aStreamThatStopsIsNotAnUnderrun() {
        var buffer = AudioJitterBuffer()
        for sequence in 1...8 { buffer.push(packet(), sequence: UInt32(sequence)) }
        for _ in 0..<100 { _ = buffer.pull(frames: 480) }
        buffer.push(packet(), sequence: 9)
        #expect(buffer.stats.underruns == 0)
        #expect(buffer.stats.stops == 1)
        #expect(abs(buffer.stats.targetMs - 35) < 0.01)
    }

    @Test func anOverflowDropsBackToTheTarget() {
        var buffer = AudioJitterBuffer()
        for sequence in 1...60 { buffer.push(packet(), sequence: UInt32(sequence)) }
        #expect(buffer.stats.overflows >= 1)
        #expect(buffer.stats.droppedFrames > 0)
        #expect(buffer.stats.levelMs <= 35 + 60 + 0.01)
        #expect(buffer.stats.levelMs >= 35)
    }

    @Test func aLostPacketBecomesSilenceAndALateOneIsDropped() {
        var buffer = AudioJitterBuffer()
        for sequence: UInt32 in [1, 2, 3, 5] { buffer.push(packet(), sequence: sequence) }
        #expect(buffer.stats.concealedPackets == 1)
        #expect(abs(buffer.stats.levelMs - 25) < 0.01)
        buffer.push(packet(), sequence: 4)
        #expect(buffer.stats.latePackets == 1)
        #expect(abs(buffer.stats.levelMs - 25) < 0.01)
        buffer.push(packet(), sequence: 100)
        #expect(buffer.stats.lostPackets == 94)
    }

    @Test(arguments: [500.0, -500.0])
    func followsAnOutputClockThatDrifts(ppm: Double) {
        var buffer = AudioJitterBuffer()
        let consumerRatio = 1 + ppm / 1_000_000
        let pullInterval = 0.010 / consumerRatio
        var nextPush = 0.0
        var nextPull = 0.040
        var sequence: UInt32 = 0
        while nextPull < 120 {
            if nextPush <= nextPull {
                sequence &+= 1
                buffer.push(packet(), sequence: sequence)
                nextPush += 0.005
            } else {
                _ = buffer.pull(frames: 480)
                nextPull += pullInterval
            }
        }
        let stats = buffer.stats
        #expect(stats.underruns == 0)
        #expect(stats.overflows == 0)
        #expect(stats.playing)
        #expect(abs(stats.levelMs - stats.targetMs) < 10)
        #expect(abs(stats.driftPpm - ppm) < 100)
    }
}
