import CoreMedia
import Darwin
import Foundation

struct NALUnit: Sendable {
    let offset: Int
    let length: Int
    let type: UInt8
}

final class Recording {
    let path: String
    let size: Int
    let bytes: UnsafePointer<UInt8>
    let firstNAL: Int
    let sps: NALUnit
    let pps: NALUnit
    let format: CMVideoFormatDescription
    let width: Int
    let height: Int

    init(path: String) throws {
        self.path = path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FakeStreamError("cannot open the recording \(path) (\(String(cString: strerror(errno))))") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 8 else { throw FakeStreamError("the recording \(path) is empty") }
        let size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw FakeStreamError("cannot map the recording \(path) (\(String(cString: strerror(errno))))")
        }
        let bytes = UnsafePointer(mapped.assumingMemoryBound(to: UInt8.self))
        guard let code = Self.startCode(in: bytes, size: size, from: 0) else {
            munmap(mapped, size)
            throw FakeStreamError("the recording \(path) has no Annex B start code")
        }
        var position = code + 3
        var sps: NALUnit?
        var pps: NALUnit?
        for _ in 0..<256 where sps == nil || pps == nil {
            guard let (unit, next) = Self.nal(in: bytes, size: size, at: position) else { break }
            if unit.type == 7 && sps == nil { sps = unit }
            if unit.type == 8 && pps == nil { pps = unit }
            position = next
        }
        guard let sps, let pps, let format = Self.format(bytes: bytes, sps: sps, pps: pps) else {
            munmap(mapped, size)
            throw FakeStreamError("the recording \(path) has no usable H.264 SPS and PPS at its start")
        }
        let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: false, useCleanAperture: true)
        self.size = size
        self.bytes = bytes
        self.firstNAL = code + 3
        self.sps = sps
        self.pps = pps
        self.format = format
        self.width = Int(dimensions.width)
        self.height = Int(dimensions.height)
    }

    static func startCode(in bytes: UnsafePointer<UInt8>, size: Int, from position: Int) -> Int? {
        guard position + 3 <= size else { return nil }
        var needle: (UInt8, UInt8, UInt8) = (0, 0, 1)
        let hit = withUnsafeBytes(of: &needle) { memmem(bytes + position, size - position, $0.baseAddress, 3) }
        guard let hit else { return nil }
        return UnsafeRawPointer(bytes).distance(to: UnsafeRawPointer(hit))
    }

    static func nal(in bytes: UnsafePointer<UInt8>, size: Int, at position: Int) -> (NALUnit, Int)? {
        var start = position
        while start < size {
            let code = startCode(in: bytes, size: size, from: start)
            var end = code ?? size
            let next = code.map { $0 + 3 } ?? size
            while end > start && bytes[end - 1] == 0 { end -= 1 }
            if end > start { return (NALUnit(offset: start, length: end - start, type: bytes[start] & 0x1F), next) }
            start = next
        }
        return nil
    }

    static func format(bytes: UnsafePointer<UInt8>, sps: NALUnit, pps: NALUnit) -> CMVideoFormatDescription? {
        let pointers = [bytes + sps.offset, bytes + pps.offset]
        let sizes = [sps.length, pps.length]
        var format: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer -> OSStatus in
            sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                guard let pointerBase = pointerBuffer.baseAddress, let sizeBase = sizeBuffer.baseAddress else { return -1 }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointerBase,
                    parameterSetSizes: sizeBase, nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        return status == noErr ? format : nil
    }

    func same(_ left: NALUnit, _ right: NALUnit) -> Bool {
        left.length == right.length && memcmp(bytes + left.offset, bytes + right.offset, left.length) == 0
    }
}

struct AccessUnitReader {
    let recording: Recording
    private var position: Int
    private var pending: NALUnit?
    private var frames = 0

    init(recording: Recording) {
        self.recording = recording
        position = recording.firstNAL
    }

    mutating func next() -> (units: [NALUnit], loopedAfter: Int?) {
        var units: [NALUnit] = []
        var sawPicture = false
        var loopedAfter: Int?
        while true {
            let unit: NALUnit
            if let pending {
                unit = pending
                self.pending = nil
            } else if let (found, next) = Recording.nal(in: recording.bytes, size: recording.size, at: position) {
                unit = found
                position = next
            } else {
                if !units.isEmpty {
                    frames += 1
                    return (units, loopedAfter)
                }
                loopedAfter = frames
                frames = 0
                position = recording.firstNAL
                continue
            }
            if sawPicture && startsAccessUnit(unit) {
                pending = unit
                frames += 1
                return (units, loopedAfter)
            }
            units.append(unit)
            if unit.type == 1 || unit.type == 5 { sawPicture = true }
        }
    }

    private func startsAccessUnit(_ unit: NALUnit) -> Bool {
        switch unit.type {
        case 6, 7, 8, 9, 14...18: true
        case 1, 5: unit.length > 1 && recording.bytes[unit.offset + 1] & 0x80 != 0
        default: false
        }
    }
}
