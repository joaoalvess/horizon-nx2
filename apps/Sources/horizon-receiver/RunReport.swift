import Foundation
import HorizonLink
import HorizonPlayer

enum Console {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

func decimal(_ value: Double?, _ digits: Int = 1) -> String {
    guard let value else { return "-" }
    guard value.isFinite else { return "∞" }
    return String(format: "%.\(digits)f", value)
}

func percent(_ fraction: Double?) -> String {
    guard let fraction else { return "-" }
    return decimal(fraction * 100, fraction < 0.001 && fraction > 0 ? 3 : 2) + "%"
}

func count(_ value: UInt64) -> String {
    let digits = Array(String(value))
    var text = ""
    for (index, digit) in digits.enumerated() {
        if index > 0, (digits.count - index) % 3 == 0 { text += "," }
        text.append(digit)
    }
    return text
}

func latencyText(_ histogram: LatencyHistogram, limitMs: Double) -> String {
    guard !histogram.isEmpty else { return "no samples" }
    return "p50 \(decimal(histogram.p50)) · p95 \(decimal(histogram.p95)) · p99 \(decimal(histogram.p99)) · max \(decimal(histogram.maxMs)) ms;"
        + " above \(decimal(limitMs, 0)) ms: \(percent(histogram.fraction(above: limitMs)))"
}

struct RunTotals {
    var connections = 0
    var presentToDecoded = LatencyHistogram()
    var presentToDisplayed = LatencyHistogram()
    var decodeTime = LatencyHistogram()
    var received: UInt64 = 0
    var decoded: UInt64 = 0
    var displayed: UInt64 = 0
    var replaced: UInt64 = 0
    var missing: UInt64 = 0
    var skipped: UInt64 = 0
    var late: UInt64 = 0
    var withoutClock: UInt64 = 0
    var decodeErrors: UInt64 = 0
    var refreshRequests: UInt64 = 0
    var delayedOutputs: UInt64 = 0
    var longestMissingRun: UInt64 = 0
    var receivedShards: UInt64 = 0
    var recoveredShards: UInt64 = 0
    var invalidShards: UInt64 = 0
    var nacks: UInt64 = 0
    var lostFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var refreshes: UInt64 = 0
    var droppedBySimulation: UInt64 = 0
    var openFailures: UInt64 = 0
    var audioPackets: UInt64 = 0
    var underruns: UInt64 = 0
    var stops: UInt64 = 0
    var overflows: UInt64 = 0
    var concealed: UInt64 = 0
    var audioLost: UInt64 = 0
    var audioLate: UInt64 = 0
    var minimumRoundTripNs: Int64?
    var lastAudio: AudioStats?

    mutating func add(_ stats: PlayerStats) {
        connections += 1
        presentToDecoded = presentToDecoded + stats.presentToDecoded
        presentToDisplayed = presentToDisplayed + stats.presentToDisplayed
        decodeTime = decodeTime + stats.decodeTime
        received += stats.received
        decoded += stats.decoded
        displayed += stats.displayed
        replaced += stats.replaced
        missing += stats.missing
        skipped += stats.skipped
        late += stats.late
        withoutClock += stats.withoutClock
        decodeErrors += stats.decodeErrors
        refreshRequests += stats.refreshRequests
        delayedOutputs += stats.delayedOutputs
        longestMissingRun = max(longestMissingRun, stats.longestMissingRun)
        if let link = stats.link {
            receivedShards += UInt64(link.video.receivedShards)
            recoveredShards += UInt64(link.video.recoveredShards)
            invalidShards += UInt64(link.video.invalidShards)
            nacks += UInt64(link.video.nacks)
            lostFrames += UInt64(link.video.lostFrames)
            droppedFrames += UInt64(link.video.droppedFrames)
            refreshes += UInt64(link.video.refreshes)
            droppedBySimulation += link.droppedBySimulation
            openFailures += link.openFailures
            audioPackets += link.audioPackets
            if let rtt = link.roundTripNs { minimumRoundTripNs = min(minimumRoundTripNs ?? rtt, rtt) }
        }
        underruns += stats.audio.underruns
        stops += stats.audio.stops
        overflows += stats.audio.overflows
        concealed += stats.audio.concealedPackets
        audioLost += stats.audio.lostPackets
        audioLate += stats.audio.latePackets
        lastAudio = stats.audio
    }

    func summary(seconds: Double, hub: String, limitMs: Double, window: Bool) -> [String] {
        let undecodedShare = presentToDecoded.count == 0 ? nil : Double(missing) / Double(presentToDecoded.count)
        var lines = [
            "Summary of the whole run: \(decimal(seconds, 0)) s, \(connections) \(connections == 1 ? "connection" : "connections"), hub \(hub)",
            "  frames: \(count(decoded)) decoded, \(count(missing)) never decoded (\(percent(undecodedShare))),"
                + " longest run without decoding: \(count(longestMissingRun)) \(longestMissingRun == 1 ? "frame" : "frames")",
            "  presented → decoded: \(latencyText(presentToDecoded, limitMs: limitMs)) (undecoded frames count as above)",
        ]
        if withoutClock > 0 { lines.append("  \(count(withoutClock)) frames decoded before the first clock sync were left out of the latency") }
        if window {
            lines.append("  presented → displayed (estimated from vsync): \(latencyText(presentToDisplayed, limitMs: limitMs)); displayed \(count(displayed)), replaced before vsync \(count(replaced))")
        }
        lines.append(
            "  decode: p50 \(decimal(decodeTime.p50, 2)) · p95 \(decimal(decodeTime.p95, 2)) ms; errors \(count(decodeErrors)), skipped \(count(skipped)),"
                + " out of order \(count(late)), refresh requests \(count(refreshRequests)), delayed outputs \(count(delayedOutputs))"
        )
        lines.append(
            "  network: shards \(count(receivedShards)), recovered \(count(recoveredShards)), invalid \(count(invalidShards)), NACK \(count(nacks)),"
                + " lost frames \(count(lostFrames)), dropped waiting for refresh \(count(droppedFrames)), refresh \(count(refreshes)),"
                + " simulated loss \(count(droppedBySimulation)) datagrams, open failures \(count(openFailures))"
        )
        lines.append("  minimum RTT: \(minimumRoundTripNs.map { decimal(Double($0) / 1e6, 2) + " ms" } ?? "-")")
        let audio = lastAudio.map { " drift \(decimal($0.driftPpm, 0)) ppm, buffer \(decimal($0.levelMs, 0)) ms (target \(decimal($0.targetMs, 0)) ms)" } ?? ""
        lines.append(
            "  audio: packets \(count(audioPackets)), underruns \(count(underruns)), stops \(count(stops)), overflows \(count(overflows)),"
                + " concealed \(count(concealed)), lost \(count(audioLost)), late \(count(audioLate));\(audio)"
        )
        return lines
    }
}

struct StatusLine {
    static func text(elapsed: Double, current: PlayerStats, previous: PlayerStats?, seconds: Double, limitMs: Double) -> String {
        func delta(_ path: KeyPath<PlayerStats, UInt64>) -> UInt64 {
            let now = current[keyPath: path]
            let before = previous?[keyPath: path] ?? 0
            return now >= before ? now - before : now
        }
        func linkDelta(_ path: KeyPath<VideoReceiverStats, UInt32>) -> UInt64 {
            guard let now = current.link?.video[keyPath: path] else { return 0 }
            let before = previous?.link?.video[keyPath: path] ?? 0
            return UInt64(now >= before ? now - before : now)
        }
        let decoded = delta(\.decoded)
        let fps = seconds > 0 ? Double(decoded) / seconds : 0
        let latency = previous.map { current.presentToDecoded - $0.presentToDecoded } ?? current.presentToDecoded
        let decode = previous.map { current.decodeTime - $0.decodeTime } ?? current.decodeTime
        let underruns = current.audio.underruns - min(current.audio.underruns, previous?.audio.underruns ?? 0)
        var parts = [
            "[\(String(format: "%5.0f", elapsed)) s] \(decimal(fps)) fps",
            "network: lost \(linkDelta(\.lostFrames)), dropped \(linkDelta(\.droppedFrames)), NACK \(linkDelta(\.nacks)),"
                + " recovered \(linkDelta(\.recoveredShards)), refresh \(linkDelta(\.refreshes))",
            "RTT \(current.link?.roundTripNs.map { decimal(Double($0) / 1e6) } ?? "-") ms",
            latency.isEmpty
                ? "latency: no samples"
                : "latency p50 \(decimal(latency.p50)) · p95 \(decimal(latency.p95)) · p99 \(decimal(latency.p99)) ms"
                    + " (above \(decimal(limitMs, 0)) ms: \(percent(latency.fraction(above: limitMs))))",
            "decode p95 \(decimal(decode.p95, 2)) ms",
            current.audio.running || current.audio.packets > 0
                ? "audio \(decimal(current.audio.levelMs, 0)) ms, underruns \(underruns)"
                : "audio off",
        ]
        let errors = delta(\.decodeErrors)
        let skipped = delta(\.skipped)
        if errors > 0 || skipped > 0 { parts.append("decode: \(errors) errors, \(skipped) skipped") }
        if current.waitingForKeyFrame, current.received > 0 { parts.append("waiting for a key frame") }
        return parts.joined(separator: " · ")
    }
}
