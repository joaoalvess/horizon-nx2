import Darwin
import Foundation
import HorizonLink

final class HubLink: Sendable {
    private let path: String
    private let host: Host
    private let queue: SendQueue
    private let sendBuffer: Int32

    init(path: String, host: Host, queue: SendQueue, sendBuffer: Int32) {
        self.path = path
        self.host = host
        self.queue = queue
        self.sendBuffer = sendBuffer
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "fakestream.link"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        var lastError: Int32 = -1
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 || !connect(fd) {
                let error = errno
                if fd >= 0 { close(fd) }
                if error != lastError {
                    let reason = String(cString: strerror(error))
                    if error == ENOENT || error == ECONNREFUSED {
                        Log.info("no hub listening at \(path) (\(reason)): trying once a second")
                    } else {
                        Log.red("cannot connect to the hub at \(path) (\(reason)): trying once a second")
                    }
                    lastError = error
                }
                sleep(1)
                continue
            }
            lastError = -1
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var buffer = sendBuffer
            if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                Log.red("SO_SNDBUF \(sendBuffer) refused (\(String(cString: strerror(errno))))")
            }
            var deadline = timeval(tv_sec: 5, tv_usec: 0)
            if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size)) != 0 {
                Log.red("SO_SNDTIMEO refused (\(String(cString: strerror(errno))))")
            }
            queue.linkUp()
            host.connected()
            Log.info("connected to the hub at \(path)")
            _ = queue.enqueue(.control(host.helloMessage()))
            let readerDone = DispatchSemaphore(value: 0)
            let reader = Thread { [self] in
                readLoop(fd)
                readerDone.signal()
            }
            reader.name = "fakestream.reader"
            reader.qualityOfService = .userInteractive
            reader.start()
            while var item = queue.pop() {
                if !write(&item, to: fd) { break }
            }
            shutdown(fd, SHUT_RDWR)
            readerDone.wait()
            close(fd)
            host.linkClosed()
            if host.refused { return }
            Log.info("the hub's socket closed: connecting again once a second")
            sleep(1)
        }
    }

    private func connect(_ fd: Int32) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private func write(_ item: inout OutgoingItem, to fd: Int32) -> Bool {
        let now = LinkClock.nowNs().littleEndian
        let headers = item.headers
        item.data.withUnsafeMutableBytes { raw in
            for header in headers where header + DMStream.headerSize <= raw.count {
                raw.storeBytes(of: now, toByteOffset: header + 8, as: UInt64.self)
            }
        }
        return item.data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    Log.red("the hub has read nothing for 5 s: closing its socket")
                    return false
                }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func readLoop(_ fd: Int32) {
        var header = Data(count: DMStream.headerSize)
        while readAll(fd, into: &header) {
            guard let parsed = try? DMStream.Header(header) else { break }
            guard parsed.length <= UInt32(DMStream.maxPayload) else {
                Log.red("the hub sent a message of \(parsed.length) bytes (type \(parsed.type)), over the 8 MB limit: closing")
                break
            }
            var payload = Data(count: Int(parsed.length))
            if parsed.length > 0 && !readAll(fd, into: &payload) { break }
            let message: DMStream.Message
            do {
                message = try DMStream.decode(type: parsed.type, flags: parsed.flags, payload: payload, direction: .fromHub)
            } catch {
                if host.undecodable(type: parsed.type, length: parsed.length) { continue }
                break
            }
            if !host.handle(message) { break }
        }
        shutdown(fd, SHUT_RDWR)
        queue.markBroken()
    }

    private func readAll(_ fd: Int32, into data: inout Data) -> Bool {
        data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = read(fd, base + offset, raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }
}
