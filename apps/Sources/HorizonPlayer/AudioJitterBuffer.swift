import Foundation
import HorizonLink

public struct AudioStats: Sendable, Equatable {
    public var packets: UInt64 = 0
    public var levelMs: Double = 0
    public var targetMs: Double = 0
    public var playing = false
    public var running = false
    public var underruns: UInt64 = 0
    public var stops: UInt64 = 0
    public var overflows: UInt64 = 0
    public var droppedFrames: UInt64 = 0
    public var concealedPackets: UInt64 = 0
    public var lostPackets: UInt64 = 0
    public var latePackets: UInt64 = 0
    public var driftPpm: Double = 0
    public var error: String?

    public init() {}
}

public struct AudioJitterSettings: Sendable, Equatable {
    public var sampleRate: Double = 48000
    public var targetMs: Double = 35
    public var minimumTargetMs: Double = 20
    public var maximumTargetMs: Double = 120
    public var overflowMs: Double = 60
    public var growMs: Double = 5
    public var shrinkMs: Double = 0.5
    public var calmSeconds: Double = 30
    public var concealMs: Double = 20
    public var stopGapMs: Double = 500
    public var levelSeconds: Double = 1
    public var correctionSeconds: Double = 2
    public var integralGain: Double = 0.05
    public var driftSeconds: Double = 20
    public var maximumCorrection: Double = 0.002

    public init(targetMs: Double = 35) {
        self.targetMs = targetMs
    }
}

public struct AudioJitterBuffer: Sendable {
    public let settings: AudioJitterSettings
    public private(set) var stats = AudioStats()
    private var left: [Float]
    private var right: [Float]
    private var head = 0
    private var stored = 0
    private var phase = 0.0
    private var targetFrames: Double
    private var smoothedLevel = 0.0
    private var integral = 0.0
    private var drift = 0.0
    private var lastSequence: UInt32?
    private var pulledFrames: UInt64 = 0
    private var calmFrames = 0.0
    private var starvedAt: UInt64?

    public init(settings: AudioJitterSettings = AudioJitterSettings()) {
        self.settings = settings
        let capacity = Int((settings.maximumTargetMs + settings.overflowMs + settings.concealMs + 100) * settings.sampleRate / 1000)
        left = Array(repeating: 0, count: capacity)
        right = Array(repeating: 0, count: capacity)
        targetFrames = settings.targetMs * settings.sampleRate / 1000
        stats.targetMs = settings.targetMs
    }

    public var levelFrames: Double { Double(stored) - phase }

    public var ratio: Double {
        guard stats.playing else { return 1 }
        let error = (smoothedLevel - targetFrames) / settings.sampleRate
        let correction = error / settings.correctionSeconds + integral
        return 1 + min(max(correction, -settings.maximumCorrection), settings.maximumCorrection)
    }

    public mutating func push(_ samples: Data, sequence: UInt32) {
        samples.withUnsafeBytes { push($0, sequence: sequence) }
    }

    public mutating func push(_ samples: UnsafeRawBufferPointer, sequence: UInt32) {
        let frames = samples.count / 4
        guard frames > 0 else { return }
        if let last = lastSequence {
            guard VideoShards.precedes(last, sequence) else {
                stats.latePackets += 1
                return
            }
            let gap = Int(sequence &- last &- 1)
            if gap > 0 {
                let silent = gap * frames
                if Double(silent) <= settings.concealMs * settings.sampleRate / 1000 {
                    stats.concealedPackets += UInt64(gap)
                    appendSilence(silent)
                } else {
                    stats.lostPackets += UInt64(gap)
                }
            }
        }
        lastSequence = sequence
        stats.packets += 1
        if let starved = starvedAt {
            starvedAt = nil
            if Double(pulledFrames - starved) <= settings.stopGapMs * settings.sampleRate / 1000 {
                stats.underruns += 1
                targetFrames = min(targetFrames + settings.growMs * settings.sampleRate / 1000, settings.maximumTargetMs * settings.sampleRate / 1000)
                calmFrames = 0
            } else {
                stats.stops += 1
            }
        }
        for index in 0..<frames {
            let l = Int16(littleEndian: samples.loadUnaligned(fromByteOffset: index * 4, as: Int16.self))
            let r = Int16(littleEndian: samples.loadUnaligned(fromByteOffset: index * 4 + 2, as: Int16.self))
            append(Float(l) / 32768, Float(r) / 32768)
        }
        let limit = targetFrames + settings.overflowMs * settings.sampleRate / 1000
        if Double(stored) > limit {
            let excess = stored - Int(targetFrames)
            discard(excess)
            stats.overflows += 1
            stats.droppedFrames += UInt64(excess)
            smoothedLevel = levelFrames
        }
        if !stats.playing, levelFrames >= targetFrames {
            stats.playing = true
            smoothedLevel = levelFrames
        }
        publish()
    }

    public mutating func pull(frames: Int, left output: UnsafeMutablePointer<Float>, right outputRight: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        pulledFrames += UInt64(frames)
        guard stats.playing else {
            output.update(repeating: 0, count: frames)
            outputRight.update(repeating: 0, count: frames)
            return
        }
        let step = ratio
        let capacity = left.count
        var written = 0
        while written < frames {
            if stored >= 2 {
                let first = head
                let second = head + 1 == capacity ? 0 : head + 1
                let weight = Float(phase)
                output[written] = left[first] + (left[second] - left[first]) * weight
                outputRight[written] = right[first] + (right[second] - right[first]) * weight
                phase += step
                while phase >= 1, stored > 0 {
                    phase -= 1
                    head = head + 1 == capacity ? 0 : head + 1
                    stored -= 1
                }
                written += 1
            } else {
                if stored == 1 {
                    output[written] = left[head]
                    outputRight[written] = right[head]
                    discard(1)
                    written += 1
                }
                phase = 0
                let rest = frames - written
                if rest > 0 {
                    (output + written).update(repeating: 0, count: rest)
                    (outputRight + written).update(repeating: 0, count: rest)
                }
                stats.playing = false
                starvedAt = pulledFrames
                break
            }
        }
        let seconds = Double(frames) / settings.sampleRate
        smoothedLevel += (levelFrames - smoothedLevel) * min(1, seconds / settings.levelSeconds)
        if stats.playing {
            let error = (smoothedLevel - targetFrames) / settings.sampleRate
            integral = min(max(integral + error * settings.integralGain * seconds, -settings.maximumCorrection), settings.maximumCorrection)
            drift += (-integral * 1_000_000 - drift) * min(1, seconds / settings.driftSeconds)
            calmFrames += Double(frames)
            let minimum = settings.minimumTargetMs * settings.sampleRate / 1000
            if calmFrames >= settings.calmSeconds * settings.sampleRate, targetFrames > minimum {
                targetFrames = max(minimum, targetFrames - settings.shrinkMs * settings.sampleRate / 1000)
                calmFrames = 0
            }
        }
        publish()
    }

    public mutating func pull(frames: Int) -> (left: [Float], right: [Float]) {
        var outputLeft = [Float](repeating: 0, count: frames)
        var outputRight = [Float](repeating: 0, count: frames)
        outputLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outputRight.withUnsafeMutableBufferPointer { rightBuffer in
                guard let leftBase = leftBuffer.baseAddress, let rightBase = rightBuffer.baseAddress else { return }
                pull(frames: frames, left: leftBase, right: rightBase)
            }
        }
        return (outputLeft, outputRight)
    }

    private mutating func append(_ l: Float, _ r: Float) {
        let capacity = left.count
        if stored == capacity { discard(1) }
        let tail = (head + stored) % capacity
        left[tail] = l
        right[tail] = r
        stored += 1
    }

    private mutating func appendSilence(_ frames: Int) {
        for _ in 0..<frames { append(0, 0) }
    }

    private mutating func discard(_ frames: Int) {
        let count = min(frames, stored)
        head = (head + count) % left.count
        stored -= count
        if stored == 0 { phase = 0 }
    }

    private mutating func publish() {
        stats.levelMs = levelFrames * 1000 / settings.sampleRate
        stats.targetMs = targetFrames * 1000 / settings.sampleRate
        stats.driftPpm = drift
    }
}
