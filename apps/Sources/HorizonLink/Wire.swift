import Foundation

public enum WireError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncated
    case invalid(String)

    public var description: String {
        switch self {
        case .truncated: "message truncated"
        case .invalid(let text): text
        }
    }
}

public struct ByteWriter: Sendable {
    public private(set) var data = Data()

    public init(capacity: Int = 64) {
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ value: UInt8) { data.append(value) }
    public mutating func u16(_ value: UInt16) { integer(value) }
    public mutating func u32(_ value: UInt32) { integer(value) }
    public mutating func u64(_ value: UInt64) { integer(value) }
    public mutating func i16(_ value: Int16) { integer(value) }
    public mutating func i64(_ value: Int64) { integer(value) }
    public mutating func f32(_ value: Float) { integer(value.bitPattern) }
    public mutating func bytes(_ value: some DataProtocol) { data.append(contentsOf: value) }
    public mutating func zeros(_ count: Int) { data.append(contentsOf: repeatElement(0 as UInt8, count: count)) }

    private mutating func integer<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

public struct ByteReader: Sendable {
    private let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    public mutating func i16() throws -> Int16 { try integer(Int16.self) }
    public mutating func i64() throws -> Int64 { try integer(Int64.self) }
    public mutating func f32() throws -> Float { Float(bitPattern: try integer(UInt32.self)) }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    public mutating func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        offset += count
    }

    public mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }

    private mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { buffer in
            _ = data.copyBytes(to: buffer, from: offset..<offset + size)
        }
        offset += size
        return T(littleEndian: value)
    }
}
