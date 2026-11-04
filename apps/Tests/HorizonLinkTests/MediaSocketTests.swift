import CryptoKit
import Foundation
import Testing
@testable import HorizonLink

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Data, SocketAddress)] = []

    func add(_ data: Data, _ from: SocketAddress) { lock.withLock { items.append((data, from)) } }

    var all: [(Data, SocketAddress)] { lock.withLock { items } }
}

func eventually(within seconds: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition did not hold within \(seconds) s")
}

struct MediaSocketTests {
    @Test func addressesParseAndPrint() throws {
        let v4 = try #require(SocketAddress(host: "127.0.0.1", port: 5000))
        #expect(v4.port == 5000)
        #expect(v4.description == "127.0.0.1:5000")
        #expect(v4.mapped().host == "127.0.0.1")
        #expect(v4.mapped().port == 5000)
        let v6 = try #require(SocketAddress(host: "::1", port: 6000))
        #expect(v6.description == "[::1]:6000")
        #expect(SocketAddress(host: "not an address", port: 1) == nil)
    }

    @Test func datagramsCrossTheLoopbackOnBothFamilies() async throws {
        let server = try MediaSocket()
        let client = try MediaSocket()
        defer {
            server.close()
            client.close()
        }
        let inbox = Inbox()
        server.receive { inbox.add($0, $1) }
        for host in ["127.0.0.1", "::1"] {
            let target = try #require(SocketAddress(host: host, port: server.port))
            #expect(client.send(Data(host.utf8), to: target) == 0)
        }
        try await eventually { inbox.all.count == 2 }
        #expect(Set(inbox.all.map { String(decoding: $0.0, as: UTF8.self) }) == ["127.0.0.1", "::1"])
        #expect(inbox.all.allSatisfy { $0.1.port == client.port })
    }

    @Test func thePacerSealsInOrderAndPutsPriorityFirst() async throws {
        let server = try MediaSocket()
        let client = try MediaSocket()
        defer {
            server.close()
            client.close()
        }
        let inbox = Inbox()
        server.receive { inbox.add($0, $1) }
        let key = SymmetricKey(size: .bits256)
        let pacer = PacedSender(socket: client, settings: PacerSettings(burst: 4, gapMicroseconds: 100))
        defer { pacer.stop() }
        pacer.configure(key: key)
        pacer.sendBulk((0..<40).map { Data([UInt8($0)]) }, channel: .video)
        pacer.send(Data([0xAA]), channel: .audio)
        let destination = try #require(SocketAddress(host: "127.0.0.1", port: server.port))
        pacer.setDestination(destination)
        try await eventually { inbox.all.count == 41 }
        var opener = DatagramOpener(key: key)
        let opened = try inbox.all.map { try opener.open($0.0) }
        #expect(opened.first?.channel == MediaChannel.audio.rawValue)
        #expect(opened.dropFirst().map(\.plaintext) == (0..<40).map { Data([UInt8($0)]) })
        #expect(pacer.stats.sent == 41)
        #expect(pacer.stats.failed == 0)
    }

    @Test func aFullBulkQueueDropsTheExcess() {
        let socket = try? MediaSocket()
        guard let socket else {
            Issue.record("no socket")
            return
        }
        defer { socket.close() }
        let pacer = PacedSender(socket: socket, bulkLimit: 10)
        defer { pacer.stop() }
        pacer.configure(key: SymmetricKey(size: .bits256))
        pacer.sendBulk((0..<15).map { _ in Data([1]) }, channel: .video)
        #expect(pacer.queuedBulk == 10)
        #expect(pacer.stats.dropped == 5)
        pacer.clearBulk()
        #expect(pacer.queuedBulk == 0)
    }
}
