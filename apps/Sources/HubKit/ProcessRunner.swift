import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable, CustomStringConvertible {
    case executableNotFound(String)
    case timedOut(String, seconds: Int)

    public var description: String {
        switch self {
        case .executableNotFound(let path): "\(path) is not an executable"
        case .timedOut(let path, let seconds): "\(path) did not finish in \(seconds) s and was stopped"
        }
    }
}

public struct ProcessRunner: Sendable {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessRunner.baseEnvironment()) {
        self.environment = environment
    }

    public static func stopChildren(grace: TimeInterval) {
        Children.shared.signal(SIGTERM)
        let deadline = Date() + grace
        while !Children.shared.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        Children.shared.signal(SIGKILL)
    }

    public static func baseEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        for key in ["SSH_AUTH_SOCK", "USER", "TMPDIR"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : stdinPipe
        try process.run()
        Children.shared.add(process.processIdentifier)
        defer { Children.shared.remove(process.processIdentifier) }
        let deadline = Deadline(pid: process.processIdentifier)
        if let timeout { deadline.arm(after: timeout) }

        let group = DispatchGroup()
        func onOwnThread(_ work: @escaping @Sendable () -> Void) {
            group.enter()
            Thread {
                work()
                group.leave()
            }.start()
        }
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        onOwnThread { stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile()) }
        onOwnThread { stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile()) }
        if let input {
            let writer = stdinPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            onOwnThread {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        group.wait()
        process.waitUntilExit()
        if deadline.finish(), let timeout {
            throw ProcessRunnerError.timedOut(executable, seconds: Int(timeout))
        }
        return ProcessResult(status: process.terminationStatus, stdout: stdoutBox.value, stderr: stderrBox.value)
    }
}

private final class Deadline: @unchecked Sendable {
    static let killGrace: TimeInterval = 10

    private let lock = NSLock()
    private let pid: pid_t
    private var finished = false
    private var expired = false

    init(pid: pid_t) {
        self.pid = pid
    }

    func arm(after timeout: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            self.signal(SIGTERM, expiring: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + Deadline.killGrace) {
                self.signal(SIGKILL, expiring: false)
            }
        }
    }

    private func signal(_ signal: Int32, expiring: Bool) {
        lock.withLock {
            guard !finished else { return }
            if expiring { expired = true }
            kill(-pid, signal)
        }
    }

    func finish() -> Bool {
        lock.withLock {
            finished = true
            return expired
        }
    }
}

private final class Children: @unchecked Sendable {
    static let shared = Children()

    private let lock = NSLock()
    private var groups = Set<pid_t>()

    var isEmpty: Bool { lock.withLock { groups.isEmpty } }

    func add(_ pid: pid_t) { lock.withLock { _ = groups.insert(pid) } }

    func remove(_ pid: pid_t) { lock.withLock { _ = groups.remove(pid) } }

    func signal(_ signal: Int32) {
        lock.withLock {
            for group in groups { kill(-group, signal) }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data { lock.withLock { data } }

    func set(_ newValue: Data) { lock.withLock { data = newValue } }
}
