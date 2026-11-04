import Testing
@testable import HorizonPlayer

func close(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 1e-6 } ?? false
}

struct LatencyHistogramTests {
    @Test func missingFramesCountAboveEveryLimit() {
        var histogram = LatencyHistogram()
        for value in 1...98 { histogram.add(Double(value) / 10 - 0.05) }
        histogram.missing = 2
        #expect(histogram.count == 100)
        #expect(close(histogram.p50, 5.0))
        #expect(close(histogram.p95, 9.5))
        #expect(histogram.p99 == .infinity)
        #expect(close(histogram.fraction(above: 25), 0.02))
        #expect(close(histogram.fraction(above: 9.02), 0.10))
        #expect(close(histogram.maxMs, 9.8))
    }

    @Test func windowsAreDifferencesOfTotals() {
        var first = LatencyHistogram()
        first.add(3.05)
        first.add(4.05)
        var total = first
        total.add(20.05)
        total.add(30.05)
        total.missing = 1
        let window = total - first
        #expect(window.measured == 2)
        #expect(window.missing == 1)
        #expect(close(window.p50, 30.1))
        #expect((first + window).measured == total.measured)
        #expect(LatencyHistogram().p95 == nil)
        var huge = LatencyHistogram()
        huge.add(5000)
        #expect(huge.maxMs == LatencyHistogram.rangeMs)
    }
}
