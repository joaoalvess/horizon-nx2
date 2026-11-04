import Foundation

public enum ExitStatus: Sendable, Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    public var description: String {
        switch self {
        case .exited(let code): "exit \(code)"
        case .signaled(let signal): "signal \(signal)"
        }
    }
}

public struct LaunchSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    public var logPath: String
    public var inheritedDescriptor: Int32?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        logPath: String,
        inheritedDescriptor: Int32?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.logPath = logPath
        self.inheritedDescriptor = inheritedDescriptor
    }
}

public enum GameLauncher {
    public static func spawn(_ spec: LaunchSpec) throws -> pid_t {
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            throw GamesError.launch("\(spec.executable) is not an executable")
        }
        let log = open(spec.logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard log >= 0 else { throw GamesError.launch("\(spec.logPath) could not be opened: \(GuardState.errorText())") }
        defer { close(log) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, log, 1)
        posix_spawn_file_actions_adddup2(&actions, log, 2)
        if let inherited = spec.inheritedDescriptor {
            posix_spawn_file_actions_addinherit_np(&actions, inherited)
        }
        posix_spawn_file_actions_addchdir_np(&actions, spec.directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw GamesError.launch("\(spec.executable) could not be started: \(String(cString: strerror(result)))")
        }
        return pid
    }

    public static func wait(_ pid: pid_t) -> ExitStatus {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return .exited(-1) }
        }
        return ExitStatus(waitStatus: status)
    }
}
