import Darwin
import Foundation
import HorizonLink
import Network
import Testing
@testable import HubKit

final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value { lock.withLock { value } }

    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

final class HostPeer: @unchecked Sendable {
    let host: FakeHost
    let received = Box<[DMStream.Message]>([])

    init(path: String) throws {
        host = try FakeHost(path: path)
        let host = self.host
        let received = self.received
        Thread {
            var reader = host
            while let message = try? reader.next() { received.update { $0.append(message) } }
        }.start()
    }

    func count(_ match: (DMStream.Message) -> Bool) -> Int { received.current.filter(match).count }

    func send(_ message: DMStream.Message) { host.send(message) }

    func close() { host.close() }
}

struct BridgeRig {
    let directory: String
    let bridge: StreamBridge
    let opened = Box<[String]>([])
    let notices = Box<[String]>([])
    let status = Box(BridgeStatus())
    let hubs = Box<[Data: Data]>([:])

    init(directory: String? = nil, identity: LinkIdentity = LinkIdentity(), feedbackTimeoutNs: UInt64 = 600_000_000) throws {
        self.directory = try directory ?? makeShortDirectory()
        var server = LinkServer.Settings(hubName: "Test Mac")
        server.advertise = false
        var settings = BridgeSettings(socketPath: self.directory + "/s.sock", server: server)
        settings.logDirectory = self.directory + "/logs"
        settings.feedbackTimeoutNs = feedbackTimeoutNs
        let me = ProcessIdentity.of(getpid())
        let opened = self.opened
        let games = HubGames(
            catalog: { ([LinkProfile(id: "test", name: "Test", nick: "T")], [LinkGame(id: "dk", title: "DK", status: .available)]) },
            state: { LinkState(game: "dk", title: "DK", profile: "test") },
            open: { profile, game in
                opened.update { $0.append("\(profile)/\(game)") }
                return game == "mkw" ? "MKW blocked" : nil
            },
            close: { opened.update { $0.append("close") } },
            gameProcess: { me }
        )
        let notices = self.notices
        let status = self.status
        bridge = StreamBridge(
            settings: settings, identity: identity, store: PairingStore(file: self.directory + "/clients.json"), games: games
        ) { event in
            switch event {
            case .status(let value): status.update { $0 = value }
            case .notice(let text): notices.update { $0.append(text) }
            }
        }
        try bridge.start()
    }

    func client(
        name: String = "Test TV", identity: LinkIdentity = LinkIdentity(), drop: LinkDrop = LinkDrop(), events: Box<[LinkClient.Event]>
    ) -> LinkClient {
        var settings = LinkClientSettings(name: name)
        settings.drop = drop
        let hubs = self.hubs
        return LinkClient(identity: identity, settings: settings, knownHub: { id in hubs.current[id] }) { event in
            if case .paired(let id, let key, _) = event { hubs.update { $0[id] = key } }
            events.update { $0.append(event) }
        }
    }

    func endpoint() async throws -> NWEndpoint {
        try await waitUntil { status.current.port != 0 }
        return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: status.current.port) ?? .any)
    }

    func pair(_ client: LinkClient, events: Box<[LinkClient.Event]>) async throws {
        bridge.openPairing()
        client.connect(to: try await endpoint())
        try await waitUntil { events.current.contains { if case .needsPairing = $0 { true } else { false } } }
        client.pair()
        try await waitUntil { status.current.awaitingCode != nil }
        let code = events.current.compactMap { if case .showCode(let code) = $0 { code } else { nil } }.last ?? ""
        bridge.submitCode(code)
        try await waitUntil { events.current.contains { if case .established = $0 { true } else { false } } }
    }

    func remove() {
        bridge.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

func videos(_ events: Box<[LinkClient.Event]>) -> [ReceivedVideo] {
    events.current.compactMap { if case .video(let video) = $0 { video } else { nil } }
}

let hostHello = DMStream.HostHello(titleId: 1, width: 1920, height: 1080, codecs: [DMStream.Codec.avc1.rawValue], build: "fake")

func play(_ host: HostPeer, frames: Range<Int>, size: Int = 20_000, refreshAfter: (() -> Bool)? = nil) async throws {
    for index in frames {
        var flags: DMStream.FrameFlags = index == 0 ? [.sync] : []
        if let refreshAfter, refreshAfter() { flags.insert(.refresh) }
        host.send(.videoFrame(DMStream.VideoFrame(
            presentNs: LinkClock.nowNs(), frameNumber: UInt64(index + 1), ltrToken: Int64(index % 4 == 0 ? index : -1), flags: flags,
            accessUnit: Data(repeating: UInt8(index % 251), count: size)
        )))
        host.send(.audio(DMStream.Audio(hostTimeNs: LinkClock.nowNs(), frameCount: 240, samples: Data(count: 960))))
        try await Task.sleep(for: .milliseconds(16))
    }
}

func start(_ host: HostPeer, rig: BridgeRig) async throws {
    try await waitUntil { host.count { if case .hubHello = $0 { true } else { false } } == 1 }
    host.send(.hostHello(hostHello))
    try await waitUntil { rig.status.current.hostBuild == "fake" }
}

struct BridgeTests {
    @Test func aPairedTVWatchesTheGameInOrder() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        try await waitUntil { events.current.contains { if case .control(.catalog) = $0 { true } else { false } } }

        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        try await waitUntil { host.count { if case .attach = $0 { true } else { false } } == 1 }
        guard case .attach(let attach)? = host.received.current.last(where: { if case .attach = $0 { true } else { false } }) else { return }
        #expect(attach.bitrateKbps == 25000)
        host.send(.attachResult(DMStream.AttachResult(ok: true, width: 1920, height: 1080, codec: attach.codec)))
        host.send(.videoConfig([Data([0x67, 7]), Data([0x68, 7])]))
        try await play(host, frames: 0..<60)
        try await waitUntil { videos(events).count == 60 }
        let received = videos(events)
        #expect(received.map(\.envelope.frameNumber) == Array(1...60))
        #expect(received.allSatisfy { $0.parameterSets == [Data([0x67, 7]), Data([0x68, 7])] })
        #expect(received.first?.isSync == true)
        #expect(events.current.contains { if case .audio = $0 { true } else { false } })

        for video in received { client.decoded(frame: video.frame, ltrToken: video.envelope.ltrToken, at: LinkClock.nowNs(), decodeMicroseconds: 900) }
        try await waitUntil { host.received.current.contains { if case .ltrAck(let tokens) = $0 { tokens.contains(56) } else { false } } }
        try await waitUntil { rig.status.current.lastBoundMs != nil }
        #expect(client.stats.roundTripNs != nil)

        client.send(.open(profile: "test", game: "mkw"))
        try await waitUntil { events.current.contains { if case .control(.notice("MKW blocked")) = $0 { true } else { false } } }
        #expect(rig.opened.current == ["test/mkw"])

        client.disconnect()
        try await waitUntil { host.count { if case .detach(pause: true) = $0 { true } else { false } } == 1 }
        let logs = try FileManager.default.contentsOfDirectory(atPath: rig.directory + "/logs")
        #expect(logs.count == 1)
    }

    @Test func randomLossIsRepairedWithoutAskingTheGame() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(drop: LinkDrop(mediaLoss: 0.02, seed: 11), events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        try await waitUntil { host.count { if case .attach = $0 { true } else { false } } == 1 }
        host.send(.videoConfig([Data([0x67, 1])]))
        try await play(host, frames: 0..<90, size: 40_000)
        try await waitUntil { videos(events).count == 90 }
        #expect(videos(events).map(\.envelope.frameNumber) == Array(1...90))
        #expect(client.stats.droppedBySimulation > 0)
        #expect(rig.status.current.repairs > 0 || client.stats.video.recoveredShards > 0)
        #expect(host.count { if case .refresh = $0 { true } else { false } } == 0)
    }

    @Test func aBurstAsksTheGameForARefresh() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(drop: LinkDrop(burstEvery: 100_000, burstLength: 0), events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        try await waitUntil { host.count { if case .attach = $0 { true } else { false } } == 1 }
        host.send(.videoConfig([Data([0x67, 1])]))
        try await play(host, frames: 0..<20)
        try await waitUntil { videos(events).count == 20 }
        let refreshes = { host.count { if case .refresh = $0 { true } else { false } } }
        client.requestRefresh()
        try await waitUntil { refreshes() == 1 }
        var answered = false
        try await play(host, frames: 20..<40) {
            guard !answered else { return false }
            answered = true
            return true
        }
        try await waitUntil { videos(events).count >= 21 }
        let after = videos(events).dropFirst(20)
        #expect(after.first?.isRefresh == true)
        #expect(after.first?.parameterSets == [Data([0x67, 1])])
    }

    @Test func aControllerThatComesBackIsHeardAgain() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        try await waitUntil { host.count { if case .attach = $0 { true } else { false } } == 1 }
        let one = DMStream.Pads(mask: 1, styles: [DMStream.styleProController] + Array(repeating: 0, count: 7))
        client.send(.pads(one))
        try await waitUntil { host.count { if case .pads = $0 { true } else { false } } == 1 }
        client.sendPad(PadPacket(sequence: 40, pad: DMStream.Pad(player: 0, buttons: DMStream.Button.a)))
        try await waitUntil { host.count { if case .pad(let pad) = $0 { pad.buttons == DMStream.Button.a } else { false } } == 1 }

        client.send(.pads(one))
        try await waitUntil { host.count { if case .pads = $0 { true } else { false } } == 2 }
        client.sendPad(PadPacket(sequence: 1, pad: DMStream.Pad(player: 0, buttons: DMStream.Button.b)))
        try await waitUntil { host.count { if case .pad(let pad) = $0 { pad.buttons == DMStream.Button.b } else { false } } == 1 }
    }

    @Test func controllersChosenBeforeTheGameStartsReachIt() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        let one = DMStream.Pads(mask: 1, styles: [DMStream.styleProController] + Array(repeating: 0, count: 7))
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        client.send(.pads(one))
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 20000)))
        client.send(.open(profile: "test", game: "dk"))
        try await waitUntil { rig.opened.current == ["test/dk"] }

        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        try await waitUntil { host.count { if case .pads(let pads) = $0 { pads == one } else { false } } == 1 }
        let messages = host.received.current
        let attach = try #require(messages.firstIndex { if case .attach(let attach) = $0 { attach.bitrateKbps == 20000 } else { false } })
        let pads = try #require(messages.firstIndex { if case .pads = $0 { true } else { false } })
        #expect(attach < pads)
        client.sendPad(PadPacket(sequence: 1, pad: DMStream.Pad(player: 0, buttons: DMStream.Button.a)))
        try await waitUntil { host.count { if case .pad(let pad) = $0 { pad.buttons == DMStream.Button.a } else { false } } == 1 }
    }

    @Test func controllersComeBackWhenAStalledClientResumes() async throws {
        let rig = try BridgeRig(feedbackTimeoutNs: 1_000_000)
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        let one = DMStream.Pads(mask: 1, styles: [DMStream.styleProController] + Array(repeating: 0, count: 7))
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        client.send(.pads(one))
        try await waitUntil {
            let messages = host.received.current
            let pads = messages.indices.filter { if case .pads(let pads) = messages[$0] { pads == one } else { false } }
            guard pads.count >= 2, let last = pads.last,
                  let detach = messages.firstIndex(where: { if case .detach(pause: true) = $0 { true } else { false } })
            else { return false }
            return detach < last
        }
    }

    @Test func aSilentClientPausesTheGame() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(drop: LinkDrop(feedbackLoss: 1, seed: 5), events: events)
        defer { client.disconnect() }
        try await rig.pair(client, events: events)
        let host = try HostPeer(path: rig.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: rig)
        client.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        try await waitUntil { host.count { if case .attach = $0 { true } else { false } } == 1 }
        try await waitUntil(within: 5) { host.count { if case .detach(pause: true) = $0 { true } else { false } } == 1 }
        #expect(rig.status.current.stalled)
        try await waitUntil { events.current.contains { if case .control(.state(let state)) = $0 { state.paused } else { false } } }
    }

    @Test func aPairedTVComesBackAfterTheHubRestarts() async throws {
        let hubIdentity = LinkIdentity()
        let tvIdentity = LinkIdentity()
        let first = try BridgeRig(identity: hubIdentity)
        let events = Box<[LinkClient.Event]>([])
        let client = first.client(identity: tvIdentity, events: events)
        try await first.pair(client, events: events)
        let known = first.hubs.current
        first.bridge.stop()
        try await waitUntil { events.current.contains { if case .disconnected = $0 { true } else { false } } }

        let second = try BridgeRig(directory: first.directory, identity: hubIdentity)
        defer { second.remove() }
        second.hubs.update { $0 = known }
        let again = Box<[LinkClient.Event]>([])
        let back = second.client(identity: tvIdentity, events: again)
        defer { back.disconnect() }
        back.connect(to: try await second.endpoint())
        try await waitUntil { again.current.contains { if case .established = $0 { true } else { false } } }
        #expect(!again.current.contains { if case .needsPairing = $0 { true } else { false } })

        let host = try HostPeer(path: second.bridge.settings.socketPath)
        defer { host.close() }
        try await start(host, rig: second)
        back.send(.attach(DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)))
        try await waitUntil { host.count { if case .attach = $0 { true } else { false } } == 1 }
        host.send(.videoConfig([Data([0x67, 3])]))
        try await play(host, frames: 0..<10)
        try await waitUntil { videos(again).count == 10 }
    }

    @Test func anUnknownTVIsRefusedWithoutThePairingWindow() async throws {
        let rig = try BridgeRig()
        defer { rig.remove() }
        let events = Box<[LinkClient.Event]>([])
        let client = rig.client(events: events)
        client.connect(to: try await rig.endpoint())
        try await waitUntil { events.current.contains { if case .needsPairing = $0 { true } else { false } } }
        client.pair()
        try await waitUntil {
            events.current.contains { if case .disconnected(let reason) = $0 { reason.contains("Pair a TV") } else { false } }
        }
    }
}
