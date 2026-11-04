import Foundation
import IOKit.pwr_mgt

public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [IOPMAssertionID] = []

    public init(reason: String) {
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var identifier = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &identifier)
                == kIOReturnSuccess
            {
                identifiers.append(identifier)
            }
        }
    }

    public static func declareUserActivity(_ reason: String) {
        var identifier = IOPMAssertionID(0)
        _ = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &identifier)
    }

    public func release() {
        lock.withLock {
            identifiers.forEach { IOPMAssertionRelease($0) }
            identifiers = []
        }
    }

    deinit {
        release()
    }
}

public struct ProcessIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64

    public static func of(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    public static func groupLeader(_ pid: pid_t) -> Bool {
        getpgid(pid) == pid
    }

    public var isAlive: Bool {
        ProcessIdentity.of(pid) == self
    }
}

public enum MemoryLevel {
    public static let warningBelow = 10

    public static func current() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
