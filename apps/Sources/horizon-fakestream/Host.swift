import Darwin
import Foundation
import HorizonLink
import Synchronization

final class Host: @unchecked Sendable {
    static let audioFrames = 240
    static let audioBlockNs: UInt64 = 5_000_000

    private let settings: Settings
    private let width: Int
    private let height: Int
    private let queue: SendQueue
    private let stats: Stats
    private let control = DispatchQueue(label: "fakestream.control", qos: .userInteractive)
    private let lock = NSLock()
    private var encoder: Encoder?
    private var attached = false
    private var paused = false
    private var generation: UInt32 = 0
    private var padTimer: DispatchSourceTimer?
    private var loggedPads: (pad: UInt64, pads: UInt64, mask: UInt32) = (0, 0, 0)
    private let sending = Atomic<Bool>(false)
    private let hubHello = Atomic<Bool>(false)
    private let refusedFlag = Atomic<Bool>(false)
    private let frameNumber = Atomic<UInt64>(0)
    private let audioGeneration = Atomic<UInt64>(0)
    private let padMessages = Atomic<UInt64>(0)
    private let padsMessages = Atomic<UInt64>(0)
    private let padsMask = Atomic<UInt32>(0)
    private let pauses = Atomic<UInt64>(0)

    init(settings: Settings, width: Int, height: Int, queue: SendQueue, stats: Stats) {
        self.settings = settings
        self.width = width
        self.height = height
        self.queue = queue
        self.stats = stats
        control.async { [self] in startPadSummary() }
    }

    var refused: Bool { refusedFlag.load(ordering: .acquiring) }

    func refuse() { refusedFlag.store(true, ordering: .releasing) }

    func currentEncoder() -> Encoder? { lock.withLock { encoder } }

    func nextFrameNumber() -> UInt64 { frameNumber.add(1, ordering: .relaxed).oldValue }

    func helloMessage() -> Data {
        DMStream.encode(.hostHello(DMStream.HostHello(
            titleId: settings.titleId, width: UInt16(clamping: width), height: UInt16(clamping: height),
            codecs: [DMStream.Codec.avc1.rawValue], build: settings.build
        )), sentNs: 0)
    }

    func connected() {
        hubHello.store(false, ordering: .releasing)
    }

    func linkClosed() {
        queue.linkDown()
        detach(pause: true, why: "the hub's socket closed while a client was attached")
        if refused { detach(pause: false, why: "the hub was refused") }
    }

    func undecodable(type: UInt16, length: UInt32) -> Bool {
        switch DMStream.Kind(rawValue: type) {
        case .hello:
            Log.red("the hub's HELLO is \(length) bytes, too short for a version: closing, not connecting again")
            refuse()
            return false
        case .attach:
            Log.red("a short ATTACH from the hub (\(length) bytes), ignored")
            sendAttachResult(ok: false, width: 0, height: 0, codec: 0, reason: "a short ATTACH")
        default:
            Log.red("a short message of type \(type) from the hub (\(length) bytes), ignored")
        }
        return true
    }

    func handle(_ message: DMStream.Message) -> Bool {
        switch message {
        case .hubHello(let version):
            guard version == DMStream.version else {
                Log.red("the hub speaks protocol \(version), this host speaks \(DMStream.version): closing, not connecting again")
                refuse()
                return false
            }
            hubHello.store(true, ordering: .releasing)
            Log.info("the hub speaks protocol \(version)")
        case .attach(let attach):
            handleAttach(attach)
        case .detach(let pause):
            detach(pause: pause, why: "the hub detached its client")
        case .pad:
            padMessages.add(1, ordering: .relaxed)
        case .pads(let pads):
            padsMessages.add(1, ordering: .relaxed)
            padsMask.store(pads.mask, ordering: .relaxed)
        case .ltrAck(let tokens):
            control.async { [self] in currentEncoder()?.acknowledge(tokens) }
        case .refresh:
            currentEncoder()?.request(Force.refresh)
        case .bitrate(let kbps):
            guard kbps > 0, kbps <= UInt32(Int32.max) else {
                Log.red("a BITRATE of \(kbps) kbit/s from the hub, ignored")
                return true
            }
            control.async { [self] in currentEncoder()?.setBitrate(Int(kbps)) }
            Log.info("the hub set the bitrate to \(kbps) kbit/s")
        default:
            break
        }
        return true
    }

    private func handleAttach(_ attach: DMStream.Attach) {
        guard hubHello.load(ordering: .acquiring) else {
            Log.red("ATTACH before the hub's HELLO, ignored")
            sendAttachResult(ok: false, width: attach.width, height: attach.height, codec: attach.codec, reason: "ATTACH before the hub's HELLO")
            return
        }
        guard attach.codec == DMStream.Codec.avc1.rawValue else {
            let name = attach.codec == DMStream.Codec.hvc1.rawValue ? "hvc1" : "0x" + String(attach.codec, radix: 16)
            Log.red("ATTACH asks for codec \(name), which HELLO did not list: ignored")
            sendAttachResult(ok: false, width: attach.width, height: attach.height, codec: attach.codec, reason: "a codec HELLO did not list")
            return
        }
        var asked = (width: Int(attach.width), height: Int(attach.height))
        var note = ""
        if !(64...4096).contains(asked.width) || !(64...4096).contains(asked.height) {
            Log.red("ATTACH asks for \(asked.width)x\(asked.height) (64 to 4096): using 1920x1080")
            note = "the size asked for, \(asked.width)x\(asked.height), is outside 64 to 4096: 1920x1080 instead"
            asked = (1920, 1080)
        } else if (asked.width | asked.height) & 1 != 0 {
            note = "the size asked for, \(asked.width)x\(asked.height), is rounded down to even numbers"
        }
        let width = asked.width & ~1
        let height = asked.height & ~1
        let reason = note
        let codec = attach.codec
        let kbps = attach.bitrateKbps > 0 && attach.bitrateKbps <= UInt32(Int32.max) ? Int(attach.bitrateKbps) : 25000
        let hz = Int(attach.refreshHz)
        control.async { [self] in
            let was = attached
            stopEncoder()
            generation &+= 1
            let started = Encoder.start(width: width, height: height, kbps: kbps, generation: generation, host: self, stats: stats)
            switch started {
            case .success:
                sendAttachResult(ok: true, width: UInt16(width), height: UInt16(height), codec: codec, reason: reason)
            case .failure(let error):
                sendAttachResult(ok: false, width: UInt16(width), height: UInt16(height), codec: codec, reason: error.description)
            }
            guard case .success(let encoder) = started else {
                queue.setGeneration(0)
                sending.store(false, ordering: .releasing)
                setClient(false)
                return
            }
            queue.setGeneration(generation)
            lock.withLock { self.encoder = encoder }
            stats.resetSecond()
            sending.store(true, ordering: .releasing)
            setClient(true)
            Log.info("a client \(was ? "attached again" : "attached"): \(width)x\(height) at \(hz) Hz, \(kbps) kbit/s")
            if paused {
                paused = false
                Log.info("the paused game goes on for the client")
            }
        }
    }

    private func sendAttachResult(ok: Bool, width: UInt16, height: UInt16, codec: UInt32, reason: String) {
        let result = DMStream.AttachResult(ok: ok, width: width, height: height, codec: codec, reason: reason)
        _ = queue.enqueue(.control(DMStream.encode(.attachResult(result), sentNs: 0)))
    }

    func detach(pause: Bool, why: String) {
        control.sync {
            let was = attached
            let suspend = pause && was && !paused
            let resume = !pause && paused
            if suspend { paused = true }
            if resume { paused = false }
            sending.store(false, ordering: .releasing)
            setClient(false)
            stopEncoder()
            queue.setGeneration(0)
            if suspend { pauses.add(1, ordering: .relaxed) }
            if was { Log.info("\(why): the encoder stopped\(suspend ? "; the game is paused until the next ATTACH" : "")") }
            if suspend { Log.info("the game is paused, as the Switch's HOME button pauses it (a fake host only stops its media)") }
            if resume { Log.info("\(why): the paused game goes on at the Mac") }
        }
    }

    func stopForExit() {
        control.sync {
            sending.store(false, ordering: .releasing)
            setClient(false)
            stopEncoder()
        }
    }

    func sendFrame(config: [Data]?, frame: DMStream.VideoFrame, generation: UInt32) -> Bool {
        guard sending.load(ordering: .acquiring) else { return false }
        let frameData = DMStream.encode(.videoFrame(frame), sentNs: 0)
        var item = OutgoingItem(data: frameData, headers: [0], kind: .video, generation: generation)
        if let config {
            var data = DMStream.encode(.videoConfig(config), sentNs: 0)
            item.headers = [0, data.count]
            data.append(frameData)
            item.data = data
        }
        return queue.enqueue(item, frameFlags: frame.flags)
    }

    func sendStats(_ text: String) {
        guard sending.load(ordering: .acquiring) else { return }
        _ = queue.enqueue(.control(DMStream.encode(.stats(text), sentNs: 0)))
    }

    private func stopEncoder() {
        let old = lock.withLock { () -> Encoder? in
            let old = encoder
            encoder = nil
            return old
        }
        old?.stop()
    }

    private func setClient(_ on: Bool) {
        guard attached != on else { return }
        attached = on
        let next = audioGeneration.add(1, ordering: .acquiringAndReleasing).newValue
        guard on else { return }
        let thread = Thread { [self] in audioLoop(next) }
        thread.name = "fakestream.audio"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func audioLoop(_ generation: UInt64) {
        let step = 2 * Double.pi * 440 / 48000
        var phase = 0.0
        var samples = [Int16](repeating: 0, count: Self.audioFrames * 2)
        if !Realtime.promote(periodNs: Self.audioBlockNs, computationNs: 500_000, constraintNs: 2_000_000), stats.once(.audioRealtime) {
            Log.red("the audio thread did not get the time-constraint policy: its blocks follow the system's timer coalescing")
        }
        var time = LinkClock.nowNs()
        while audioGeneration.load(ordering: .acquiring) == generation {
            time += Self.audioBlockNs
            let now = LinkClock.nowNs()
            if time > now {
                mach_wait_until(LinkClock.machTime(nanoseconds: time))
            } else if now - time > 100_000_000 {
                time = now
            }
            guard audioGeneration.load(ordering: .acquiring) == generation else { return }
            for frame in 0..<Self.audioFrames {
                let value = Int16((sin(phase) * 8192).rounded())
                samples[2 * frame] = value
                samples[2 * frame + 1] = value
                phase += step
                if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
            }
            guard sending.load(ordering: .acquiring) else { continue }
            let pcm = samples.withUnsafeBytes { Data($0) }
            let block = DMStream.Audio(hostTimeNs: time, frameCount: UInt32(Self.audioFrames), samples: pcm)
            _ = queue.enqueue(OutgoingItem(data: DMStream.encode(.audio(block), sentNs: 0), headers: [0], kind: .audio))
        }
    }

    private func startPadSummary() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in logPads() }
        timer.resume()
        padTimer = timer
    }

    private func logPads() {
        let current = (pad: padMessages.load(ordering: .relaxed), pads: padsMessages.load(ordering: .relaxed), mask: padsMask.load(ordering: .relaxed))
        guard current != loggedPads else { return }
        Log.info("controllers from the hub: \(current.pad - loggedPads.pad) PAD in the last second (\(current.pad) in all), "
            + "\(current.pads) PADS, players 0x\(String(current.mask, radix: 16)); this host does not apply them")
        loggedPads = current
    }
}
