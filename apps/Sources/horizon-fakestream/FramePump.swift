import CoreVideo
import Darwin
import Foundation
import HorizonLink
import Synchronization
import VideoToolbox

final class FramePump: @unchecked Sendable {
    private struct Ready {
        let input: CVPixelBuffer
        let generation: UInt32
    }

    static let depth = 2

    private let host: Host
    private let decoder: SourceDecoder
    private let stats: Stats
    private let fps: UInt64
    private let running = Atomic<Bool>(true)
    private let tickLock = NSLock()
    private let ringLock = NSLock()
    private var ring: [Ready] = []
    private let wake = DispatchSemaphore(value: 0)
    private var transfer: VTPixelTransferSession?

    init(host: Host, decoder: SourceDecoder, stats: Stats, fps: Int) {
        self.host = host
        self.decoder = decoder
        self.stats = stats
        self.fps = UInt64(fps)
    }

    func start() {
        let ticks = Thread { [self] in runTicks() }
        ticks.name = "fakestream.frames"
        ticks.qualityOfService = .userInteractive
        ticks.start()
        let decoding = Thread { [self] in runDecoder() }
        decoding.name = "fakestream.decode"
        decoding.qualityOfService = .userInteractive
        decoding.start()
    }

    func stop() {
        running.store(false, ordering: .releasing)
        tickLock.withLock {}
        wake.signal()
    }

    private func runTicks() {
        let period = 1_000_000_000 / fps
        if !Realtime.promote(periodNs: period, computationNs: 2_000_000, constraintNs: min(period, 8_000_000)) {
            Log.red("the frame timer thread did not get the time-constraint policy: its cadence follows the system's timer coalescing")
        }
        let start = LinkClock.nowNs()
        var tick: UInt64 = 1
        while running.load(ordering: .acquiring) {
            mach_wait_until(LinkClock.machTime(nanoseconds: deadline(start, tick)))
            let alive = tickLock.withLock { () -> Bool in
                guard running.load(ordering: .acquiring) else { return false }
                self.tick()
                return true
            }
            guard alive else { return }
            tick += 1
            let now = LinkClock.nowNs()
            if now > deadline(start, tick) {
                let due = (now - start) * fps / 1_000_000_000 + 1
                stats.lateTicks.add(due - tick, ordering: .relaxed)
                tick = due
            }
        }
    }

    private func deadline(_ start: UInt64, _ tick: UInt64) -> UInt64 {
        start + tick * 1_000_000_000 / fps
    }

    private func tick() {
        guard let encoder = host.currentEncoder() else { return }
        let picture = ringLock.withLock { () -> CVPixelBuffer? in
            while !ring.isEmpty {
                let first = ring.removeFirst()
                if first.generation == encoder.generation { return first.input }
            }
            return nil
        }
        wake.signal()
        guard let picture else {
            stats.starved.add(1, ordering: .relaxed)
            return
        }
        encoder.encode(picture)
    }

    private func runDecoder() {
        while running.load(ordering: .acquiring) {
            _ = wake.wait(timeout: .now() + .milliseconds(100))
            guard let encoder = host.currentEncoder() else { continue }
            while running.load(ordering: .acquiring) && needsPicture(for: encoder) {
                guard let source = decoder.nextPicture(), let input = prepare(source, for: encoder) else { break }
                ringLock.withLock { ring.append(Ready(input: input, generation: encoder.generation)) }
            }
        }
    }

    private func needsPicture(for encoder: Encoder) -> Bool {
        ringLock.withLock {
            ring.removeAll { $0.generation != encoder.generation }
            return ring.count < Self.depth
        }
    }

    private func prepare(_ source: CVPixelBuffer, for encoder: Encoder) -> CVPixelBuffer? {
        let image: CVPixelBuffer
        if CVPixelBufferGetWidth(source) == encoder.width && CVPixelBufferGetHeight(source) == encoder.height {
            image = source
        } else {
            guard let scaled = scale(source, for: encoder) else { return nil }
            image = scaled
        }
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return image
    }

    private func scale(_ source: CVPixelBuffer, for encoder: Encoder) -> CVPixelBuffer? {
        if transfer == nil {
            var created: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created)
            guard status == noErr, let created else {
                if stats.once(.transfer) { Log.red("VTPixelTransferSessionCreate failed (\(status))") }
                return nil
            }
            transfer = created
        }
        guard let transfer else { return nil }
        var destination: CVPixelBuffer?
        if let pool = encoder.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        }
        if destination == nil {
            let attributes = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, encoder.width, encoder.height, kCVPixelFormatType_32BGRA, attributes, &destination)
        }
        guard let destination else {
            if stats.once(.transfer) { Log.red("cannot create a \(encoder.width)x\(encoder.height) pixel buffer for the encoder") }
            return nil
        }
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
        guard status == noErr else {
            if stats.once(.transfer) { Log.red("VTPixelTransferSessionTransferImage failed (\(status))") }
            return nil
        }
        return destination
    }
}
