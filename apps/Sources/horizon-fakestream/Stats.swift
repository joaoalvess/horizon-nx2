import Foundation
import Synchronization

final class Stats: Sendable {
    enum Warning: Int, CaseIterable {
        case encodeCall
        case encoderFailed
        case parameterSets
        case nalOverrun
        case transfer
        case audioRealtime
    }

    private struct Window {
        var encode: [Double] = []
        var total: [Double] = []
        var frames: UInt64 = 0
        var bytes: UInt64 = 0
        var sync: UInt64 = 0
        var ltr: UInt64 = 0
        var firstNs: UInt64 = 0
        var lastNs: UInt64 = 0
        var secondEncode: [Double] = []
        var secondFrames: UInt64 = 0
        var secondBytes: UInt64 = 0
        var secondSince: UInt64 = 0
    }

    static let windowFrames = 600
    static let secondSamples = 256

    let queueDrops = Atomic<UInt64>(0)
    let ringDrops = Atomic<UInt64>(0)
    let encoderDrops = Atomic<UInt64>(0)
    let failed = Atomic<UInt64>(0)
    let lateTicks = Atomic<UInt64>(0)
    let starved = Atomic<UInt64>(0)
    private let warned = Atomic<Int>(0)
    private let window = Mutex(Window())

    func once(_ warning: Warning) -> Bool {
        let bit = 1 << warning.rawValue
        return warned.bitwiseOr(bit, ordering: .relaxed).oldValue & bit == 0
    }

    func frameEncoded(encodeMs: Double, totalMs: Double, bytes: Int, sync: Bool, ltr: Bool, presentNs: UInt64, doneNs: UInt64) -> String? {
        window.withLock { state -> String? in
            state.frames += 1
            state.bytes += UInt64(bytes)
            if sync { state.sync += 1 }
            if ltr { state.ltr += 1 }
            if state.firstNs == 0 { state.firstNs = presentNs }
            state.lastNs = presentNs
            state.encode.append(encodeMs)
            state.total.append(totalMs)
            if state.encode.count == Self.windowFrames { logWindow(&state) }
            if state.secondEncode.count < Self.secondSamples { state.secondEncode.append(encodeMs) }
            state.secondFrames += 1
            state.secondBytes += UInt64(bytes)
            if state.secondSince == 0 {
                state.secondSince = doneNs
                return nil
            }
            guard doneNs - state.secondSince >= 1_000_000_000 else { return nil }
            let seconds = Double(doneNs - state.secondSince) / 1e9
            let sorted = state.secondEncode.sorted()
            let queue = queueDrops.load(ordering: .relaxed)
            let text = String(
                format: "frames=%llu encode_p50_ms=%.2f encode_p95_ms=%.2f dropped=%llu queue_drops=%llu ring_drops=%llu kbps=%.0f",
                state.secondFrames, Self.percentile(sorted, 50), Self.percentile(sorted, 95), queue, queue,
                ringDrops.load(ordering: .relaxed), Double(state.secondBytes) * 8 / seconds / 1e3
            )
            state.secondEncode.removeAll(keepingCapacity: true)
            state.secondFrames = 0
            state.secondBytes = 0
            state.secondSince = doneNs
            return text
        }
    }

    func resetSecond() {
        window.withLock { $0.secondSince = 0 }
    }

    private func logWindow(_ state: inout Window) {
        let encode = state.encode.sorted()
        let total = state.total.sorted()
        let seconds = Double(state.lastNs - state.firstNs) / 1e9
        let mbps = seconds > 0 ? Double(state.bytes) * 8 / seconds / 1e6 : 0
        Log.info(String(
            format: "frames %llu: encode p50 %.2f ms / p95 %.2f / max %.2f; present to encoded p50 %.2f ms / p95 %.2f / max %.2f; "
                + "%.1f Mbit/s; sync frames %llu, LTR frames %llu; dropped: ring full %llu, by the encoder %llu; failed %llu; "
                + "late frame ticks %llu, no decoded picture ready %llu; dropped from the socket queue %llu",
            state.frames, Self.percentile(encode, 50), Self.percentile(encode, 95), encode.last ?? 0,
            Self.percentile(total, 50), Self.percentile(total, 95), total.last ?? 0, mbps, state.sync, state.ltr,
            ringDrops.load(ordering: .relaxed), encoderDrops.load(ordering: .relaxed), failed.load(ordering: .relaxed),
            lateTicks.load(ordering: .relaxed), starved.load(ordering: .relaxed), queueDrops.load(ordering: .relaxed)
        ))
        state.encode.removeAll(keepingCapacity: true)
        state.total.removeAll(keepingCapacity: true)
        state.bytes = 0
        state.firstNs = 0
    }

    private static func percentile(_ sorted: [Double], _ percent: Int) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, sorted.count * percent / 100)]
    }
}
