import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox
@testable import HorizonLink
@testable import HorizonPlayer

struct EncoderFailure: Error, Sendable {
    let reason: String
}

struct EncodedFrame: Sendable {
    let sets: [Data]
    let accessUnit: Data
    let sync: Bool
}

final class EncodedSlot: Sendable {
    let value = Mutex<Result<EncodedFrame, EncoderFailure>?>(nil)
}

final class SyntheticEncoder {
    let width: Int
    let height: Int
    let codec: CMVideoCodecType
    private let session: VTCompressionSession
    private var index: Int64 = 0

    init(width: Int, height: Int, codec: CMVideoCodecType = kCMVideoCodecType_H264) throws {
        self.width = width
        self.height = height
        self.codec = codec
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw EncoderFailure(reason: "VTCompressionSessionCreate \(status)") }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 10_000))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 400_000))
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func encode(key: Bool = false) throws -> EncodedFrame {
        let image = try makeImage(shade: UInt8(truncatingIfNeeded: index * 37 + 20))
        let time = CMTime(value: index, timescale: 60)
        index += 1
        let slot = EncodedSlot()
        let codec = self.codec
        let properties = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: time, duration: CMTime(value: 1, timescale: 60),
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            let result: Result<EncodedFrame, EncoderFailure>
            if status == noErr, let sample {
                result = Self.extract(sample, codec: codec)
            } else {
                result = .failure(EncoderFailure(reason: "the encoder returned \(status)"))
            }
            slot.value.withLock { $0 = result }
        }
        guard status == noErr else { throw EncoderFailure(reason: "VTCompressionSessionEncodeFrame \(status)") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: time)
        guard let result = slot.value.withLock({ $0 }) else { throw EncoderFailure(reason: "no encoder output") }
        return try result.get()
    }

    func encode(count: Int, firstKey: Bool = true) throws -> [EncodedFrame] {
        try (0..<count).map { try encode(key: firstKey && $0 == 0) }
    }

    private func makeImage(shade: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let created else { throw EncoderFailure(reason: "CVPixelBufferCreate \(status)") }
        CVPixelBufferLockBaseAddress(created, [])
        defer { CVPixelBufferUnlockBaseAddress(created, []) }
        guard let base = CVPixelBufferGetBaseAddress(created) else { throw EncoderFailure(reason: "no pixel memory") }
        let stride = CVPixelBufferGetBytesPerRow(created)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels + y * stride + x * 4
                pixel[0] = shade
                pixel[1] = UInt8(truncatingIfNeeded: x * 2)
                pixel[2] = UInt8(truncatingIfNeeded: y * 3)
                pixel[3] = 255
            }
        }
        return created
    }

    private static func extract(_ sample: CMSampleBuffer, codec: CMVideoCodecType) -> Result<EncodedFrame, EncoderFailure> {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
            return .failure(EncoderFailure(reason: "an encoded sample without format or data"))
        }
        var count = 0
        var headerLength: Int32 = 0
        let lookup: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?,
                     UnsafeMutablePointer<Int32>?) -> OSStatus = { index, pointer, size, total, header in
            codec == kCMVideoCodecType_HEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                    parameterSetCountOut: total, nalUnitHeaderLengthOut: header
                )
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                    parameterSetCountOut: total, nalUnitHeaderLengthOut: header
                )
        }
        guard lookup(0, nil, nil, &count, &headerLength) == noErr, headerLength == 4 else {
            return .failure(EncoderFailure(reason: "no parameter sets with 4-byte lengths"))
        }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard lookup(index, &pointer, &size, nil, nil) == noErr, let pointer else {
                return .failure(EncoderFailure(reason: "parameter set \(index) unreadable"))
            }
            sets.append(Data(bytes: pointer, count: size))
        }
        let length = CMBlockBufferGetDataLength(block)
        var unit = Data(count: length)
        let status = unit.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return .failure(EncoderFailure(reason: "CMBlockBufferCopyDataBytes \(status)")) }
        var sync = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            sync = !notSync
        }
        return .success(EncodedFrame(sets: sets, accessUnit: unit, sync: sync))
    }
}

struct Wire {
    var sender = VideoSender()
    var receiver = VideoReceiver()
    var dmFrame: UInt64 = 0

    mutating func send(_ frame: EncodedFrame, ltrToken: Int64 = -1, refresh: Bool = false) -> [ReceivedVideo] {
        send(sets: frame.sets, accessUnit: frame.accessUnit, sync: frame.sync, ltrToken: ltrToken, refresh: refresh)
    }

    mutating func send(sets: [Data], accessUnit: Data, sync: Bool, ltrToken: Int64 = -1, refresh: Bool = false) -> [ReceivedVideo] {
        sender.configure(sets)
        dmFrame += 1
        var flags: DMStream.FrameFlags = []
        if sync { flags.insert(.sync) }
        if refresh { flags.insert(.refresh) }
        let packet = sender.packetize(DMStream.VideoFrame(
            presentNs: LinkClock.nowNs(), frameNumber: dmFrame, ltrToken: ltrToken, flags: flags, accessUnit: accessUnit
        ))
        var delivered: [ReceivedVideo] = []
        for datagram in packet.data {
            for output in receiver.receive(datagram, now: LinkClock.nowNs()) {
                if case .deliver(let video) = output { delivered.append(video) }
            }
        }
        return delivered
    }

    mutating func send(_ frames: [EncodedFrame], tokens: (Int) -> Int64 = { _ in -1 }) -> [ReceivedVideo] {
        frames.enumerated().flatMap { send($0.element, ltrToken: tokens($0.offset)) }
    }
}

final class RecordingLink: PlayerLink, @unchecked Sendable {
    struct Decoded: Equatable {
        let frame: UInt32
        let token: Int64
        let at: UInt64
        let microseconds: UInt32
    }

    private let lock = NSLock()
    private var calls: [Decoded] = []
    private var refreshes = 0
    private let offsetNs: Int64?

    init(offsetNs: Int64? = 0) {
        self.offsetNs = offsetNs
    }

    var decodedCalls: [Decoded] { lock.withLock { calls } }
    var refreshCount: Int { lock.withLock { refreshes } }

    func decoded(frame: UInt32, ltrToken: Int64, at decodedNs: UInt64, decodeMicroseconds: UInt32) {
        lock.withLock { calls.append(Decoded(frame: frame, token: ltrToken, at: decodedNs, microseconds: decodeMicroseconds)) }
    }

    func requestRefresh() {
        lock.withLock { refreshes += 1 }
    }

    func clientTime(hubNs: UInt64) -> UInt64? {
        offsetNs.map { hubNs &- UInt64(bitPattern: $0) }
    }

    var linkStats: LinkClientStats { LinkClientStats() }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("horizon-player-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
