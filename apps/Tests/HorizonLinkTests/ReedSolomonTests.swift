import Foundation
import Testing
import HorizonLink

struct FECRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func data(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            var word = next()
            for _ in 0..<min(8, count - offset) {
                bytes[offset] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                offset += 1
            }
        }
        return Data(bytes)
    }
}

struct ReedSolomonTests {
    private func shardSet(_ code: ReedSolomon, data: [Data], parity: [Data], erasing erased: Set<Int>) -> [Int: Data] {
        var shards: [Int: Data] = [:]
        for (index, shard) in (data + parity).enumerated() where !erased.contains(index) { shards[index] = shard }
        return shards
    }

    private static func referenceMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = UInt16(a)
        var b = b
        var product: UInt16 = 0
        while b != 0 {
            if b & 1 != 0 { product ^= a }
            a <<= 1
            if a & 0x100 != 0 { a ^= 0x11D }
            b >>= 1
        }
        return UInt8(product)
    }

    private static func referenceInverse(_ value: UInt8) -> UInt8 {
        UInt8((1...255).first { referenceMultiply(value, UInt8($0)) == 1 }!)
    }

    @Test func theCodeAcceptsOneTo255DataShards() throws {
        #expect(throws: ReedSolomonError.unsupportedDataCount(0)) { try ReedSolomon(dataCount: 0) }
        #expect(throws: ReedSolomonError.unsupportedDataCount(256)) { try ReedSolomon(dataCount: 256) }
        #expect(try ReedSolomon(dataCount: 48).maxParityCount == 208)
        #expect(try ReedSolomon(dataCount: 1).maxParityCount == 255)
        #expect(try ReedSolomon(dataCount: 255).maxParityCount == 1)
    }

    @Test func parityMatchesTheNormalizedCauchyMatrixOver0x11D() throws {
        var random = FECRandom(seed: 1)
        for dataCount in [1, 2, 5, 48] {
            let code = try ReedSolomon(dataCount: dataCount)
            let data = (0..<dataCount).map { _ in random.data(9) }
            let rows = [0, 1, 7, code.maxParityCount - 1]
            let parity = code.parity(indices: rows, data: data)
            for (row, shard) in zip(rows, parity) {
                var expected = [UInt8](repeating: 0, count: 9)
                for column in 0..<dataCount {
                    let cauchy = Self.referenceInverse(UInt8((dataCount + row) ^ column))
                    let coefficient = Self.referenceMultiply(cauchy, UInt8(dataCount ^ column))
                    for byte in 0..<9 { expected[byte] ^= Self.referenceMultiply(coefficient, data[column][byte]) }
                }
                #expect(Array(shard) == expected)
            }
            #expect(parity[0] == data.dropFirst().reduce(data[0]) { Data(zip($0, $1).map { $0 ^ $1 }) })
        }
    }

    @Test func everyErasurePatternUpToTheParityCountIsRecovered() throws {
        var random = FECRandom(seed: 2)
        for (dataCount, parityCount) in [(1, 1), (1, 3), (2, 2), (3, 3), (4, 3), (5, 4), (8, 4)] {
            let code = try ReedSolomon(dataCount: dataCount)
            let data = (0..<dataCount).map { _ in random.data(37) }
            let parity = code.parity(indices: 0..<parityCount, data: data)
            let total = dataCount + parityCount
            var patterns = 0
            for mask in 0..<(1 << total) where mask.nonzeroBitCount <= parityCount {
                let erased = Set((0..<total).filter { mask & (1 << $0) != 0 })
                let rebuilt = try code.reconstruct(shardSet(code, data: data, parity: parity, erasing: erased), shardSize: 37)
                #expect(rebuilt == data, "k=\(dataCount) m=\(parityCount) erased \(erased.sorted())")
                patterns += 1
            }
            #expect(patterns == (0...parityCount).reduce(0) { sum, erasures in
                sum + (0..<erasures).reduce(1) { $0 * (total - $1) / ($1 + 1) }
            })
        }
    }

    @Test func randomErasuresOfA48By12BlockAreRecovered() throws {
        var random = FECRandom(seed: 3)
        let code = try ReedSolomon(dataCount: 48)
        let data = (0..<48).map { _ in random.data(101) }
        let parity = code.parity(indices: 0..<12, data: data)
        for trial in 0..<200 {
            let erasures = trial < 150 ? 12 : Int.random(in: 1...11, using: &random)
            let erased = Set(Array(0..<60).shuffled(using: &random).prefix(erasures))
            let rebuilt = try code.reconstruct(shardSet(code, data: data, parity: parity, erasing: erased), shardSize: 101)
            #expect(rebuilt == data, "erased \(erased.sorted())")
        }
    }

    @Test func oneErasureTooManyFailsCleanly() throws {
        var random = FECRandom(seed: 4)
        let code = try ReedSolomon(dataCount: 48)
        let data = (0..<48).map { _ in random.data(16) }
        let parity = code.parity(indices: 0..<12, data: data)
        let shards = shardSet(code, data: data, parity: parity, erasing: Set(0..<13))
        #expect(throws: ReedSolomonError.tooFewShards(have: 47, need: 48)) {
            try code.reconstruct(shards, shardSize: 16)
        }
        #expect(throws: ReedSolomonError.tooFewShards(have: 0, need: 48)) { try code.reconstruct([:], shardSize: 16) }
    }

    @Test func malformedShardsAreRejected() throws {
        let code = try ReedSolomon(dataCount: 2)
        #expect(throws: ReedSolomonError.shardOutOfRange(256)) {
            try code.reconstruct([0: Data(count: 4), 256: Data(count: 4)], shardSize: 4)
        }
        #expect(throws: ReedSolomonError.shardOutOfRange(-1)) {
            try code.reconstruct([0: Data(count: 4), -1: Data(count: 4)], shardSize: 4)
        }
        #expect(throws: ReedSolomonError.shardSizeMismatch(index: 1, expected: 4, actual: 3)) {
            try code.reconstruct([0: Data(count: 4), 1: Data(count: 3)], shardSize: 4)
        }
    }

    @Test func parityRowsGeneratedLaterWorkWithEarlierOnes() throws {
        var random = FECRandom(seed: 5)
        let code = try ReedSolomon(dataCount: 48)
        let data = (0..<48).map { _ in random.data(1156) }
        let early = code.parity(indices: 0..<4, data: data)
        let late = code.parity(indices: 4..<10, data: data)
        #expect(code.parity(indices: 0..<10, data: data) == early + late)
        #expect(code.parity(index: 7, data: data) == late[3])
        let sparse = [200, 13, 150, 207]
        var shards: [Int: Data] = [:]
        for column in 14..<48 { shards[column] = data[column] }
        for (row, shard) in zip(0..<10, early + late) { shards[48 + row] = shard }
        for (row, shard) in zip(sparse, code.parity(indices: sparse, data: data)) { shards[48 + row] = shard }
        #expect(try code.reconstruct(shards, shardSize: 1156) == data)
    }

    @Test func slicedShardsAndTheWidestCodeWork() throws {
        var random = FECRandom(seed: 6)
        let code = try ReedSolomon(dataCount: 255)
        let backing = random.data(255 * 24 + 5)
        let data = (0..<255).map { backing.dropFirst(5 + $0 * 24).prefix(24) }
        let parity = code.parity(index: 0, data: data)
        var shards: [Int: Data] = [255: parity]
        for column in 0..<255 where column != 77 { shards[column] = data[column] }
        let rebuilt = try code.reconstruct(shards, shardSize: 24)
        #expect(rebuilt.map { Array($0) } == data.map { Array($0) })
    }
}
