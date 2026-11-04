import AVFoundation
import CoreMedia
import Foundation
import HorizonLink
import Testing
import VideoToolbox
@testable import HorizonPlayer

struct PlayerSessionTests {
    @Test func decodesInOrderAndAcknowledgesEachFrame() throws {
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        let videos = wire.send(try encoder.encode(count: 12)) { $0 % 4 == 0 ? Int64(1000 + $0) : -1 }
        #expect(videos.count == 12)
        #expect(videos.first?.isSync == true)
        let link = RecordingLink()
        let session = PlayerSession(link: link, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        videos.forEach(session.video)
        session.waitUntilIdle()

        let calls = link.decodedCalls
        #expect(calls.map(\.frame) == videos.map(\.frame))
        #expect(calls.map(\.token) == videos.map(\.envelope.ltrToken))
        #expect(zip(calls, videos).allSatisfy { $0.at >= $1.completedNs })
        #expect(link.refreshCount == 0)
        let stats = session.stats
        #expect(stats.decoded == 12)
        #expect(stats.decodeErrors == 0)
        #expect(stats.missing == 0)
        #expect(stats.delayedOutputs == 0)
        #expect(stats.sessionsCreated == 1)
        #expect(stats.width == 128 && stats.height == 72)
        #expect(stats.presentToDecoded.measured == 12)
        #expect(stats.decodeTime.measured == 12)
        #expect(stats.waitingForKeyFrame == false)
        let snapshot = try #require(session.snapshot())
        #expect(snapshot.frame == videos.last?.frame)
        #expect(snapshot.image.width == 128)
    }

    @Test func aDecodeErrorAsksForARefreshAndSkipsToTheNextKeyFrame() throws {
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        var videos = wire.send(try encoder.encode(count: 3))
        let sets = try #require(videos.first?.parameterSets)
        videos += wire.send(sets: sets, accessUnit: Data(), sync: false)
        videos += wire.send(try encoder.encode(count: 2, firstKey: false))
        videos += wire.send(try encoder.encode(key: true))
        videos += wire.send(try encoder.encode())
        #expect(videos.count == 8)
        let link = RecordingLink()
        let session = PlayerSession(link: link, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        videos.forEach(session.video)
        session.waitUntilIdle()

        #expect(link.decodedCalls.map(\.frame) == [videos[0], videos[1], videos[2], videos[6], videos[7]].map(\.frame))
        #expect(link.refreshCount == 1)
        let stats = session.stats
        #expect(stats.decodeErrors == 1)
        #expect(stats.lastError == .emptyAccessUnit)
        #expect(stats.skipped == 2)
        #expect(stats.missing == 3)
        #expect(stats.longestMissingRun == 3)
        #expect(stats.presentToDecoded.missing == 3)
        #expect(stats.presentToDecoded.count == 8)
    }

    @Test func aHoleInTheFramesIsNeverDecodedAgainst() throws {
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        let videos = wire.send(try encoder.encode(count: 5)) + wire.send(try encoder.encode(key: true))
        let link = RecordingLink()
        let session = PlayerSession(link: link, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        for (index, video) in videos.enumerated() where index != 2 { session.video(video) }
        session.waitUntilIdle()

        #expect(link.decodedCalls.map(\.frame) == [videos[0].frame, videos[1].frame, videos[5].frame])
        #expect(link.refreshCount == 1)
        let stats = session.stats
        #expect(stats.decodeErrors == 0)
        #expect(stats.skipped == 2)
        #expect(stats.missing == 3)
        #expect(stats.refreshRequests == 1)
    }

    @Test func aRefreshFrameResumesWithTheReferencesTheDecoderKept() throws {
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        let first = try encoder.encode(count: 3)
        let lost = try encoder.encode()
        let refresh = try encoder.encode()
        let videos = wire.send(first) + wire.send(lost) + wire.send(refresh, refresh: true)
        let link = RecordingLink()
        let session = PlayerSession(link: link, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        #expect(videos[4].isRefresh)
        for index in [0, 1, 2, 4] { session.video(videos[index]) }
        session.waitUntilIdle()
        let stats = session.stats
        #expect(stats.skipped == 0)
        #expect(stats.missing == 1 + stats.decodeErrors)
        #expect(UInt64(link.decodedCalls.count) + stats.decodeErrors == 4)
        #expect(link.refreshCount == Int(stats.decodeErrors))
    }

    @Test func newParameterSetsBringANewDecoderSession() throws {
        let large = try SyntheticEncoder(width: 128, height: 72)
        let small = try SyntheticEncoder(width: 96, height: 64)
        var wire = Wire()
        let videos = wire.send(try large.encode(count: 3)) + wire.send(try small.encode(count: 3))
        #expect(videos.map(\.generation) == [1, 1, 1, 2, 2, 2])
        let link = RecordingLink()
        let session = PlayerSession(link: link, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        videos.forEach(session.video)
        session.waitUntilIdle()
        let stats = session.stats
        #expect(stats.decoded == 6)
        #expect(stats.sessionsCreated == 2)
        #expect(stats.width == 96 && stats.height == 64)
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)))
    func decodesHEVC() throws {
        let encoder = try SyntheticEncoder(width: 256, height: 144, codec: kCMVideoCodecType_HEVC)
        var wire = Wire()
        let frames = try encoder.encode(count: 4)
        #expect(VideoCodec.detect(frames[0].sets) == .hevc)
        let videos = wire.send(frames)
        let link = RecordingLink()
        let session = PlayerSession(link: link, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        videos.forEach(session.video)
        session.waitUntilIdle()
        #expect(session.stats.decoded == 4)
        #expect(session.stats.width == 256)
    }

    @Test func aLinkClientCountsWhatTheSessionDecoded() throws {
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        let videos = wire.send(try encoder.encode(count: 3))
        let client = LinkClient(identity: LinkIdentity(), settings: LinkClientSettings(name: "Test"), knownHub: { _ in nil }) { _ in }
        let session = PlayerSession(client: client, settings: PlayerSettings(audio: false))
        defer { session.stop() }
        videos.forEach(session.video)
        session.waitUntilIdle()
        #expect(client.stats.decodedFrames == 3)
        let stats = session.stats
        #expect(stats.link?.decodedFrames == 3)
        #expect(stats.withoutClock == 3)
        #expect(stats.presentToDecoded.measured == 0)
    }

    @Test func writesOneTSVLinePerFrame() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("frames.tsv").path
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        var videos = wire.send(try encoder.encode(count: 4))
        videos += wire.send(sets: videos[0].parameterSets, accessUnit: Data(), sync: false)
        let session = PlayerSession(link: RecordingLink(offsetNs: 1_000_000), settings: PlayerSettings(tsvPath: path, audio: false))
        videos.forEach(session.video)
        session.waitUntilIdle()
        session.stop()

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.count == 6)
        #expect(lines.allSatisfy { $0.count == 17 })
        #expect(lines.first?.first == "link")
        #expect(lines.dropFirst().map { String($0[11]) } == ["decoded", "decoded", "decoded", "decoded", "error"])
        #expect(lines.dropFirst().map { String($0[10]) }.allSatisfy { $0 == "1000000" })
        #expect(lines[1][2] == "sc")
        let decodedMs = try #require(Double(String(lines[1][14])))
        #expect(decodedMs >= 1 && decodedMs < 1000)
    }

    @MainActor @Test func framesOnScreenAreMarkedAtTheNextVsync() throws {
        let encoder = try SyntheticEncoder(width: 128, height: 72)
        var wire = Wire()
        let videos = wire.send(try encoder.encode(count: 3))
        let session = PlayerSession(link: RecordingLink(), settings: PlayerSettings(audio: false))
        defer { session.stop() }
        session.setVsyncActive(true)
        let layer = AVSampleBufferDisplayLayer()
        session.attach(layer.sampleBufferRenderer)
        videos.forEach(session.video)
        session.waitUntilIdle()
        session.vsync(targetNs: LinkClock.nowNs() + 16_000_000)
        let stats = session.stats
        #expect(stats.displayed == 1)
        #expect(stats.replaced == 2)
        #expect(stats.presentToDisplayed.measured == 1)
    }
}

struct VideoDecoderTests {
    @Test func warmsUpWithItsOwnParameterSets() {
        #expect(VideoDecoder.warmUp())
    }

    @Test func detectsTheCodecFromTheParameterSets() {
        #expect(VideoCodec.detect([Data([0x67, 0x42]), Data([0x68, 0xCE])]) == .h264)
        #expect(VideoCodec.detect([Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])]) == .hevc)
        #expect(VideoCodec.detect([Data([0x65])]) == nil)
        #expect(VideoDecoder.stripStartCode(Data([0, 0, 0, 1, 0x67])) == Data([0x67]))
        #expect(VideoDecoder.stripStartCode(Data([0, 0, 1, 0x68])) == Data([0x68]))
    }
}
