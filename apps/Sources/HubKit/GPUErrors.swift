import Foundation

public enum GPUFault: Sendable, Equatable {
    case own
    case victim(culprits: [String])
}

public enum GPUErrors {
    public static let reportDirectories = ["/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports/Retired"]
    public static let overlap = 64

    static let markers = [
        "kIOGPUCommandBufferCallbackError", "Caused GPU", "Ignored (for causing", "victim of GPU error", "IOGPUMetalError",
    ].map { Data($0.utf8) }
    static let codePrefix = "kIOGPUCommandBufferCallbackError"

    public static func firstMatch(in data: Data) -> Range<Data.Index>? {
        markers.compactMap { data.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    public static func matchingLines(in data: Data) -> [String] {
        data.split(separator: UInt8(ascii: "\n")).filter { line in
            markers.contains { line.range(of: $0) != nil }
        }.map { String(decoding: $0, as: UTF8.self) }
    }

    public static func isVictimOnly(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard !line.contains("Caused GPU"), !line.contains("Ignored (for causing") else { return false }
            guard line.contains("victim of GPU error") || line.contains("InnocentVictim") else { return false }
            return codes(in: line).allSatisfy { $0 == "InnocentVictim" }
        }
    }

    public static func classify(lines: [String], reportProcesses: [String], gameProcess: String) -> GPUFault {
        guard isVictimOnly(lines) else { return .own }
        let names = Set(reportProcesses)
        if names.contains(where: { $0 == gameProcess || $0.hasPrefix(gameProcess) || gameProcess.hasPrefix($0) }) { return .own }
        let others = names.subtracting(["WindowServer"])
        return others.isEmpty ? .own : .victim(culprits: others.sorted())
    }

    public static func reportProcesses(in directories: [String], from start: Date, to end: Date) -> [String] {
        var names: [String] = []
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for entry in entries where entry.hasPrefix("gpuEvent-") && entry.hasSuffix(".ips") {
                let path = directory + "/" + entry
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                    modified >= start, modified <= end
                else { continue }
                if let name = processName(path: path) ?? processName(fileName: entry) { names.append(name) }
            }
        }
        return names
    }

    static func processName(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let newline = data.firstIndex(of: UInt8(ascii: "\n")),
            let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        else { return nil }
        return body["process_name"] as? String
    }

    static func processName(fileName: String) -> String? {
        let stem = fileName.dropFirst("gpuEvent-".count)
        guard let range = stem.range(of: #"-\d{4}-\d{2}-\d{2}-"#, options: .regularExpression) else { return nil }
        return String(stem[..<range.lowerBound])
    }

    static func codes(in line: String) -> [String] {
        var result: [String] = []
        var rest = line[...]
        while let range = rest.range(of: codePrefix) {
            rest = rest[range.upperBound...]
            result.append(String(rest.prefix { $0.isLetter }))
        }
        return result
    }
}
