import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class FrameRenderer {
    let renderer: AVSampleBufferVideoRenderer
    private var format: CMVideoFormatDescription?

    init(_ renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func show(_ image: CVPixelBuffer, presentNs: UInt64) -> Bool {
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: image) }) ?? true {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &created
            ) == noErr, let created else { return false }
            format = created
        }
        guard let format else { return false }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: Int64(clamping: presentNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return false }
        if sample.sampleAttachments.count > 0 { sample.sampleAttachments[0][.displayImmediately] = true }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sample)
        return true
    }

    func flush() {
        renderer.flush()
    }
}
