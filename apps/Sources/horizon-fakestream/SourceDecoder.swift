import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private final class DecodedPicture: @unchecked Sendable {
    private let lock = NSLock()
    private var status: OSStatus = noErr
    private var image: CVPixelBuffer?

    func store(status: OSStatus, image: CVPixelBuffer?) {
        lock.withLock {
            self.status = status
            self.image = image
        }
    }

    func take() -> (status: OSStatus, image: CVPixelBuffer?) {
        lock.withLock {
            defer { image = nil }
            return (status, image)
        }
    }
}

final class SourceDecoder {
    private static var pictureAttributes: CFDictionary { [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary }

    let recording: Recording
    private var reader: AccessUnitReader
    private var format: CMVideoFormatDescription
    private var session: VTDecompressionSession?
    private var sps: NALUnit
    private var pps: NALUnit
    private var sample: [UInt8] = []
    private var index: Int64 = 0
    private var loops = 0
    private(set) var errors = 0

    init(recording: Recording) throws {
        self.recording = recording
        reader = AccessUnitReader(recording: recording)
        format = recording.format
        sps = recording.sps
        pps = recording.pps
        guard let session = Self.makeSession(format) else {
            throw FakeStreamError("no H.264 decoder for the recording \(recording.path)")
        }
        self.session = session
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func nextPicture() -> CVPixelBuffer? {
        for _ in 0..<16 {
            let (units, loopedAfter) = reader.next()
            if let loopedAfter {
                loops += 1
                Log.info("the recording looped (\(loopedAfter) frames, loop \(loops))")
            }
            var newSPS: NALUnit?
            var newPPS: NALUnit?
            var picture = false
            sample.removeAll(keepingCapacity: true)
            for unit in units {
                switch unit.type {
                case 7: newSPS = unit
                case 8: newPPS = unit
                case 9, 10, 11, 12: continue
                default:
                    if unit.type == 1 || unit.type == 5 { picture = true }
                    let length = UInt32(unit.length).bigEndian
                    withUnsafeBytes(of: length) { sample.append(contentsOf: $0) }
                    sample.append(contentsOf: UnsafeBufferPointer(start: recording.bytes + unit.offset, count: unit.length))
                }
            }
            if newSPS != nil || newPPS != nil { update(sps: newSPS ?? sps, pps: newPPS ?? pps) }
            guard picture else { continue }
            if let image = decode() { return image }
        }
        return nil
    }

    private func update(sps newSPS: NALUnit, pps newPPS: NALUnit) {
        if recording.same(newSPS, sps) && recording.same(newPPS, pps) { return }
        guard let newFormat = Recording.format(bytes: recording.bytes, sps: newSPS, pps: newPPS) else {
            report("the recording's parameter sets at byte \(newSPS.offset) do not make a format description")
            return
        }
        sps = newSPS
        pps = newPPS
        format = newFormat
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = Self.makeSession(newFormat)
        Log.info("the recording's parameter sets changed: the decoder is recreated")
    }

    private func decode() -> CVPixelBuffer? {
        if session == nil { session = Self.makeSession(format) }
        guard let session else { return nil }
        var block: CMBlockBuffer?
        let length = sample.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == noErr, let block else { return report("cannot make a block buffer (\(status))") }
        status = sample.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { return report("cannot fill a block buffer (\(status))") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: index, timescale: 60), decodeTimeStamp: .invalid
        )
        index += 1
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return report("cannot make a sample buffer (\(status))") }
        let picture = DecodedPicture()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, flags, image, _, _ in
            picture.store(status: status, image: flags.contains(.frameDropped) ? nil : image)
        }
        if status == noErr { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        if status == kVTInvalidSessionErr {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        guard status == noErr else { return report("VTDecompressionSessionDecodeFrame failed (\(status))") }
        let result = picture.take()
        guard result.status == noErr else { return report("the decoder reported \(result.status)") }
        guard let image = result.image else { return report("the decoder gave no picture") }
        return image
    }

    @discardableResult
    private func report(_ text: String) -> CVPixelBuffer? {
        errors += 1
        if errors <= 5 { Log.red("the recording's frame \(index) did not decode: \(text)") }
        else if errors == 6 { Log.red("more frames of the recording did not decode; they are counted, not printed") }
        return nil
    }

    private static func makeSession(_ format: CMVideoFormatDescription) -> VTDecompressionSession? {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: pictureAttributes,
            outputCallback: nil, decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            Log.red("VTDecompressionSessionCreate failed (\(status))")
            return nil
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }
}
