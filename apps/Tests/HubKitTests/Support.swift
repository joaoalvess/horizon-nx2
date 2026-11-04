import Foundation
import Testing
@testable import HubKit

let guardScript = "/Volumes/Hangar/Games/overnight/guard.py"
let hasGuard = FileManager.default.fileExists(atPath: guardScript)

struct Scratch {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hubkit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ content: String, executable: Bool = false) throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: URL(fileURLWithPath: target))
        if executable { chmod(target, 0o755) }
        return target
    }

    func read(_ relative: String) -> String {
        (try? String(contentsOfFile: path(relative), encoding: .utf8)) ?? ""
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative)) }

    func remove() {
        if let short = try? FileManager.default.destinationOfSymbolicLink(atPath: path("short")) {
            try? FileManager.default.removeItem(atPath: short)
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}

struct FakeGames {
    let scratch: Scratch
    let gameId: String
    let shortDirectory: String

    init(gameId: String = "hubtest") throws {
        scratch = try Scratch()
        self.gameId = gameId
        shortDirectory = try makeShortDirectory()
        try FileManager.default.createSymbolicLink(atPath: scratch.path("short"), withDestinationPath: shortDirectory)
        for folder in ["state", "support", "logs", "run", "saves", "volume", "reports"] {
            try FileManager.default.createDirectory(atPath: scratch.path(folder), withIntermediateDirectories: true)
        }
        try scratch.write("program", "")
    }

    var state: GuardState { GuardState(directory: scratch.path("state")) }

    var settings: GamesSettings {
        var settings = GamesSettings(supportDirectory: scratch.path("support"))
        settings.reportDirectories = [scratch.path("reports")]
        settings.reportWait = 1
        settings.closeGrace = 1
        settings.survivalWait = 2
        settings.pollInterval = 0.05
        settings.levelInterval = 0.05
        settings.systemLog = false
        settings.keepsAwake = false
        settings.volumeRoot = scratch.path("volume")
        settings.memoryLevel = { 50 }
        settings.streamSocket = shortDirectory + "/s.sock"
        return settings
    }

    func catalog(script: String, extraGames: [String] = []) throws -> GameCatalog {
        let host = try scratch.write("bin/fakehost", "#!/bin/sh\n" + script, executable: true)
        let games = ([gameId] + extraGames).map { id in
            Game(
                id: id,
                title: "Fake \(id)",
                titleId: "0100000000000000",
                host: host,
                program: scratch.path("program"),
                directory: scratch.path("run"),
                logs: scratch.path("logs"),
                saves: scratch.path("saves"),
                psoUser: scratch.path("pso_user.tsv"),
                environment: ["HUB_TEST_ROOT": scratch.root, "HUB_TEST_VOLUME": scratch.path("volume")]
            )
        }
        return GameCatalog(
            state: scratch.path("state"),
            profiles: [GameProfile(id: "test", name: "Test", nick: "Tester")],
            games: games
        )
    }

    func open(_ catalog: GameCatalog, settings: GamesSettings? = nil) throws -> GameSession {
        try GameSession.open(catalog: catalog, profile: "test", game: gameId, settings: settings ?? self.settings)
    }

    func report(process: String, name: String? = nil) throws {
        let header = #"{"bug_type":"284","timestamp":"2026-11-03 17:39:45.00 -0300","os_version":"macOS 27.0.1 (26A434)"}"#
        let body = "{\n  \"bug_type\" : \"284\",\n  \"process_name\" : \"\(process)\",\n  \"registers\" : {}\n}"
        try scratch.write("reports/" + (name ?? "gpuEvent-\(process)-2026-11-03-173945.ips"), header + "\n" + body)
    }
}

let victimLine = #"    "Error Domain=MTL4CommandQueueErrorDomain Code=1 \"Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)\" UserInfo={NSLocalizedDescription=Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim), NSUnderlyingError=0x77b2edc720 {Error"#
let ownLine = #"    "Error Domain=MTL4CommandQueueErrorDomain Code=2 \"Caused GPU Address Fault Error (0000000b:kIOGPUCommandBufferCallbackErrorPageFault)\" UserInfo={NSLocalizedDescription=Caused GPU Address Fault Error (0000000b:kIOGPUCommandBufferCallbackErrorPageFault), NSUnderlyingError=0x7930c41080 {Error Domain=IOGPUCommandQueueError"#

func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

struct Timeout: Error {}

func finished(_ session: GameSession, within seconds: TimeInterval = 20) async throws -> GameOutcome {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if case .finished(let outcome) = session.currentStatus.phase { return outcome }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw Timeout()
}

func waitUntil(
    within seconds: TimeInterval = 10, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("the condition did not hold within \(seconds) s", sourceLocation: sourceLocation)
    throw Timeout()
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

func runGuard(state: String, game: String, lockWait: Int, log: String) async throws -> ProcessResult {
    var environment = ProcessRunner.baseEnvironment()
    environment["GUARD_STATE"] = state
    let runner = ProcessRunner(environment: environment)
    let arguments = [guardScript, "--game", game, "--log", log, "--lock-wait", String(lockWait), "--", "/usr/bin/true"]
    return try await withCheckedThrowingContinuation { continuation in
        Thread {
            continuation.resume(with: Result { try runner.run("/usr/bin/python3", arguments, timeout: 120) })
        }.start()
    }
}

func makeShortDirectory() throws -> String {
    var template = Array("/tmp/hv.XXXXXX".utf8CString)
    guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else { throw Timeout() }
    return String(cString: made)
}

func physical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
