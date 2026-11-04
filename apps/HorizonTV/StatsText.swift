import Foundation
import HorizonPlayer

enum StatsText {
    static func describe(_ stats: PlayerStats) -> String {
        var lines = [
            String(format: "%dx%d  %.0f fps", stats.width, stats.height, stats.fps),
            "present → display  p50 \(ms(stats.presentToDisplayed.p50))  p95 \(ms(stats.presentToDisplayed.p95))",
            "present → decoded  p95 \(ms(stats.presentToDecoded.p95))  decode p95 \(ms(stats.decodeTime.p95))",
        ]
        if let link = stats.link {
            var network = "lost \(link.video.lostFrames)  repaired \(link.video.recoveredShards)  refresh \(stats.refreshRequests)"
            if let rtt = link.roundTripNs { network += String(format: "  RTT %.1f ms", Double(rtt) / 1e6) }
            lines.append(network)
        }
        lines.append(String(format: "audio %.0f ms  underruns %llu", stats.audio.levelMs, stats.audio.underruns))
        return lines.joined(separator: "\n")
    }

    private static func ms(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }
}
