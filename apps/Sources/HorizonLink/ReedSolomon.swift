import Foundation

public enum ReedSolomonError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedDataCount(Int)
    case tooFewShards(have: Int, need: Int)
    case shardOutOfRange(Int)
    case shardSizeMismatch(index: Int, expected: Int, actual: Int)
    case singularMatrix

    public var description: String {
        switch self {
        case .unsupportedDataCount(let count): "a Reed-Solomon block needs 1 to 255 data shards, not \(count)"
        case .tooFewShards(let have, let need): "\(have) shards cannot rebuild a block of \(need) data shards"
        case .shardOutOfRange(let index): "shard \(index) is outside the code"
        case .shardSizeMismatch(let index, let expected, let actual): "shard \(index) has \(actual) bytes instead of \(expected)"
        case .singularMatrix: "the decoding matrix is singular"
        }
    }
}

public struct ReedSolomon: Sendable {
    public static let maxShards = 256

    public let dataCount: Int

    public init(dataCount: Int) throws {
        guard (1..<Self.maxShards).contains(dataCount) else { throw ReedSolomonError.unsupportedDataCount(dataCount) }
        self.dataCount = dataCount
    }

    public var maxParityCount: Int { Self.maxShards - dataCount }

    public func parity(index: Int, data: [Data]) -> Data {
        parity(indices: CollectionOfOne(index), data: data)[0]
    }

    public func parity(indices: some Sequence<Int>, data: [Data]) -> [Data] {
        let rows = Array(indices)
        precondition(data.count == dataCount, "parity needs \(dataCount) data shards, got \(data.count)")
        precondition(rows.allSatisfy { (0..<maxParityCount).contains($0) }, "parity rows must be in 0..<\(maxParityCount)")
        let size = data[0].count
        precondition(data.allSatisfy { $0.count == size }, "data shards must have equal length")
        var coefficients: [UInt8] = []
        coefficients.reserveCapacity(dataCount * rows.count)
        for column in 0..<dataCount {
            for row in rows { coefficients.append(coefficient(row: row, column: column)) }
        }
        return Galois.combine(data, coefficients: coefficients, outputs: rows.count, size: size)
    }

    public func reconstruct(_ shards: [Int: Data], shardSize: Int) throws -> [Data] {
        for (index, shard) in shards {
            guard (0..<Self.maxShards).contains(index) else { throw ReedSolomonError.shardOutOfRange(index) }
            guard shard.count == shardSize else {
                throw ReedSolomonError.shardSizeMismatch(index: index, expected: shardSize, actual: shard.count)
            }
        }
        guard shards.count >= dataCount else { throw ReedSolomonError.tooFewShards(have: shards.count, need: dataCount) }
        let lost = (0..<dataCount).filter { shards[$0] == nil }
        guard !lost.isEmpty else { return (0..<dataCount).map { shards[$0]! } }
        let rows = shards.keys.filter { $0 >= dataCount }.sorted().prefix(lost.count).map { $0 - dataCount }
        let count = lost.count
        var square = [UInt8](repeating: 0, count: count * count)
        for (r, row) in rows.enumerated() {
            for (c, column) in lost.enumerated() { square[r * count + c] = coefficient(row: row, column: column) }
        }
        let inverse = try Galois.invert(square, size: count)
        var inputs: [Data] = []
        var coefficients: [UInt8] = []
        inputs.reserveCapacity(dataCount)
        coefficients.reserveCapacity(dataCount * count)
        for (r, row) in rows.enumerated() {
            inputs.append(shards[dataCount + row]!)
            for c in 0..<count { coefficients.append(inverse[c * count + r]) }
        }
        for column in 0..<dataCount {
            guard let shard = shards[column] else { continue }
            inputs.append(shard)
            let known = rows.map { coefficient(row: $0, column: column) }
            for c in 0..<count {
                var sum: UInt8 = 0
                for r in 0..<count { sum ^= Galois.multiply(inverse[c * count + r], known[r]) }
                coefficients.append(sum)
            }
        }
        var rebuilt = Galois.combine(inputs, coefficients: coefficients, outputs: count, size: shardSize).makeIterator()
        return (0..<dataCount).map { shards[$0] ?? rebuilt.next()! }
    }

    private func coefficient(row: Int, column: Int) -> UInt8 {
        Galois.multiply(Galois.inverse(UInt8((dataCount + row) ^ column)), UInt8(dataCount ^ column))
    }
}

enum Galois {
    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 510)
        var log = [UInt8](repeating: 0, count: 256)
        var value = 1
        for power in 0..<255 {
            exp[power] = UInt8(value)
            exp[power + 255] = UInt8(value)
            log[value] = UInt8(power)
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        return (exp, log)
    }()

    static let products: [UInt8] = {
        let (exp, log) = tables
        var table = [UInt8](repeating: 0, count: 65536)
        for a in 1..<256 {
            for b in 1..<256 { table[a << 8 | b] = exp[Int(log[a]) + Int(log[b])] }
        }
        return table
    }()

    private static let inverses: [UInt8] = {
        let (exp, log) = tables
        return (0..<256).map { $0 == 0 ? 0 : exp[255 - Int(log[$0])] }
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 { products[Int(a) << 8 | Int(b)] }

    static func inverse(_ value: UInt8) -> UInt8 { inverses[Int(value)] }

    static func invert(_ matrix: [UInt8], size: Int) throws -> [UInt8] {
        var work = matrix
        var result = [UInt8](repeating: 0, count: size * size)
        for i in 0..<size { result[i * size + i] = 1 }
        for column in 0..<size {
            guard let pivot = (column..<size).first(where: { work[$0 * size + column] != 0 }) else {
                throw ReedSolomonError.singularMatrix
            }
            if pivot != column {
                for c in 0..<size {
                    work.swapAt(pivot * size + c, column * size + c)
                    result.swapAt(pivot * size + c, column * size + c)
                }
            }
            let scale = inverse(work[column * size + column])
            for c in 0..<size {
                work[column * size + c] = multiply(work[column * size + c], scale)
                result[column * size + c] = multiply(result[column * size + c], scale)
            }
            for r in 0..<size where r != column {
                let factor = work[r * size + column]
                guard factor != 0 else { continue }
                for c in 0..<size {
                    work[r * size + c] ^= multiply(factor, work[column * size + c])
                    result[r * size + c] ^= multiply(factor, result[column * size + c])
                }
            }
        }
        return result
    }

    static func combine(_ inputs: [Data], coefficients: [UInt8], outputs: Int, size: Int) -> [Data] {
        guard outputs > 0 else { return [] }
        guard size > 0 else { return Array(repeating: Data(), count: outputs) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: outputs * size, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: outputs * size)
        products.withUnsafeBufferPointer { table in
            let base = table.baseAddress!
            for (input, data) in inputs.enumerated() {
                data.withUnsafeBytes { source in
                    let pointer = source.baseAddress!
                    for output in 0..<outputs {
                        let coefficient = coefficients[input * outputs + output]
                        let target = buffer + output * size
                        switch coefficient {
                        case 0: break
                        case 1: add(pointer, into: target, count: size)
                        default: multiplyAdd(base + Int(coefficient) << 8, pointer, into: target, count: size)
                        }
                    }
                }
            }
        }
        return (0..<outputs).map { Data(bytes: buffer + $0 * size, count: size) }
    }

    @inline(__always)
    private static func add(_ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, count: Int) {
        var offset = 0
        while offset &+ 8 <= count {
            let value = source.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            let current = target.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            target.storeBytes(of: current ^ value, toByteOffset: offset, as: UInt64.self)
            offset &+= 8
        }
        while offset < count {
            let value = source.load(fromByteOffset: offset, as: UInt8.self)
            let current = target.load(fromByteOffset: offset, as: UInt8.self)
            target.storeBytes(of: current ^ value, toByteOffset: offset, as: UInt8.self)
            offset &+= 1
        }
    }

    @inline(__always)
    private static func multiplyAdd(
        _ row: UnsafePointer<UInt8>, _ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, count: Int
    ) {
        var offset = 0
        while offset &+ 8 <= count {
            let word = source.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            let product = UInt64(row[Int(truncatingIfNeeded: word & 0xFF)])
                | UInt64(row[Int(truncatingIfNeeded: word &>> 8 & 0xFF)]) &<< 8
                | UInt64(row[Int(truncatingIfNeeded: word &>> 16 & 0xFF)]) &<< 16
                | UInt64(row[Int(truncatingIfNeeded: word &>> 24 & 0xFF)]) &<< 24
                | UInt64(row[Int(truncatingIfNeeded: word &>> 32 & 0xFF)]) &<< 32
                | UInt64(row[Int(truncatingIfNeeded: word &>> 40 & 0xFF)]) &<< 40
                | UInt64(row[Int(truncatingIfNeeded: word &>> 48 & 0xFF)]) &<< 48
                | UInt64(row[Int(truncatingIfNeeded: word &>> 56)]) &<< 56
            let current = target.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            target.storeBytes(of: current ^ product, toByteOffset: offset, as: UInt64.self)
            offset &+= 8
        }
        while offset < count {
            let value = source.load(fromByteOffset: offset, as: UInt8.self)
            let current = target.load(fromByteOffset: offset, as: UInt8.self)
            target.storeBytes(of: current ^ row[Int(value)], toByteOffset: offset, as: UInt8.self)
            offset &+= 1
        }
    }
}
