import CryptoKit
import Darwin
import Foundation

public struct SocketAddress: Sendable, Hashable, CustomStringConvertible {
    public let bytes: Data

    public init?(host: String, port: UInt16) {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let address = info.pointee.ai_addr else { return nil }
        bytes = Data(bytes: address, count: Int(info.pointee.ai_addrlen))
    }

    init(_ pointer: UnsafeRawPointer, length: socklen_t) {
        bytes = Data(bytes: pointer, count: Int(length))
    }

    var family: Int32 {
        bytes.count > 1 ? Int32(bytes[bytes.startIndex + 1]) : AF_UNSPEC
    }

    public var port: UInt16 {
        bytes.count >= 4 ? UInt16(bytes[bytes.startIndex + 2]) << 8 | UInt16(bytes[bytes.startIndex + 3]) : 0
    }

    public var host: String {
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = bytes.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return getnameinfo(
                base.assumingMemoryBound(to: sockaddr.self), socklen_t(buffer.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST
            )
        }
        guard result == 0 else { return "?" }
        let host = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
    }

    public var description: String { family == AF_INET6 && !host.contains(".") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    func mapped() -> SocketAddress {
        guard family == AF_INET, bytes.count >= MemoryLayout<sockaddr_in>.size else { return self }
        var v4 = sockaddr_in()
        _ = withUnsafeMutableBytes(of: &v4) { bytes.copyBytes(to: $0) }
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = v4.sin_port
        withUnsafeMutableBytes(of: &v6.sin6_addr) { target in
            target[10] = 0xFF
            target[11] = 0xFF
            withUnsafeBytes(of: v4.sin_addr) { source in
                for index in 0..<4 { target[12 + index] = source[index] }
            }
        }
        return withUnsafeBytes(of: &v6) { SocketAddress($0.baseAddress.unsafelyUnwrapped, length: socklen_t(MemoryLayout<sockaddr_in6>.size)) }
    }
}

public final class MediaSocket: @unchecked Sendable {
    public let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    public init(port: UInt16 = 0, serviceType: Int32 = NET_SERVICE_TYPE_VI, bufferBytes: Int32 = 4 << 20) throws {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw LinkError.violation("no UDP socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var off: Int32 = 0
        var service = serviceType
        var buffer = bufferBytes
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &off, size)
        setsockopt(descriptor, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &buffer, size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &buffer, size)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else {
            let text = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw LinkError.violation("the UDP socket could not bind port \(port): \(text)")
        }
        var local = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        self.descriptor = descriptor
        self.port = UInt16(bigEndian: local.sin6_port)
    }

    deinit {
        close()
    }

    public func close() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    @discardableResult
    public func send(_ data: Data, to address: SocketAddress) -> Int32 {
        let target = address.mapped()
        let sent = data.withUnsafeBytes { payload in
            target.bytes.withUnsafeBytes { name in
                sendto(
                    descriptor, payload.baseAddress, payload.count, 0, name.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(name.count)
                )
            }
        }
        return sent < 0 ? errno : 0
    }

    public func receive(_ handler: @escaping @Sendable (Data, SocketAddress) -> Void) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            var name = sockaddr_storage()
            while true {
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    withUnsafeMutablePointer(to: &name) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length) }
                    }
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if lock.withLock({ closed }) { return }
                let from = withUnsafeBytes(of: &name) { SocketAddress($0.baseAddress.unsafelyUnwrapped, length: length) }
                handler(Data(buffer[0..<count]), from)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "horizon.media.receive"
        thread.start()
    }
}

public struct PacerSettings: Sendable, Equatable {
    public var burst: Int
    public var gapMicroseconds: UInt32

    public init(burst: Int = 24, gapMicroseconds: UInt32 = 250) {
        self.burst = burst
        self.gapMicroseconds = gapMicroseconds
    }
}

public struct PacerStats: Sendable, Equatable {
    public var sent: UInt64 = 0
    public var failed: UInt64 = 0
    public var lastError: Int32 = 0
    public var dropped: UInt64 = 0
    public var deepestQueue = 0
}

public final class PacedSender: @unchecked Sendable {
    private struct Item {
        let channel: MediaChannel
        let plaintext: Data
    }

    public var settings: PacerSettings {
        get { condition.withLock { currentSettings } }
        set { condition.withLock { currentSettings = newValue } }
    }

    private let socket: MediaSocket
    private let condition = NSCondition()
    private var currentSettings: PacerSettings
    private var sealer: DatagramSealer?
    private var destination: SocketAddress?
    private var priority: [Item] = []
    private var bulk: [Item] = []
    private var bulkHead = 0
    private var running = true
    private var counters = PacerStats()
    private let bulkLimit: Int

    public init(socket: MediaSocket, settings: PacerSettings = PacerSettings(), bulkLimit: Int = 4096) {
        self.socket = socket
        currentSettings = settings
        self.bulkLimit = bulkLimit
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInteractive
        thread.name = "horizon.media.send"
        thread.start()
    }

    public var stats: PacerStats { condition.withLock { counters } }

    public var queuedBulk: Int { condition.withLock { bulk.count - bulkHead } }

    public func configure(key: SymmetricKey) {
        condition.withLock {
            sealer = DatagramSealer(key: key)
            priority.removeAll()
            bulk.removeAll()
            bulkHead = 0
        }
    }

    public func setDestination(_ address: SocketAddress?) {
        condition.withLock {
            destination = address
            condition.signal()
        }
    }

    public func send(_ plaintext: Data, channel: MediaChannel) {
        condition.withLock {
            priority.append(Item(channel: channel, plaintext: plaintext))
            condition.signal()
        }
    }

    public func sendBulk(_ plaintexts: [Data], channel: MediaChannel) {
        condition.withLock {
            let room = bulkLimit - (bulk.count - bulkHead)
            if plaintexts.count > room { counters.dropped += UInt64(plaintexts.count - max(0, room)) }
            for plaintext in plaintexts.prefix(max(0, room)) { bulk.append(Item(channel: channel, plaintext: plaintext)) }
            counters.deepestQueue = max(counters.deepestQueue, bulk.count - bulkHead)
            condition.signal()
        }
    }

    public func clearBulk() {
        condition.withLock {
            counters.dropped += UInt64(bulk.count - bulkHead)
            bulk.removeAll()
            bulkHead = 0
        }
    }

    public func stop() {
        condition.withLock {
            running = false
            condition.signal()
        }
    }

    private func loop() {
        condition.lock()
        while running {
            guard destination != nil, sealer != nil, !priority.isEmpty || bulkHead < bulk.count else {
                condition.wait()
                continue
            }
            let urgent = priority
            priority.removeAll(keepingCapacity: true)
            let take = min(currentSettings.burst, bulk.count - bulkHead)
            let batch = Array(bulk[bulkHead..<bulkHead + take])
            bulkHead += take
            if bulkHead == bulk.count {
                bulk.removeAll(keepingCapacity: true)
                bulkHead = 0
            }
            let more = bulkHead < bulk.count
            let gap = currentSettings.gapMicroseconds
            var sealed: [Data] = []
            sealed.reserveCapacity(urgent.count + batch.count)
            for item in urgent + batch {
                if let datagram = try? sealer?.seal(item.plaintext, channel: item.channel.rawValue) { sealed.append(datagram) }
            }
            let target = destination
            condition.unlock()
            var sent: UInt64 = 0
            var failed: UInt64 = 0
            var lastError: Int32 = 0
            if let target {
                for datagram in sealed {
                    let error = socket.send(datagram, to: target)
                    if error == 0 { sent += 1 } else {
                        failed += 1
                        lastError = error
                    }
                }
            }
            if more, gap > 0 { usleep(gap) }
            condition.lock()
            counters.sent += sent
            counters.failed += failed
            if lastError != 0 { counters.lastError = lastError }
        }
        condition.unlock()
    }
}
