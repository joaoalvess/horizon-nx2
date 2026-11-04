import Foundation
import HorizonLink

public enum FrameStatus: String, Sendable {
    case decoded
    case skipped
    case error
    case late
}

struct FrameRow: Sendable {
    var link: UInt32
    var dmFrame: UInt64
    var flags: UInt8
    var bytes: Int
    var presentNs: UInt64
    var firstShardNs: UInt64
    var completedNs: UInt64
    var decodeStartNs: UInt64?
    var decodeEndNs: UInt64?
    var displayedNs: UInt64?
    var offsetNs: Int64?
    var status: FrameStatus

    func latency(to clientNs: UInt64?) -> Double? {
        guard let clientNs, let offsetNs else { return nil }
        let present = Int64(bitPattern: presentNs &- UInt64(bitPattern: offsetNs))
        return Double(Int64(bitPattern: clientNs) - present) / 1e6
    }

    var decodeMs: Double? {
        guard let start = decodeStartNs, let end = decodeEndNs else { return nil }
        return Double(end &- start) / 1e6
    }

    static let header = [
        "link", "dm", "flags", "bytes", "present_ns", "first_shard_ns", "completed_ns", "decode_start_ns", "decode_end_ns",
        "displayed_ns", "offset_ns", "status", "shard_ms", "completed_ms", "decoded_ms", "displayed_ms", "decode_ms",
    ].joined(separator: "\t") + "\n"

    var line: String {
        var flagText = ""
        if flags & VideoFlags.sync != 0 { flagText += "s" }
        if flags & VideoFlags.refresh != 0 { flagText += "r" }
        if flags & VideoFlags.config != 0 { flagText += "c" }
        let fields: [String] = [
            String(link), String(dmFrame), flagText.isEmpty ? "-" : flagText, String(bytes), String(presentNs), String(firstShardNs),
            String(completedNs), Self.text(decodeStartNs), Self.text(decodeEndNs), Self.text(displayedNs), offsetNs.map(String.init) ?? "-",
            status.rawValue, Self.text(latency(to: firstShardNs)), Self.text(latency(to: completedNs)), Self.text(latency(to: decodeEndNs)),
            Self.text(latency(to: displayedNs)), Self.text(decodeMs),
        ]
        return fields.joined(separator: "\t") + "\n"
    }

    private static func text(_ value: UInt64?) -> String { value.map(String.init) ?? "-" }

    private static func text(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
}

final class FrameLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.player.tsv", qos: .utility)
    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false

    init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        guard FileManager.default.createFile(atPath: path, contents: Data(FrameRow.header.utf8)),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    func write(_ row: FrameRow) {
        queue.async { [self] in
            guard !closed else { return }
            buffer.append(Data(row.line.utf8))
            if buffer.count >= 64 * 1024 { flush() }
        }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            flush()
            closed = true
            try? handle.close()
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
