import Foundation

public struct LatencyHistogram: Sendable, Equatable {
    public static let resolutionMs = 0.1
    public static let rangeMs = 1000.0
    static let bucketCount = Int(rangeMs / resolutionMs)

    private var buckets: [UInt32] = []
    public private(set) var measured: UInt64 = 0
    public private(set) var overflow: UInt64 = 0
    public private(set) var totalMs: Double = 0
    public var missing: UInt64 = 0

    public init() {}

    public var count: UInt64 { measured + missing }

    public var isEmpty: Bool { count == 0 }

    public mutating func add(_ ms: Double) {
        guard ms.isFinite else {
            missing += 1
            return
        }
        let value = max(0, ms)
        measured += 1
        totalMs += value
        let index = Int(value / Self.resolutionMs)
        guard index < Self.bucketCount else {
            overflow += 1
            return
        }
        if buckets.isEmpty { buckets = Array(repeating: 0, count: Self.bucketCount) }
        buckets[index] &+= 1
    }

    public var meanMs: Double? { measured == 0 ? nil : totalMs / Double(measured) }

    public var p50: Double? { percentile(0.50) }
    public var p95: Double? { percentile(0.95) }
    public var p99: Double? { percentile(0.99) }

    public var maxMs: Double? {
        if overflow > 0 { return Self.rangeMs }
        guard let index = buckets.lastIndex(where: { $0 > 0 }) else { return nil }
        return Double(index + 1) * Self.resolutionMs
    }

    public func percentile(_ fraction: Double) -> Double? {
        let total = count
        guard total > 0 else { return nil }
        let rank = max(1, UInt64((min(max(fraction, 0), 1) * Double(total)).rounded(.up)))
        var seen: UInt64 = 0
        for (index, bucket) in buckets.enumerated() where bucket > 0 {
            seen += UInt64(bucket)
            if seen >= rank { return Double(index + 1) * Self.resolutionMs }
        }
        seen += overflow
        if seen >= rank { return Self.rangeMs }
        return .infinity
    }

    public func fraction(above ms: Double) -> Double? {
        let total = count
        guard total > 0 else { return nil }
        let limit = Int(max(0, ms) / Self.resolutionMs)
        var above = overflow + missing
        if limit < buckets.count {
            above += buckets[limit...].reduce(UInt64(0)) { $0 + UInt64($1) }
        }
        return Double(above) / Double(total)
    }

    public static func + (left: LatencyHistogram, right: LatencyHistogram) -> LatencyHistogram {
        var sum = left
        sum.measured += right.measured
        sum.overflow += right.overflow
        sum.totalMs += right.totalMs
        sum.missing += right.missing
        if !right.buckets.isEmpty {
            if sum.buckets.isEmpty { sum.buckets = Array(repeating: 0, count: bucketCount) }
            for index in right.buckets.indices { sum.buckets[index] &+= right.buckets[index] }
        }
        return sum
    }

    public static func - (left: LatencyHistogram, right: LatencyHistogram) -> LatencyHistogram {
        var difference = left
        difference.measured = left.measured >= right.measured ? left.measured - right.measured : 0
        difference.overflow = left.overflow >= right.overflow ? left.overflow - right.overflow : 0
        difference.totalMs = max(0, left.totalMs - right.totalMs)
        difference.missing = left.missing >= right.missing ? left.missing - right.missing : 0
        if !difference.buckets.isEmpty, !right.buckets.isEmpty {
            for index in right.buckets.indices {
                let value = difference.buckets[index]
                difference.buckets[index] = value >= right.buckets[index] ? value - right.buckets[index] : 0
            }
        }
        return difference
    }
}
