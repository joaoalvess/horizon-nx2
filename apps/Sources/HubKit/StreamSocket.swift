import Darwin
import Foundation
import HorizonLink

public final class StreamSocket: @unchecked Sendable {
    public enum Event: Sendable {
        case connected(ProcessIdentity)
        case message(DMStream.Header, DMStream.Message)
        case disconnected(String)
        case refused(pid_t)
    }

    public let path: String
    private let accepts: @Sendable (ProcessIdentity) -> Bool
    private let events: @Sendable (Event) -> Void
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "dev.joaoalvess.horizon.stream-socket.write")
    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var generation = 0

    public init(
        path: String, accepts: @escaping @Sendable (ProcessIdentity) -> Bool, events: @escaping @Sendable (Event) -> Void
    ) {
        self.path = path
        self.accepts = accepts
        self.events = events
    }

    public var isConnected: Bool { lock.withLock { connection >= 0 } }

    public func start() throws {
        guard path.utf8.count <= DMStream.maxSocketPath else {
            throw GamesError.unavailable("the stream socket path \(path) is over \(DMStream.maxSocketPath) bytes")
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if unlink(path) != 0, errno != ENOENT {
            throw GamesError.unavailable("\(path) could not be removed: \(GuardState.errorText())")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GamesError.unavailable("no stream socket: \(GuardState.errorText())") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            let text = GuardState.errorText()
            Darwin.close(descriptor)
            throw GamesError.unavailable("the stream socket \(path) could not listen: \(text)")
        }
        lock.withLock { listener = descriptor }
        Thread { [self] in acceptLoop(descriptor) }.start()
    }

    public func stop() {
        let (listening, connected) = lock.withLock { () -> (Int32, Int32) in
            defer {
                listener = -1
                connection = -1
                generation += 1
            }
            return (listener, connection)
        }
        if listening >= 0 { Darwin.close(listening) }
        if connected >= 0 { shutdown(connected, SHUT_RDWR) }
        unlink(path)
    }

    public func disconnect() {
        let connected = lock.withLock { connection }
        if connected >= 0 { shutdown(connected, SHUT_RDWR) }
    }

    public func send(_ message: DMStream.Message) {
        let data = DMStream.encode(message)
        writes.async { [self] in
            let descriptor = lock.withLock { connection }
            guard descriptor >= 0 else { return }
            if !Self.writeAll(descriptor, data) { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func acceptLoop(_ listening: Int32) {
        while true {
            let client = accept(listening, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var peer: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            let identity = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0 ? ProcessIdentity.of(peer) : nil
            guard let identity, accepts(identity) else {
                Darwin.close(client)
                events(.refused(peer))
                continue
            }
            let (previous, current) = lock.withLock { () -> (Int32, Int) in
                let previous = connection
                connection = client
                generation += 1
                return (previous, generation)
            }
            if previous >= 0 { shutdown(previous, SHUT_RDWR) }
            events(.connected(identity))
            send(.hubHello(DMStream.version))
            Thread { [self] in readLoop(client, generation: current) }.start()
        }
    }

    private func readLoop(_ descriptor: Int32, generation current: Int) {
        var parser = DMStream.Parser(direction: .fromHost)
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var reason = "the game closed the stream socket"
        reading: while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                reason = "reading the stream socket failed: \(GuardState.errorText())"
                break
            }
            parser.append(Data(buffer[0..<count]))
            do {
                while let next = try parser.next() {
                    guard lock.withLock({ generation == current }) else { break reading }
                    events(.message(next.header, next.message))
                }
            } catch {
                reason = "protocol error from the game: \(error)"
                break
            }
        }
        let wasCurrent = lock.withLock { () -> Bool in
            guard generation == current, connection == descriptor else { return false }
            connection = -1
            return true
        }
        writes.sync {}
        Darwin.close(descriptor)
        if wasCurrent { events(.disconnected(reason)) }
    }
}
