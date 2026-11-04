import Darwin
import Foundation
import HorizonLink
import Testing
@testable import HubKit

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StreamSocket.Event] = []

    func add(_ event: StreamSocket.Event) { lock.withLock { events.append(event) } }

    var all: [StreamSocket.Event] { lock.withLock { events } }

    var connections: Int { all.filter { if case .connected = $0 { true } else { false } }.count }
    var disconnections: Int { all.filter { if case .disconnected = $0 { true } else { false } }.count }
    var refusals: Int { all.filter { if case .refused = $0 { true } else { false } }.count }
    var messages: [DMStream.Message] { all.compactMap { if case .message(_, let message) = $0 { message } else { nil } } }
}

struct FakeHost {
    let descriptor: Int32
    private var parser = DMStream.Parser(direction: .fromHub)

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw Timeout()
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ message: DMStream.Message) {
        let data = DMStream.encode(message)
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    mutating func next() throws -> DMStream.Message? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let next = try parser.next() { return next.message }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { return nil }
            parser.append(Data(buffer[0..<count]))
        }
    }

    func close() { Darwin.close(descriptor) }
}

struct StreamSocketTests {
    let hello = DMStream.HostHello(titleId: 0x0100_0000_0000_0000, width: 1920, height: 1080, codecs: [DMStream.Codec.avc1.rawValue], build: "test")

    func makeSocket(accepts: Bool = true) throws -> (StreamSocket, EventLog, String) {
        let directory = try makeShortDirectory()
        let log = EventLog()
        let socket = StreamSocket(path: directory + "/s.sock", accepts: { _ in accepts }, events: { log.add($0) })
        try socket.start()
        return (socket, log, directory)
    }

    @Test func aGameThatConnectsIsGreetedAndHeard() async throws {
        let (socket, log, directory) = try makeSocket()
        defer {
            socket.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
        var host = try FakeHost(path: socket.path)
        #expect(try host.next() == .hubHello(DMStream.version))
        host.send(.hostHello(hello))
        host.send(.videoConfig([Data([0x67, 1]), Data([0x68, 2])]))
        try await waitUntil { log.messages.count == 2 }
        #expect(log.messages == [.hostHello(hello), .videoConfig([Data([0x67, 1]), Data([0x68, 2])])])
        #expect(log.connections == 1)
        #expect(socket.isConnected)

        let attach = DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 25000)
        socket.send(.attach(attach))
        socket.send(.detach(pause: true))
        #expect(try host.next() == .attach(attach))
        #expect(try host.next() == .detach(pause: true))

        host.close()
        try await waitUntil { log.disconnections == 1 }
        #expect(!socket.isConnected)
    }

    @Test func anotherProcessIsRefused() async throws {
        let (socket, log, directory) = try makeSocket(accepts: false)
        defer {
            socket.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
        var host = try FakeHost(path: socket.path)
        #expect(try host.next() == nil)
        host.close()
        try await waitUntil { log.refusals == 1 }
        #expect(log.connections == 0)
        #expect(!socket.isConnected)
    }

    @Test func aReconnectionReplacesTheOldConnection() async throws {
        let (socket, log, directory) = try makeSocket()
        defer {
            socket.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
        var first = try FakeHost(path: socket.path)
        #expect(try first.next() == .hubHello(DMStream.version))
        var second = try FakeHost(path: socket.path)
        #expect(try second.next() == .hubHello(DMStream.version))
        #expect(try first.next() == nil)
        first.close()
        try await waitUntil { log.connections == 2 }
        second.send(.stats("fps=60"))
        try await waitUntil { log.messages.contains(.stats("fps=60")) }
        #expect(log.disconnections == 0)
        #expect(socket.isConnected)
        second.close()
        try await waitUntil { log.disconnections == 1 }
    }

    @Test func aBrokenStreamDropsTheGame() async throws {
        let (socket, log, directory) = try makeSocket()
        defer {
            socket.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
        var host = try FakeHost(path: socket.path)
        #expect(try host.next() == .hubHello(DMStream.version))
        var header = ByteWriter()
        header.u32(UInt32(DMStream.maxPayload + 1))
        header.u16(DMStream.Kind.videoFrame.rawValue)
        header.u16(0)
        header.u64(0)
        _ = header.data.withUnsafeBytes { Darwin.write(host.descriptor, $0.baseAddress, $0.count) }
        try await waitUntil { log.disconnections == 1 }
        #expect(try host.next() == nil)
        host.close()
    }

    @Test func stoppingRemovesTheSocket() throws {
        let (socket, _, directory) = try makeSocket()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(FileManager.default.fileExists(atPath: socket.path))
        socket.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(throws: (any Error).self) { try FakeHost(path: socket.path) }
    }

    @Test func aLongPathIsRefusedBeforeListening() {
        let socket = StreamSocket(path: "/tmp/" + String(repeating: "x", count: 120), accepts: { _ in true }, events: { _ in })
        #expect(throws: GamesError.self) { try socket.start() }
    }
}
