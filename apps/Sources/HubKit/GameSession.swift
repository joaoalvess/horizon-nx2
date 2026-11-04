import Foundation
import HorizonLink

public struct GamesSettings: Sendable {
    public var supportDirectory: String
    public var reportDirectories = GPUErrors.reportDirectories
    public var reportWait: TimeInterval = 15
    public var reportLookback: TimeInterval = 30
    public var closeGrace: TimeInterval = 10
    public var survivalWait: TimeInterval = 5
    public var pollInterval: TimeInterval = 0.25
    public var levelInterval: TimeInterval = 2
    public var systemLog = true
    public var keepsAwake = true
    public var volumeRoot = "/Volumes/Hangar"
    public var memoryLevel: @Sendable () -> Int? = MemoryLevel.current
    public var streamSocket: String

    public init(supportDirectory: String) {
        self.supportDirectory = supportDirectory
        streamSocket = supportDirectory + "/stream.sock"
    }

    public var sessionFile: String { supportDirectory + "/session.json" }
    public var catalogCache: String { supportDirectory + "/catalog.json" }
}

public struct SessionRecord: Codable, Sendable, Equatable {
    public var process: ProcessIdentity
    public var game: String
    public var title: String
    public var profile: String
    public var profileName: String
    public var log: String
    public var state: String
    public var processName: String
    public var startedAt: Date
}

public struct GameOutcome: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case closed, ended, gpu, memory, crash
        case gpuOther = "gpu-other"
        case ssdLost = "ssd-lost"
    }

    public var kind: Kind
    public var exit: ExitStatus?
    public var seconds: Int
    public var note: String
    public var culprits: [String]
    public var stopAll: String?
    public var gracefulExit: Bool
}

public enum SessionPhase: Sendable, Equatable {
    case running
    case closing
    case finished(GameOutcome)
}

public struct SessionStatus: Sendable, Equatable {
    public var phase: SessionPhase = .running
    public var memoryLevel: Int?
    public var memoryCritical = false

    public var memoryWarning: Bool { memoryLevel.map { $0 < MemoryLevel.warningBelow } ?? false }
}

public final class GameSession: @unchecked Sendable {
    public let record: SessionRecord
    public let adopted: Bool

    private let settings: GamesSettings
    private let guardState: GuardState
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.game-session")
    private var bootLock: BootLock?
    private var power: PowerAssertion?
    private var status = SessionStatus()
    private var changeHandler: (@Sendable (SessionStatus) -> Void)?
    private var finishHandlers: [@Sendable (GameOutcome) -> Void] = []
    private var timer: DispatchSourceTimer?
    private var memorySource: DispatchSourceMemoryPressure?
    private var exitSource: DispatchSourceProcess?
    private var systemLog: Process?
    private var logHandle: FileHandle?
    private var logOffset: UInt64 = 0
    private var gpuLines: [String] = []
    private var gpuDetectedAt: Date?
    private var lastLevelCheck = Date.distantPast
    private var closeRequested = false
    private var memoryCloseRequested = false
    private var survived = false
    private var exiting = false
    private var detached = false

    private init(record: SessionRecord, adopted: Bool, settings: GamesSettings, bootLock: BootLock?) {
        self.record = record
        self.adopted = adopted
        self.settings = settings
        self.bootLock = bootLock
        guardState = GuardState(directory: record.state)
    }

    public var pid: pid_t { record.process.pid }

    public var currentStatus: SessionStatus { queue.sync { status } }

    public func onChange(_ handler: @escaping @Sendable (SessionStatus) -> Void) {
        let current: SessionStatus = queue.sync {
            changeHandler = handler
            return status
        }
        handler(current)
    }

    public func onFinish(_ handler: @escaping @Sendable (GameOutcome) -> Void) {
        let outcome: GameOutcome? = queue.sync {
            if case .finished(let outcome) = status.phase { return outcome }
            finishHandlers.append(handler)
            return nil
        }
        if let outcome { handler(outcome) }
    }

    public static func open(catalog: GameCatalog, profile profileId: String, game gameId: String, settings: GamesSettings) throws
        -> GameSession
    {
        guard let profile = catalog.profile(profileId) else { throw GamesError.catalog("unknown profile \(profileId)") }
        guard let game = catalog.game(gameId) else { throw GamesError.catalog("unknown game \(gameId)") }
        if let record = readRecord(settings: settings), record.process.isAlive { throw GamesError.alreadyRunning }
        guard settings.streamSocket.utf8.count <= DMStream.maxSocketPath else {
            throw GamesError.unavailable("the stream socket path \(settings.streamSocket) is over \(DMStream.maxSocketPath) bytes")
        }
        let state = GuardState(directory: catalog.state)
        try state.ensureNotBlocked(game: game.id)
        let files = FileManager.default
        for path in [game.host, game.program, game.directory] where !files.fileExists(atPath: path) {
            throw GamesError.unavailable("\(path) does not exist")
        }
        let save = catalog.savePath(profile: profile, game: game)
        if !files.fileExists(atPath: save) {
            guard !catalog.hasExplicitSave(profile: profile, game: game) else {
                throw GamesError.unavailable("the save folder \(save) does not exist")
            }
            try files.createDirectory(atPath: save, withIntermediateDirectories: true)
        }
        try files.createDirectory(atPath: game.logs, withIntermediateDirectories: true)
        try files.createDirectory(atPath: settings.supportDirectory, withIntermediateDirectories: true)

        let lock = try BootLock.acquire(path: state.lockPath)
        do {
            try state.ensureNotBlocked(game: game.id)
            let startedAt = Date()
            let log = "\(game.logs)/hub-\(profile.id)-\(GuardState.format("yyyy-MM-dd-HHmmss", startedAt)).log"
            let spec = LaunchSpec(
                executable: game.host,
                arguments: [game.program],
                environment: catalog.launchEnvironment(profile: profile, game: game, streamSocket: settings.streamSocket),
                directory: game.directory,
                logPath: log,
                inheritedDescriptor: lock.descriptor
            )
            let pid = try GameLauncher.spawn(spec)
            let record = SessionRecord(
                process: ProcessIdentity.of(pid) ?? ProcessIdentity(pid: pid, startSeconds: 0, startMicroseconds: 0),
                game: game.id,
                title: game.title,
                profile: profile.id,
                profileName: profile.name,
                log: log,
                state: catalog.state,
                processName: URL(fileURLWithPath: game.host).resolvingSymlinksInPath().lastPathComponent,
                startedAt: startedAt
            )
            let session = GameSession(record: record, adopted: false, settings: settings, bootLock: lock)
            try? session.saveRecord()
            session.queue.sync { session.startMonitoring() }
            Thread {
                let exit = GameLauncher.wait(pid)
                session.queue.async { session.processExited(exit) }
            }.start()
            return session
        } catch {
            lock.close()
            throw error
        }
    }

    public static func adopt(settings: GamesSettings) -> GameSession? {
        guard let record = readRecord(settings: settings) else { return nil }
        let session = GameSession(record: record, adopted: true, settings: settings, bootLock: nil)
        session.queue.sync {
            if record.process.isAlive, ProcessIdentity.groupLeader(record.process.pid) {
                session.startMonitoring()
            } else {
                session.processExited(nil)
            }
        }
        return session
    }

    public static func readRecord(settings: GamesSettings) -> SessionRecord? {
        guard let data = FileManager.default.contents(atPath: settings.sessionFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    public func close() {
        queue.async { [self] in
            guard !isFinished, !exiting, !closeRequested else { return }
            closeRequested = true
            note("close requested: SIGTERM to the game's process group")
            setPhase(.closing)
            kill(-pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + settings.closeGrace) { [self] in
                guard !isFinished, !exiting else { return }
                note("still running \(Int(settings.closeGrace)) s after SIGTERM: SIGKILL")
                kill(-pid, SIGKILL)
            }
        }
    }

    func memoryPressureCritical() {
        guard !isFinished, !exiting, !memoryCloseRequested else { return }
        memoryCloseRequested = true
        status.memoryCritical = true
        note("memory pressure critical: closing the game with SIGTERM")
        if !closeRequested { setPhase(.closing) } else { notify() }
        kill(-pid, SIGTERM)
    }

    func simulateCriticalMemory() {
        queue.sync { memoryPressureCritical() }
    }

    func detach() {
        queue.sync {
            detached = true
            stopMonitoring()
            power?.release()
            bootLock?.close()
        }
    }

    private var isFinished: Bool {
        if case .finished = status.phase { return true }
        return detached
    }

    private func startMonitoring() {
        if settings.keepsAwake {
            if !adopted { PowerAssertion.declareUserActivity("HorizonHub opened \(record.title)") }
            power = PowerAssertion(reason: "HorizonHub: \(record.title) is running")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: settings.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer

        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        memory.setEventHandler { [weak self, weak memory] in
            guard let self, let event = memory?.data else { return }
            if event.contains(.critical) {
                memoryPressureCritical()
            } else {
                note("memory pressure \(event.contains(.warning) ? "warning" : "normal")")
            }
        }
        memory.resume()
        memorySource = memory

        if adopted {
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [weak self] in self?.processExited(nil) }
            exit.resume()
            exitSource = exit
        }
        if settings.systemLog { startSystemLog() }
    }

    private func stopMonitoring() {
        timer?.cancel()
        timer = nil
        memorySource?.cancel()
        memorySource = nil
        exitSource?.cancel()
        exitSource = nil
        if let systemLog, systemLog.isRunning { systemLog.terminate() }
        systemLog = nil
        try? logHandle?.close()
        logHandle = nil
    }

    private func startSystemLog() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "compact", "--predicate",
            #"eventMessage CONTAINS "IOGPUMetalError" OR eventMessage CONTAINS "kIOGPUCommandBufferCallbackError""#,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        systemLog = process
        let marker = "[\(pid):"
        let reader = pipe.fileHandleForReading
        Thread { [weak self] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { return }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if line.contains(marker) {
                        guard let self else { return }
                        queue.async { self.gpuError(line, source: "system log") }
                    }
                }
            }
        }.start()
    }

    private func poll() {
        guard !isFinished else { return }
        scanLog()
        let now = Date()
        if now.timeIntervalSince(lastLevelCheck) >= settings.levelInterval {
            lastLevelCheck = now
            let level = settings.memoryLevel()
            if level != status.memoryLevel {
                let wasWarning = status.memoryWarning
                status.memoryLevel = level
                if status.memoryWarning != wasWarning {
                    note(status.memoryWarning ? "memory level \(level ?? -1), below \(MemoryLevel.warningBelow)" : "memory level \(level ?? -1)")
                }
                notify()
            }
        }
        if adopted, !exiting, !record.process.isAlive { processExited(nil) }
    }

    private func scanLog() {
        if logHandle == nil { logHandle = FileHandle(forReadingAtPath: record.log) }
        guard let logHandle else { return }
        let start = logOffset > UInt64(GPUErrors.overlap) ? logOffset - UInt64(GPUErrors.overlap) : 0
        guard (try? logHandle.seek(toOffset: start)) != nil, let data = try? logHandle.readToEnd(), !data.isEmpty else { return }
        logOffset = start + UInt64(data.count)
        guard gpuDetectedAt == nil, let match = GPUErrors.firstMatch(in: data) else { return }
        let from = data.index(match.lowerBound, offsetBy: -80, limitedBy: data.startIndex) ?? data.startIndex
        let to = data.index(match.upperBound, offsetBy: 120, limitedBy: data.endIndex) ?? data.endIndex
        let snippet = String(decoding: data[from..<to], as: UTF8.self)
        gpuError(snippet, source: "game log")
    }

    private func gpuError(_ text: String, source: String) {
        let snippet = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        if source == "system log" { gpuLines.append(snippet) }
        guard gpuDetectedAt == nil, !isFinished else { return }
        gpuDetectedAt = Date()
        try? guardState.writeStop(game: record.game, log: record.log, note: String(snippet.prefix(300)))
        guard !exiting else { return }
        kill(-pid, SIGKILL)
        note("GPU error in the \(source): SIGKILL to the game's process group")
        setPhase(.closing)
        queue.asyncAfter(deadline: .now() + settings.survivalWait) { [self] in
            guard !isFinished, !exiting else { return }
            survived = true
            try? guardState.writeStopAll(why: "the game survived the kill", game: record.game)
            kill(-pid, SIGKILL)
        }
    }

    private func processExited(_ exit: ExitStatus?) {
        guard !isFinished, !exiting else { return }
        exiting = true
        let observedLive = timer != nil
        scanLog()
        if observedLive { kill(-pid, SIGKILL) }
        stopMonitoring()
        if adopted { holdLock(attempts: 20) }
        let wait = gpuDetectedAt.map { max(0, $0.addingTimeInterval(settings.reportWait).timeIntervalSinceNow) } ?? 0
        if gpuDetectedAt != nil, !GPUErrors.isVictimOnly(gpuLinesFromLog()) {
            complete(exit)
        } else {
            queue.asyncAfter(deadline: .now() + wait) { [self] in complete(exit) }
        }
    }

    private func holdLock(attempts: Int) {
        guard bootLock == nil, !isFinished else { return }
        if let lock = try? BootLock.acquire(path: guardState.lockPath) {
            bootLock = lock
        } else if attempts > 1 {
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in holdLock(attempts: attempts - 1) }
        }
    }

    private func gpuLinesFromLog() -> [String] {
        let data = FileManager.default.contents(atPath: record.log) ?? Data()
        return GPUErrors.matchingLines(in: data) + gpuLines
    }

    private func complete(_ exit: ExitStatus?) {
        guard !detached else { return }
        let data = FileManager.default.contents(atPath: record.log) ?? Data()
        let graceful = data.range(of: Data("graceful exit done".utf8)) != nil
        let lines = GPUErrors.matchingLines(in: data) + gpuLines
        let seconds = Int(Date().timeIntervalSince(record.startedAt))
        var kind: GameOutcome.Kind
        var detail: String
        var culprits: [String] = []
        if gpuDetectedAt == nil, !lines.isEmpty {
            gpuDetectedAt = Date()
            try? guardState.writeStop(game: record.game, log: record.log, note: String(lines[0].prefix(300)))
        }
        if let detected = gpuDetectedAt {
            let reports = GPUErrors.reportProcesses(
                in: settings.reportDirectories,
                from: detected.addingTimeInterval(-settings.reportLookback),
                to: Date()
            )
            switch GPUErrors.classify(lines: lines, reportProcesses: reports, gameProcess: record.processName) {
            case .own:
                kind = .gpu
                detail = String((lines.first ?? "GPU error").prefix(300))
            case .victim(let names):
                kind = .gpuOther
                culprits = names
                guardState.removeStop(game: record.game)
                detail = "innocent victim; the GPU was hung by \(names.joined(separator: ", "))"
            }
        } else if memoryCloseRequested {
            kind = .memory
            detail = "closed at critical memory pressure"
        } else if closeRequested {
            kind = .closed
            detail = graceful ? "closed from HorizonHub, graceful exit done" : "closed from HorizonHub"
        } else if exit == ExitStatus.signaled(SIGBUS), !FileManager.default.fileExists(atPath: settings.volumeRoot) {
            kind = .ssdLost
            detail = "the SSD went away while the game ran"
        } else if exit == ExitStatus.exited(0) || (exit == nil && graceful) {
            kind = .ended
            detail = graceful ? "graceful exit done" : "the game quit"
        } else if exit == nil {
            kind = .ended
            detail = "ended while HorizonHub was not watching"
        } else {
            kind = .crash
            detail = "the game stopped"
        }
        if survived { detail += " (the game survived the kill)" }
        var parts = ["profile \(record.profile)"]
        if let exit { parts.append(exit.description) }
        if adopted { parts.append("adopted") }
        parts.append(detail)
        try? guardState.appendEvent(game: record.game, reason: kind.rawValue, seconds: seconds, log: record.log, note: parts.joined(separator: "; "))
        var stopAll: String?
        if kind == .gpu {
            stopAll = survived ? "the game survived the kill" : guardState.gpuErrorsInLastHour() >= 3 ? "three GPU errors within an hour" : nil
            if let stopAll, !survived { try? guardState.writeStopAll(why: stopAll, game: record.game) }
        }
        try? FileManager.default.removeItem(atPath: settings.sessionFile)
        power?.release()
        bootLock?.close()
        let outcome = GameOutcome(
            kind: kind, exit: exit, seconds: seconds, note: detail, culprits: culprits, stopAll: stopAll, gracefulExit: graceful
        )
        setPhase(.finished(outcome))
        let handlers = finishHandlers
        finishHandlers = []
        handlers.forEach { $0(outcome) }
    }

    private func saveRecord() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: URL(fileURLWithPath: settings.sessionFile), options: .atomic)
    }

    private func setPhase(_ phase: SessionPhase) {
        status.phase = phase
        notify()
    }

    private func notify() {
        changeHandler?(status)
    }

    private func note(_ text: String) {
        let descriptor = Darwin.open(record.log, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let line = Data("[hub] \(GuardState.clock(Date())) \(text)\n".utf8)
        _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }
}
