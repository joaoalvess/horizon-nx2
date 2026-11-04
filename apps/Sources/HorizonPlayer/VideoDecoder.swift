import CoreMedia
import CoreVideo
import Foundation
import HorizonLink
import Synchronization
import VideoToolbox

public enum VideoCodec: Sendable, Equatable {
    case h264
    case hevc

    public static func detect(_ sets: [Data]) -> VideoCodec? {
        let first = sets.compactMap(\.first)
        if first.contains(where: { $0 & 0x1F == 7 }), first.contains(where: { $0 & 0x1F == 8 }) { return .h264 }
        let hevc = first.map { ($0 >> 1) & 0x3F }
        if hevc.contains(32), hevc.contains(33), hevc.contains(34) { return .hevc }
        return nil
    }
}

public enum DecodeError: Error, Sendable, Equatable {
    case emptyAccessUnit
    case unknownCodec
    case parameterSets(OSStatus)
    case session(OSStatus)
    case sample(OSStatus)
    case decode(OSStatus)
    case dropped
    case noImage
    case needsSyncFrame
}

public struct DecodedFrame: @unchecked Sendable {
    public let video: ReceivedVideo
    public let image: CVPixelBuffer
    public let startNs: UInt64
    public let endNs: UInt64
    public let delayed: Bool

    public var width: Int { CVPixelBufferGetWidth(image) }
    public var height: Int { CVPixelBufferGetHeight(image) }
    public var decodeMicroseconds: UInt32 { UInt32(clamping: (endNs &- startNs) / 1000) }
}

public enum DecodeOutcome: Sendable {
    case decoded(DecodedFrame)
    case failed(DecodeError, startNs: UInt64, endNs: UInt64)
}

final class DecodeSlot: Sendable {
    let value = Mutex<DecodeOutcome?>(nil)
}

public final class VideoDecoder {
    public private(set) var sessionsCreated = 0
    public private(set) var codec: VideoCodec?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sets: [Data] = []

    public init() {}

    deinit {
        invalidate()
    }

    public var needsSyncFrame: Bool { session == nil }

    public func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        sets = []
    }

    public func decode(_ video: ReceivedVideo) -> DecodeOutcome {
        let start = LinkClock.nowNs()
        let failed = { (error: DecodeError) -> DecodeOutcome in .failed(error, startNs: start, endNs: LinkClock.nowNs()) }
        guard !video.envelope.accessUnit.isEmpty else { return failed(.emptyAccessUnit) }
        let parameterSets = video.parameterSets.map(Self.stripStartCode)
        if session == nil, !video.isSync { return failed(.needsSyncFrame) }
        if session == nil || parameterSets != sets, let error = prepare(parameterSets) { return failed(error) }
        guard let session, let format else { return failed(.needsSyncFrame) }
        let sample: CMSampleBuffer
        switch Self.sampleBuffer(video, format: format) {
        case .success(let built): sample = built
        case .failure(let error): return failed(error)
        }
        let slot = DecodeSlot()
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &info) {
            status, flags, image, _, _ in
            let end = LinkClock.nowNs()
            let outcome: DecodeOutcome
            if status != noErr {
                outcome = .failed(.decode(status), startNs: start, endNs: end)
            } else if flags.contains(.frameDropped) {
                outcome = .failed(.dropped, startNs: start, endNs: end)
            } else if let image {
                outcome = .decoded(DecodedFrame(video: video, image: image, startNs: start, endNs: end, delayed: false))
            } else {
                outcome = .failed(.noImage, startNs: start, endNs: end)
            }
            slot.value.withLock { $0 = outcome }
        }
        if let outcome = slot.value.withLock({ $0 }) {
            if case .failed(.decode(let code), _, _) = outcome { reset(after: code) }
            return outcome
        }
        if status != noErr {
            reset(after: status)
            return failed(.decode(status))
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard let outcome = slot.value.withLock({ $0 }) else { return failed(.noImage) }
        if case .decoded(let frame) = outcome {
            return .decoded(DecodedFrame(video: frame.video, image: frame.image, startNs: frame.startNs, endNs: frame.endNs, delayed: true))
        }
        return outcome
    }

    private func reset(after status: OSStatus) {
        guard status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr else { return }
        invalidate()
    }

    private func prepare(_ parameterSets: [Data]) -> DecodeError? {
        guard let codec = VideoCodec.detect(parameterSets) else { return .unknownCodec }
        let built: CMVideoFormatDescription
        switch Self.formatDescription(parameterSets, codec: codec) {
        case .success(let description): built = description
        case .failure(let error): return error
        }
        invalidate()
        let created: VTDecompressionSession
        switch Self.makeSession(built) {
        case .success(let made): created = made
        case .failure(let error): return error
        }
        session = created
        format = built
        sets = parameterSets
        self.codec = codec
        sessionsCreated += 1
        return nil
    }

    private static let warmUpSets = [
        Data([0x27, 0x42, 0x00, 0x0B, 0xAB, 0x41, 0x86, 0xF0, 0x20, 0xC2, 0x28]),
        Data([0x28, 0xCE, 0x3C, 0x80]),
    ]

    private static let warmed = Mutex(false)

    @discardableResult
    public static func warmUp() -> Bool {
        guard case .success(let format) = formatDescription(warmUpSets, codec: .h264),
              case .success(let session) = makeSession(format) else { return false }
        VTDecompressionSessionInvalidate(session)
        return true
    }

    static func warmUpOnce() {
        let first = warmed.withLock { done -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if first { warmUp() }
    }

    static func makeSession(_ format: CMVideoFormatDescription) -> Result<VTDecompressionSession, DecodeError> {
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created
        )
        guard status == noErr, let created else { return .failure(.session(status)) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return .success(created)
    }

    static func stripStartCode(_ set: Data) -> Data {
        let bytes = [UInt8](set.prefix(4))
        if bytes.count == 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 { return Data(set.dropFirst(4)) }
        if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 { return Data(set.dropFirst(3)) }
        return set
    }

    static func formatDescription(_ sets: [Data], codec: VideoCodec) -> Result<CMVideoFormatDescription, DecodeError> {
        let total = sets.reduce(0) { $0 + $1.count }
        guard !sets.isEmpty, total > 0 else { return .failure(.parameterSets(kCMFormatDescriptionError_InvalidParameter)) }
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
        defer { storage.deallocate() }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var offset = 0
        for set in sets {
            set.copyBytes(to: storage + offset, count: set.count)
            pointers.append(UnsafePointer(storage + offset))
            sizes.append(set.count)
            offset += set.count
        }
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer -> OSStatus in
            sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                guard let pointerBase = pointerBuffer.baseAddress, let sizeBase = sizeBuffer.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase, nalUnitHeaderLength: 4, formatDescriptionOut: &description
                    )
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description
                    )
                }
            }
        }
        guard status == noErr, let description else { return .failure(.parameterSets(status)) }
        return .success(description)
    }

    static func sampleBuffer(_ video: ReceivedVideo, format: CMVideoFormatDescription) -> Result<CMSampleBuffer, DecodeError> {
        let unit = video.envelope.accessUnit
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: unit.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: unit.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { return .failure(.sample(status)) }
        status = unit.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: unit.count)
        }
        guard status == noErr else { return .failure(.sample(status)) }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: Int64(clamping: video.envelope.presentNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var size = unit.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return .failure(.sample(status)) }
        return .success(sample)
    }
}
