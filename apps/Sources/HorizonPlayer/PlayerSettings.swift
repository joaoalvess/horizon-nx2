import CoreGraphics
import Foundation
import HorizonLink

public struct PlayerSettings: Sendable {
    public var tsvPath: String?
    public var audio: Bool
    public var audioTargetMs: Double
    public var displayTimeoutMs: Double

    public init(tsvPath: String? = nil, audio: Bool = true, audioTargetMs: Double = 35, displayTimeoutMs: Double = 250) {
        self.tsvPath = tsvPath
        self.audio = audio
        self.audioTargetMs = audioTargetMs
        self.displayTimeoutMs = displayTimeoutMs
    }
}

public struct PlayerStats: Sendable, Equatable {
    public var fps: Double = 0
    public var received: UInt64 = 0
    public var decoded: UInt64 = 0
    public var displayed: UInt64 = 0
    public var replaced: UInt64 = 0
    public var skipped: UInt64 = 0
    public var late: UInt64 = 0
    public var missing: UInt64 = 0
    public var withoutClock: UInt64 = 0
    public var decodeErrors: UInt64 = 0
    public var refreshRequests: UInt64 = 0
    public var delayedOutputs: UInt64 = 0
    public var sessionsCreated = 0
    public var longestMissingRun: UInt64 = 0
    public var waitingForKeyFrame = true
    public var needsSyncFrame = true
    public var waitingSinceNs: UInt64?
    public var lastDecodedNs: UInt64?
    public var lastError: DecodeError?
    public var width = 0
    public var height = 0
    public var presentToDecoded = LatencyHistogram()
    public var presentToDisplayed = LatencyHistogram()
    public var decodeTime = LatencyHistogram()
    public var link: LinkClientStats?
    public var audio = AudioStats()

    public init() {}
}

public struct PlayerSnapshot: Sendable {
    public let frame: UInt32
    public let dmFrame: UInt64
    public let image: CGImage
}

protocol PlayerLink: AnyObject, Sendable {
    func decoded(frame: UInt32, ltrToken: Int64, at decodedNs: UInt64, decodeMicroseconds: UInt32)
    func requestRefresh()
    func clientTime(hubNs: UInt64) -> UInt64?
    var linkStats: LinkClientStats { get }
}

extension LinkClient: PlayerLink {
    var linkStats: LinkClientStats { stats }
}
