import Foundation

public struct GameBlock: Sendable, Equatable, Identifiable {
    public static let all = "STOP_ALL"

    public let name: String
    public let path: String
    public let text: String

    public var id: String { name }
    public var game: String? { name == Self.all ? nil : String(name.dropFirst(5)) }
}

public struct GuardState: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public var lockPath: String { directory + "/boot.lock" }
    public var eventsPath: String { directory + "/events.tsv" }

    public func stopPath(_ name: String) -> String { directory + "/" + name }

    public static func stopName(game: String) -> String { "STOP_" + game }

    public func blocks(for game: String) -> [GameBlock] {
        [GameBlock.all, Self.stopName(game: game)].compactMap(block)
    }

    public func allBlocks() -> [GameBlock] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("STOP_") && !$0.contains(".") }.sorted().compactMap(block)
    }

    public func ensureNotBlocked(game: String) throws {
        if let first = blocks(for: game).first {
            throw GamesError.blocked(name: first.name, text: first.text)
        }
    }

    public func writeStop(game: String, log: String, note: String, now: Date = Date()) throws {
        try write(Self.stopName(game: game), "\(Self.clock(now)) \(log): \(note)\n")
    }

    public func writeStopAll(why: String, game: String, now: Date = Date()) throws {
        try write(GameBlock.all, "\(Self.clock(now)): out of control, \(why) (\(game))\n")
    }

    public func removeStop(game: String) {
        try? FileManager.default.removeItem(atPath: stopPath(Self.stopName(game: game)))
    }

    public func appendEvent(game: String, reason: String, seconds: Int, log: String, note: String, now: Date = Date()) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fields = [Self.stamp(now), game, reason, String(seconds), log, note].map(Self.field)
        let line = Data((fields.joined(separator: "\t") + "\n").utf8)
        let descriptor = open(eventsPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw GamesError.unavailable("\(eventsPath) could not be opened: \(Self.errorText())") }
        defer { Darwin.close(descriptor) }
        let written = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw GamesError.unavailable("\(eventsPath) could not be written: \(Self.errorText())") }
    }

    public func gpuErrorsInLastHour(now: Date = Date()) -> Int {
        guard let text = try? String(contentsOfFile: eventsPath, encoding: .utf8) else { return 0 }
        let since = Self.stamp(now.addingTimeInterval(-3600))
        return text.split(separator: "\n").filter { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count > 2 && fields[2] == "gpu" && String(line.prefix(19)) >= since
        }.count
    }

    @discardableResult
    public func release(_ block: GameBlock, now: Date = Date()) throws -> String {
        let base = block.path + ".resolved-" + Self.format("HHmm", now)
        var target = base
        var attempt = 2
        while FileManager.default.fileExists(atPath: target) {
            target = "\(base)-\(attempt)"
            attempt += 1
        }
        guard rename(block.path, target) == 0 else {
            throw GamesError.unavailable("\(block.path) could not be renamed: \(Self.errorText())")
        }
        let note = "released from HorizonHub: " + block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try appendEvent(game: block.game ?? "all", reason: "released", seconds: 0, log: "", note: note, now: now)
        return target
    }

    private func block(_ name: String) -> GameBlock? {
        let path = stopPath(name)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return GameBlock(name: name, path: path, text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: stopPath(name)))
    }

    private static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    static func stamp(_ date: Date) -> String { format("yyyy-MM-dd HH:mm:ss", date) }

    static func clock(_ date: Date) -> String { format("HH:mm:ss", date) }

    static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func errorText() -> String { String(cString: strerror(errno)) }
}

public final class BootLock: @unchecked Sendable {
    public let descriptor: Int32
    private let lock = NSLock()
    private var isOpen = true

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquire(path: String) throws -> BootLock {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw GamesError.unavailable("\(path) could not be opened: \(GuardState.errorText())") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK { throw GamesError.busy }
            throw GamesError.unavailable("\(path) could not be locked: \(String(cString: strerror(error)))")
        }
        return BootLock(descriptor: descriptor)
    }

    public static func isHeld(path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var probe = Darwin.flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &probe) == 0 else { return false }
        return probe.l_type != Int16(F_UNLCK)
    }

    public func close() {
        lock.withLock {
            guard isOpen else { return }
            isOpen = false
            Darwin.close(descriptor)
        }
    }

    deinit {
        close()
    }
}
