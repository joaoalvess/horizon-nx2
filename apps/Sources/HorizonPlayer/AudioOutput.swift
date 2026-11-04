import AVFoundation
import Foundation
import HorizonLink
import Synchronization

final class JitterStore: Sendable {
    let buffer: Mutex<AudioJitterBuffer>

    init(settings: AudioJitterSettings) {
        buffer = Mutex(AudioJitterBuffer(settings: settings))
    }
}

public final class AudioOutput: @unchecked Sendable {
    private let store: JitterStore
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var source: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var stopped = false
    private var failure: String?

    public init(settings: AudioJitterSettings = AudioJitterSettings()) {
        store = JitterStore(settings: settings)
    }

    public var stats: AudioStats {
        var stats = store.buffer.withLock { $0.stats }
        lock.withLock {
            stats.running = running
            stats.error = failure
        }
        return stats
    }

    public func start() {
        let sampleRate = store.buffer.withLock { $0.settings.sampleRate }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            lock.withLock { failure = "invalid audio format" }
            return
        }
        let store = self.store
        let source = AVAudioSourceNode(format: format) { silence, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let frames = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? first : first
            store.buffer.withLock { $0.pull(frames: frames, left: first, right: second) }
            silence.pointee = false
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        lock.withLock { self.source = source }
        configureSession()
        let center = NotificationCenter.default
        let change = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restart()
        }
        lock.withLock { observers.append(change) }
        #if os(tvOS)
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart()
        }
        lock.withLock { observers.append(interruption) }
        #endif
        restart()
    }

    public func push(_ packet: AudioPacket) {
        store.buffer.withLock { $0.push(packet.samples, sequence: packet.sequence) }
    }

    public func stop() {
        let observers = lock.withLock { () -> [NSObjectProtocol] in
            stopped = true
            running = false
            let current = self.observers
            self.observers = []
            return current
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.stop()
        if let source = lock.withLock({ self.source }) {
            engine.detach(source)
        }
        lock.withLock { source = nil }
    }

    private func restart() {
        guard !lock.withLock({ stopped }) else { return }
        engine.stop()
        engine.prepare()
        do {
            try engine.start()
            lock.withLock {
                running = true
                failure = nil
            }
        } catch {
            lock.withLock {
                running = false
                failure = "audio did not start: \(error.localizedDescription)"
            }
        }
    }

    private func configureSession() {
        #if os(tvOS) || os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
        } catch {
            lock.withLock { failure = "the audio session refused the configuration: \(error.localizedDescription)" }
        }
        #endif
    }
}
