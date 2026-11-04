import Foundation

public struct ClockSample: Sendable, Equatable {
    public let clientSendNs: UInt64
    public let hubReceiveNs: UInt64
    public let hubSendNs: UInt64
    public let clientReceiveNs: UInt64

    public init(clientSendNs: UInt64, hubReceiveNs: UInt64, hubSendNs: UInt64, clientReceiveNs: UInt64) {
        self.clientSendNs = clientSendNs
        self.hubReceiveNs = hubReceiveNs
        self.hubSendNs = hubSendNs
        self.clientReceiveNs = clientReceiveNs
    }

    public var roundTripNs: Int64 {
        Int64(bitPattern: clientReceiveNs &- clientSendNs) - Int64(bitPattern: hubSendNs &- hubReceiveNs)
    }

    public var offsetNs: Int64 {
        let outbound = Int64(bitPattern: hubReceiveNs &- clientSendNs)
        let inbound = Int64(bitPattern: hubSendNs &- clientReceiveNs)
        return (outbound + inbound) / 2
    }
}

public struct ClockSync: Sendable {
    public let windowNs: UInt64
    private var samples: [ClockSample] = []

    public init(window: TimeInterval = 10) {
        windowNs = UInt64(window * 1e9)
    }

    public mutating func add(_ sample: ClockSample) {
        guard sample.roundTripNs >= 0 else { return }
        samples.append(sample)
        let horizon = sample.clientReceiveNs > windowNs ? sample.clientReceiveNs - windowNs : 0
        samples.removeAll { $0.clientReceiveNs < horizon }
    }

    public var best: ClockSample? { samples.min { $0.roundTripNs < $1.roundTripNs } }

    public var offsetNs: Int64? { best?.offsetNs }

    public var roundTripNs: Int64? { best?.roundTripNs }

    public func hubTime(clientNs: UInt64) -> UInt64? {
        offsetNs.map { clientNs &+ UInt64(bitPattern: $0) }
    }

    public func clientTime(hubNs: UInt64) -> UInt64? {
        offsetNs.map { hubNs &- UInt64(bitPattern: $0) }
    }
}
