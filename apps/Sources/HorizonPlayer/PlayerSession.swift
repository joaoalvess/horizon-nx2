import AVFoundation
import CoreVideo
import Foundation
import HorizonLink
import VideoToolbox

public final class PlayerSession: @unchecked Sendable {
    private struct PendingRow {
        var row: FrameRow
        let enqueuedNs: UInt64
    }

    public let settings: PlayerSettings
    public let tsvError: String?
    private let link: any PlayerLink
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.player.decode", qos: .userInteractive)
    private let decoder = VideoDecoder()
    private let output: AudioOutput?
    private let log: FrameLog?
    private let lock = NSLock()
    private var counters = PlayerStats()
    private var renderer: FrameRenderer?
    private var vsyncActive = false
    private var pending: [PendingRow] = []
    private var recent: [UInt64] = []
    private var latest: DecodedFrame?
    private var audioPackets: UInt64 = 0
    private var stopped = false
    private var lastFrame: UInt32?
    private var waitingForKey = true
    private var missingRun: UInt64 = 0

    public convenience init(client: LinkClient, settings: PlayerSettings = PlayerSettings()) {
        self.init(link: client, settings: settings)
    }

    init(link: any PlayerLink, settings: PlayerSettings) {
        self.link = link
        self.settings = settings
        if let path = settings.tsvPath {
            do {
                log = try FrameLog(path: path)
                tsvError = nil
            } catch {
                log = nil
                tsvError = "could not create the TSV at \(path): \(error.localizedDescription)"
            }
        } else {
            log = nil
            tsvError = nil
        }
        queue.async { VideoDecoder.warmUpOnce() }
        if settings.audio {
            let output = AudioOutput(settings: AudioJitterSettings(targetMs: settings.audioTargetMs))
            output.start()
            self.output = output
        } else {
            output = nil
        }
    }

    deinit {
        guard !stopped else { return }
        output?.stop()
        pending.forEach { log?.write($0.row) }
        log?.close()
    }

    public func video(_ video: ReceivedVideo) {
        guard !lock.withLock({ stopped }) else { return }
        queue.async { [self] in process(video) }
    }

    public func audio(_ packet: AudioPacket, receivedNs: UInt64) {
        guard !lock.withLock({ stopped }) else { return }
        if let output {
            output.push(packet)
        } else {
            lock.withLock { audioPackets += 1 }
        }
    }

    public var stats: PlayerStats {
        var stats = lock.withLock { () -> PlayerStats in
            let now = LinkClock.nowNs()
            recent.removeAll { now &- $0 > 1_000_000_000 }
            var stats = counters
            stats.fps = Double(recent.count)
            stats.presentToDecoded.missing = stats.missing
            stats.audio.packets = audioPackets
            return stats
        }
        stats.link = link.linkStats
        if let output { stats.audio = output.stats }
        return stats
    }

    public func snapshot() -> PlayerSnapshot? {
        guard let frame = lock.withLock({ latest }) else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(frame.image, options: nil, imageOut: &image) == noErr, let image else { return nil }
        return PlayerSnapshot(frame: frame.video.frame, dmFrame: frame.video.envelope.frameNumber, image: image)
    }

    public func stop() {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard first else { return }
        output?.stop()
        queue.sync { decoder.invalidate() }
        let rows = lock.withLock { () -> [FrameRow] in
            let rows = pending.map(\.row)
            pending = []
            return rows
        }
        rows.forEach { log?.write($0) }
        log?.close()
    }

    func waitUntilIdle() {
        queue.sync {}
    }

    func attach(_ renderer: AVSampleBufferVideoRenderer) {
        lock.withLock { self.renderer = FrameRenderer(renderer) }
    }

    func detach(_ renderer: AVSampleBufferVideoRenderer) {
        lock.withLock {
            if self.renderer?.renderer === renderer { self.renderer = nil }
        }
    }

    func setVsyncActive(_ active: Bool) {
        let rows = lock.withLock { () -> [FrameRow] in
            vsyncActive = active
            guard !active else { return [] }
            let rows = pending.map(\.row)
            pending = []
            return rows
        }
        rows.forEach { log?.write($0) }
    }

    func vsync(targetNs: UInt64) {
        let now = LinkClock.nowNs()
        let rows = lock.withLock { () -> [FrameRow] in
            let ready = pending.prefix { $0.enqueuedNs <= now }.count
            var rows: [FrameRow] = []
            for index in 0..<ready {
                var row = pending[index].row
                if index == ready - 1 {
                    row.displayedNs = targetNs
                    counters.displayed += 1
                    if let ms = row.latency(to: targetNs) { counters.presentToDisplayed.add(ms) }
                } else {
                    counters.replaced += 1
                }
                rows.append(row)
            }
            pending.removeFirst(ready)
            return rows + expire(now)
        }
        rows.forEach { log?.write($0) }
    }

    private func expire(_ now: UInt64) -> [FrameRow] {
        let limit = UInt64(settings.displayTimeoutMs * 1_000_000)
        let old = pending.prefix { now &- $0.enqueuedNs > limit }.count
        guard old > 0 else { return [] }
        let rows = pending.prefix(old).map(\.row)
        pending.removeFirst(old)
        return rows
    }

    private func process(_ video: ReceivedVideo) {
        guard !lock.withLock({ stopped }) else { return }
        var row = FrameRow(
            link: video.frame, dmFrame: video.envelope.frameNumber, flags: video.flags, bytes: video.envelope.accessUnit.count,
            presentNs: video.envelope.presentNs, firstShardNs: video.firstShardNs, completedNs: video.completedNs,
            offsetNs: link.clientTime(hubNs: video.envelope.presentNs).map { Int64(bitPattern: video.envelope.presentNs &- $0) },
            status: .decoded
        )
        var gap: UInt64 = 0
        if let last = lastFrame {
            guard VideoShards.precedes(last, video.frame) else {
                row.status = .late
                lock.withLock {
                    counters.received += 1
                    counters.late += 1
                }
                log?.write(row)
                return
            }
            gap = UInt64(video.frame &- last &- 1)
        }
        lastFrame = video.frame
        let key = video.isSync || video.isRefresh
        var refresh = false
        if gap > 0, !key, !waitingForKey {
            waitingForKey = true
            refresh = true
        }
        let decodable = !waitingForKey || (key && (video.isSync || !decoder.needsSyncFrame))
        guard decodable else {
            if refresh { link.requestRefresh() }
            row.status = .skipped
            account(row, gap: gap, refreshed: refresh, frame: nil, error: nil, enqueuedNs: nil)
            return
        }
        waitingForKey = false
        switch decoder.decode(video) {
        case .decoded(let frame):
            link.decoded(frame: video.frame, ltrToken: video.envelope.ltrToken, at: frame.endNs, decodeMicroseconds: frame.decodeMicroseconds)
            let renderer = lock.withLock { self.renderer }
            var enqueuedNs: UInt64?
            if let renderer, renderer.show(frame.image, presentNs: video.envelope.presentNs) { enqueuedNs = LinkClock.nowNs() }
            row.decodeStartNs = frame.startNs
            row.decodeEndNs = frame.endNs
            account(row, gap: gap, refreshed: refresh, frame: frame, error: nil, enqueuedNs: enqueuedNs)
        case .failed(let error, let start, let end):
            waitingForKey = true
            link.requestRefresh()
            row.decodeStartNs = start
            row.decodeEndNs = end
            row.status = .error
            account(row, gap: gap, refreshed: true, frame: nil, error: error, enqueuedNs: nil)
        }
    }

    private func account(_ row: FrameRow, gap: UInt64, refreshed: Bool, frame: DecodedFrame?, error: DecodeError?, enqueuedNs: UInt64?) {
        let now = LinkClock.nowNs()
        missingRun += gap
        if frame == nil { missingRun += 1 }
        let run = missingRun
        if frame != nil { missingRun = 0 }
        let waiting = waitingForKey
        let sessions = decoder.sessionsCreated
        let needsSync = decoder.needsSyncFrame
        let rows = lock.withLock { () -> [FrameRow] in
            counters.received += 1
            counters.missing += gap
            counters.longestMissingRun = max(counters.longestMissingRun, run)
            counters.sessionsCreated = sessions
            if refreshed { counters.refreshRequests += 1 }
            if let frame {
                counters.decoded += 1
                counters.lastDecodedNs = frame.endNs
                counters.waitingSinceNs = nil
                counters.width = frame.width
                counters.height = frame.height
                if frame.delayed { counters.delayedOutputs += 1 }
                if let ms = row.latency(to: frame.endNs) {
                    counters.presentToDecoded.add(ms)
                } else {
                    counters.withoutClock += 1
                }
                counters.decodeTime.add(Double(frame.endNs &- frame.startNs) / 1e6)
                recent.append(frame.endNs)
                if recent.count > 480 { recent.removeFirst(recent.count - 480) }
                latest = frame
            } else {
                counters.missing += 1
                if row.status == .skipped { counters.skipped += 1 }
                if let error {
                    counters.decodeErrors += 1
                    counters.lastError = error
                }
                if counters.waitingSinceNs == nil { counters.waitingSinceNs = now }
            }
            counters.waitingForKeyFrame = waiting
            counters.needsSyncFrame = needsSync
            var rows = expire(now)
            if let enqueuedNs, vsyncActive {
                pending.append(PendingRow(row: row, enqueuedNs: enqueuedNs))
            } else {
                rows.append(row)
            }
            return rows
        }
        rows.forEach { log?.write($0) }
    }
}
