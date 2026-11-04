import CoreMedia
import CoreVideo
import Foundation
import HorizonLink
import Synchronization
import VideoToolbox

enum Force {
    static let none = 0
    static let refresh = 1
    static let key = 2
}

struct FrameContext: Sendable {
    let presentNs: UInt64
    let submitNs: UInt64
    let force: Int
}

final class Encoder: @unchecked Sendable {
    static let framesInFlight = 4

    let width: Int
    let height: Int
    let generation: UInt32
    private let session: VTCompressionSession
    private unowned let host: Host
    private let stats: Stats
    private let lock = NSLock()
    private var stopped = false
    private var acks: [Int64] = []
    private var acked = false
    private let force = Atomic<Int>(Force.key)
    private let inFlight = Atomic<Int>(0)
    private let lastDone = Atomic<UInt64>(0)
    private let outputLock = NSLock()
    private var lastFormat: CMFormatDescription?
    private var nalLength = 4

    private init(session: VTCompressionSession, width: Int, height: Int, generation: UInt32, host: Host, stats: Stats) {
        self.session = session
        self.width = width
        self.height = height
        self.generation = generation
        self.host = host
        self.stats = stats
    }

    static func start(width: Int, height: Int, kbps: Int, generation: UInt32, host: Host, stats: Stats) -> Result<Encoder, FakeStreamError> {
        let specification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ] as CFDictionary
        let source = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: source, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            let reason = "no low-latency hardware H.264 encoder (\(status))"
            Log.red(reason)
            return .failure(FakeStreamError(reason))
        }
        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))
        set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Int64(kbps) * 1000))
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.info("H.264 \(width)x\(height), \(kbps) kbit/s, low-latency rate control, LTR on, \(framesInFlight) frames in flight")
        return .success(Encoder(session: session, width: width, height: height, generation: generation, host: host, stats: stats))
    }

    private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr { Log.red("the encoder refused \(key) (\(status))") }
    }

    var pixelBufferPool: CVPixelBufferPool? { VTCompressionSessionGetPixelBufferPool(session) }

    func request(_ value: Int) {
        var current = force.load(ordering: .relaxed)
        while current < value {
            let (exchanged, original) = force.compareExchange(expected: current, desired: value, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    func acknowledge(_ tokens: [Int64]) {
        lock.withLock {
            guard !stopped else { return }
            acks.append(contentsOf: tokens)
            acked = true
        }
    }

    func setBitrate(_ kbps: Int) {
        lock.withLock {
            guard !stopped else { return }
            Self.set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Int64(kbps) * 1000))
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    func encode(_ image: CVPixelBuffer) {
        guard inFlight.load(ordering: .acquiring) < Self.framesInFlight else {
            stats.ringDrops.add(1, ordering: .relaxed)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        var mode = force.exchange(Force.none, ordering: .acquiringAndReleasing)
        if mode == Force.refresh && !acked { mode = Force.key }
        var options: [CFString: Any] = [:]
        if mode == Force.key { options[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if mode == Force.refresh { options[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true }
        if !acks.isEmpty { options[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acks.map { NSNumber(value: $0) } }
        let present = LinkClock.nowNs()
        let context = FrameContext(presentNs: present, submitNs: present, force: mode)
        inFlight.add(1, ordering: .acquiringAndReleasing)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: CMTime(value: Int64(present), timescale: 1_000_000_000),
            duration: .invalid, frameProperties: options.isEmpty ? nil : options as CFDictionary, infoFlagsOut: nil
        ) { [self] status, flags, sample in
            encoded(status: status, flags: flags, sample: sample, context: context)
        }
        if status == noErr {
            acks.removeAll()
            return
        }
        inFlight.subtract(1, ordering: .acquiringAndReleasing)
        stats.failed.add(1, ordering: .relaxed)
        if mode != Force.none { request(mode) }
        if stats.once(.encodeCall) { Log.red("VTCompressionSessionEncodeFrame failed (\(status))") }
    }

    private func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?, context: FrameContext) {
        let done = LinkClock.nowNs()
        inFlight.subtract(1, ordering: .acquiringAndReleasing)
        let start = max(lastDone.exchange(done, ordering: .relaxed), context.submitNs)
        guard status == noErr, let sample, !flags.contains(.frameDropped) else {
            if status != noErr {
                stats.failed.add(1, ordering: .relaxed)
                if stats.once(.encoderFailed) { Log.red("the encoder failed a frame (\(status))") }
            } else {
                stats.encoderDrops.add(1, ordering: .relaxed)
            }
            if context.force != Force.none { request(context.force) }
            return
        }
        var sync = true
        var token: Int64 = -1
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as NSArray?,
           let first = attachments.firstObject as? NSDictionary {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool, notSync { sync = false }
            if let number = first[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber { token = number.int64Value }
        }
        var config: [Data]?
        let headerLength = outputLock.withLock { () -> Int in
            if let format = CMSampleBufferGetFormatDescription(sample),
               sync || lastFormat == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: lastFormat) {
                if let (sets, length) = Self.parameterSets(format) {
                    config = sets
                    nalLength = length
                } else if stats.once(.parameterSets) {
                    Log.red("no parameter sets in the encoder's format description")
                }
                lastFormat = format
            }
            return nalLength
        }
        let accessUnit = accessUnit(sample, nalLength: headerLength)
        let frameFlags: DMStream.FrameFlags = [sync ? .sync : [], context.force == Force.refresh ? .refresh : []]
        let frame = DMStream.VideoFrame(
            presentNs: context.presentNs, frameNumber: host.nextFrameNumber(), ltrToken: token, flags: frameFlags, accessUnit: accessUnit
        )
        if host.sendFrame(config: config, frame: frame, generation: generation) { request(Force.refresh) }
        let encodeMs = Double(done - start) / 1e6
        let totalMs = Double(done - context.presentNs) / 1e6
        if let text = stats.frameEncoded(
            encodeMs: encodeMs, totalMs: totalMs, bytes: accessUnit.count, sync: sync, ltr: token >= 0, presentNs: context.presentNs, doneNs: done
        ) {
            host.sendStats(text)
        }
    }

    private static func parameterSets(_ format: CMFormatDescription) -> ([Data], Int)? {
        var count = 0
        var headerLength: Int32 = 4
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength
        ) == noErr else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size <= Int(UInt16.max) else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, Int(headerLength))
    }

    private func accessUnit(_ sample: CMSampleBuffer, nalLength: Int) -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return Data() }
        let length = CMBlockBufferGetDataLength(block)
        var raw = Data(count: length)
        let status = raw.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return Data() }
        return raw.withUnsafeBytes { bytes -> Data in
            var offset = 0
            var valid = true
            while offset + nalLength <= bytes.count {
                var size = 0
                for index in 0..<nalLength { size = size << 8 | Int(bytes[offset + index]) }
                offset += nalLength
                if size > bytes.count - offset {
                    valid = false
                    break
                }
                offset += size
            }
            if valid && nalLength == 4 && offset == bytes.count { return raw }
            if !valid && stats.once(.nalOverrun) { Log.red("a NAL unit runs past its sample (\(bytes.count) bytes)") }
            var converted = Data(capacity: bytes.count + 64)
            offset = 0
            while offset + nalLength <= bytes.count {
                var size = 0
                for index in 0..<nalLength { size = size << 8 | Int(bytes[offset + index]) }
                offset += nalLength
                guard size <= bytes.count - offset else { break }
                withUnsafeBytes(of: UInt32(size).bigEndian) { converted.append(contentsOf: $0) }
                converted.append(contentsOf: bytes[offset..<offset + size])
                offset += size
            }
            return converted
        }
    }
}
