import Foundation
import HorizonLink

public struct HubGames: Sendable {
    public var catalog: @Sendable () -> (profiles: [LinkProfile], games: [LinkGame])
    public var state: @Sendable () -> LinkState
    public var open: @Sendable (_ profile: String, _ game: String) -> String?
    public var close: @Sendable () -> Void
    public var gameProcess: @Sendable () -> ProcessIdentity?

    public init(
        catalog: @escaping @Sendable () -> (profiles: [LinkProfile], games: [LinkGame]),
        state: @escaping @Sendable () -> LinkState,
        open: @escaping @Sendable (_ profile: String, _ game: String) -> String?,
        close: @escaping @Sendable () -> Void,
        gameProcess: @escaping @Sendable () -> ProcessIdentity?
    ) {
        self.catalog = catalog
        self.state = state
        self.open = open
        self.close = close
        self.gameProcess = gameProcess
    }
}

public struct BridgeSettings: Sendable {
    public var socketPath: String
    public var server: LinkServer.Settings
    public var bitrateKbps: UInt32 = 25000
    public var feedbackTimeoutNs: UInt64 = 1_000_000_000
    public var sender = VideoSenderSettings()
    public var logDirectory: String?

    public init(socketPath: String, server: LinkServer.Settings) {
        self.socketPath = socketPath
        self.server = server
    }
}

public struct BridgeStatus: Sendable, Equatable {
    public var listening = false
    public var port: UInt16 = 0
    public var mediaPort: UInt16 = 0
    public var hostConnected = false
    public var hostBuild: String?
    public var clients: [String] = []
    public var attachedClient: String?
    public var clientAddress: String?
    public var stalled = false
    public var attachResult: DMStream.AttachResult?
    public var framesSent: UInt64 = 0
    public var bytesSent: UInt64 = 0
    public var repairs: UInt64 = 0
    public var refreshes: UInt64 = 0
    public var lostFrames: UInt32 = 0
    public var decodeP95Us: UInt32 = 0
    public var lastBoundMs: Double?
    public var hostStats: String?
    public var awaitingCode: String?
    public var pairingMessage: String?

    public init() {}
}

public final class StreamBridge: @unchecked Sendable {
    public enum Event: Sendable {
        case status(BridgeStatus)
        case notice(String)
    }

    public let settings: BridgeSettings
    public let server: LinkServer
    private let games: HubGames
    private let events: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.bridge", qos: .userInteractive)
    private var socket: StreamSocket?
    private var sender: VideoSender
    private var hello: DMStream.HostHello?
    private var attached: (peer: LinkPeer, attach: DMStream.Attach)?
    private var lastFeedbackNs: UInt64 = 0
    private var refreshSeen: [UUID: UInt32] = [:]
    private var ackedTokens: [Int64] = []
    private var lastPad: [UInt8: UInt32] = [:]
    private var audioSequence: UInt32 = 0
    private var status = BridgeStatus()
    private var watchdog: DispatchSourceTimer?
    private var log: FrameLog?
    private var presents: [UInt32: UInt64] = [:]
    private var ticks = 0

    public init(
        settings: BridgeSettings, identity: LinkIdentity, store: PairingStore, gate: PairingGate = PairingGate(), games: HubGames,
        events: @escaping @Sendable (Event) -> Void
    ) {
        self.settings = settings
        self.games = games
        self.events = events
        sender = VideoSender(settings: settings.sender)
        let relay = Relay()
        server = LinkServer(identity: identity, store: store, gate: gate, settings: settings.server) { relay.forward($0) }
        relay.target = self
    }

    public var gate: PairingGate { server.gate }

    public var currentStatus: BridgeStatus { queue.sync { status } }

    public func start() throws {
        let socket = StreamSocket(
            path: settings.socketPath,
            accepts: { [games] identity in games.gameProcess() == identity },
            events: { [weak self] event in
                guard let self else { return }
                queue.async { self.host(event) }
            }
        )
        try socket.start()
        do { try server.start() } catch {
            socket.stop()
            throw error
        }
        if let directory = settings.logDirectory { log = FrameLog(directory: directory) }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 0.1, repeating: 0.1)
        watchdog.setEventHandler { [weak self] in self?.checkFeedback() }
        watchdog.resume()
        queue.sync {
            self.socket = socket
            self.watchdog = watchdog
        }
    }

    public func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            if attached != nil { socket?.send(.detach(pause: true)) }
            attached = nil
            socket?.stop()
            socket = nil
            log?.close()
            log = nil
        }
        server.stop()
    }

    public func openPairing() {
        server.gate.open()
        queue.async { [self] in
            status.pairingMessage = "Open HorizonTV on the Apple TV and choose this Mac"
            publish()
        }
    }

    public func closePairing() {
        server.gate.close()
        server.cancelPairing()
        queue.async { [self] in
            status.awaitingCode = nil
            status.pairingMessage = nil
            publish()
        }
    }

    public func submitCode(_ code: String) {
        server.submitCode(code)
    }

    public func gamesChanged() {
        queue.async { [self] in
            let catalog = games.catalog()
            server.broadcast(.catalog(profiles: catalog.profiles, games: catalog.games))
            server.broadcast(.state(linkState()))
        }
    }

    public func unpair(_ key: Data) throws {
        try server.store.remove(key: key)
        for peer in server.peers where peer.key == key { server.disconnect(peer) }
    }

    fileprivate func linkEvent(_ event: LinkServer.Event) {
        if case .media(let peer, let channel, let data, let receivedNs) = event {
            queue.async { [self] in media(peer, channel, data, receivedNs: receivedNs) }
            return
        }
        queue.async { [self] in control(event) }
    }

    private func linkState() -> LinkState {
        var state = games.state()
        state.streaming = attached != nil && status.hostConnected && status.attachResult?.ok != false
        state.paused = status.stalled
        return state
    }

    private func publish() {
        status.clients = server.peers.map(\.name)
        status.attachedClient = attached?.peer.name
        status.clientAddress = attached?.peer.address?.description
        events(.status(status))
    }

    private func host(_ event: StreamSocket.Event) {
        switch event {
        case .connected:
            status.hostConnected = true
            status.attachResult = nil
            publish()
        case .refused(let pid):
            events(.notice("process \(pid) tried to open the video socket and was refused"))
        case .disconnected(let reason):
            status.hostConnected = false
            status.hostBuild = nil
            hello = nil
            log?.event("host-disconnected", reason)
            server.broadcast(.state(linkState()))
            publish()
        case .message(let header, let message):
            hostMessage(header, message)
        }
    }

    private func hostMessage(_ header: DMStream.Header, _ message: DMStream.Message) {
        switch message {
        case .hostHello(let hello):
            self.hello = hello
            status.hostBuild = hello.build
            if let attached { sendAttach(attached.attach) }
            publish()
        case .videoConfig(let sets):
            sender.configure(sets)
            log?.event("config", "generation=\(sender.generation) sets=\(sets.count)")
        case .videoFrame(let frame):
            guard let attached, !status.stalled else { return }
            let received = LinkClock.nowNs()
            let packet = sender.packetize(frame)
            attached.peer.pacer.sendBulk(packet.data + packet.parity, channel: .video)
            status.framesSent += 1
            status.bytesSent += UInt64(packet.payloadBytes)
            presents[packet.frame] = frame.presentNs
            if presents.count > 600, let oldest = presents.keys.min() { presents[oldest] = nil }
            log?.frame(
                link: packet.frame, video: frame, payload: packet.payloadBytes, data: packet.data.count, parity: packet.parity.count,
                sentNs: header.sentNs, receivedNs: received, queued: attached.peer.pacer.queuedBulk
            )
        case .audio(let audio):
            guard let attached, !status.stalled else { return }
            audioSequence &+= 1
            attached.peer.pacer.send(
                AudioPacket(hostTimeNs: audio.hostTimeNs, sequence: audioSequence, samples: audio.samples).encoded(), channel: .audio
            )
        case .attachResult(let result):
            status.attachResult = result
            log?.event("attach-result", "ok=\(result.ok) \(result.width)x\(result.height) \(result.reason)")
            if let attached {
                if !result.ok {
                    server.send(.notice("The game did not start the video: \(result.reason)"), to: attached.peer)
                } else if !result.reason.isEmpty {
                    server.send(.notice("The game adjusted the video: \(result.reason)"), to: attached.peer)
                }
            }
            server.broadcast(.state(linkState()))
            publish()
        case .stats(let text):
            status.hostStats = text
        default:
            break
        }
    }

    private func sendAttach(_ attach: DMStream.Attach) {
        var attach = attach
        if attach.bitrateKbps == 0 { attach.bitrateKbps = settings.bitrateKbps }
        if let hello, !hello.codecs.contains(attach.codec), let first = hello.codecs.first { attach.codec = first }
        sender.resendConfiguration()
        socket?.send(.attach(attach))
        log?.event("attach", "\(attach.width)x\(attach.height)@\(attach.refreshHz) kbps=\(attach.bitrateKbps)")
    }

    private func control(_ event: LinkServer.Event) {
        switch event {
        case .listening(let port, let mediaPort):
            status.listening = true
            status.port = port
            status.mediaPort = mediaPort
            publish()
        case .failed(let reason):
            status.listening = false
            events(.notice(reason))
            publish()
        case .codeNeeded(let name):
            status.awaitingCode = name
            status.pairingMessage = "Enter the code shown on \(name)"
            publish()
        case .pairingFinished(let name, let paired, let reason):
            status.awaitingCode = nil
            status.pairingMessage = paired ? "\(name) paired" : "Pairing refused: \(reason)"
            publish()
        case .connected(let peer):
            let catalog = games.catalog()
            server.send(.catalog(profiles: catalog.profiles, games: catalog.games), to: peer)
            server.send(.state(linkState()), to: peer)
            publish()
        case .control(let peer, let message):
            clientMessage(peer, message)
        case .moved(let peer, let address):
            log?.event("client-address", "\(peer.name) \(address)")
            publish()
        case .disconnected(let peer, let reason):
            if attached?.peer === peer {
                socket?.send(.detach(pause: true))
                attached = nil
                status.stalled = false
                log?.event("client-disconnected", reason)
            }
            refreshSeen[peer.id] = nil
            publish()
        case .refused(let reason):
            log?.event("refused", reason)
        case .media:
            break
        }
    }

    private func clientMessage(_ peer: LinkPeer, _ message: ControlMessage) {
        switch message {
        case .attach(let attach):
            if let previous = attached, previous.peer !== peer {
                server.send(.notice("Another device took over the game"), to: previous.peer)
                previous.peer.pacer.clearBulk()
            }
            attached = (peer, attach)
            status.stalled = false
            status.attachResult = nil
            lastFeedbackNs = LinkClock.nowNs()
            refreshSeen[peer.id] = nil
            ackedTokens.removeAll()
            lastPad.removeAll()
            if hello != nil { sendAttach(attach) }
            server.broadcast(.state(linkState()))
            publish()
        case .detach(let pause):
            guard attached?.peer === peer else { return }
            socket?.send(.detach(pause: pause))
            peer.pacer.clearBulk()
            attached = nil
            status.stalled = false
            log?.event("detach", "pause=\(pause)")
            server.broadcast(.state(linkState()))
            publish()
        case .open(let profile, let game):
            if let error = games.open(profile, game) { server.send(.notice(error), to: peer) }
            gamesChanged()
        case .close:
            games.close()
            gamesChanged()
        case .pads(let pads):
            guard attached?.peer === peer else { return }
            lastPad.removeAll()
            socket?.send(.pads(pads))
        case .bitrate(let kbps):
            guard attached?.peer === peer else { return }
            socket?.send(.bitrate(kbps))
            log?.event("bitrate", "\(kbps)")
        case .stats(let text):
            log?.event("client-stats", text)
        default:
            break
        }
    }

    private func media(_ peer: LinkPeer, _ channel: MediaChannel, _ data: Data, receivedNs: UInt64) {
        switch channel {
        case .ping:
            guard let ping = try? PingPacket(data) else { return }
            peer.pacer.send(
                PongPacket(sequence: ping.sequence, clientSendNs: ping.clientSendNs, hubReceiveNs: receivedNs, hubSendNs: LinkClock.nowNs())
                    .encoded(),
                channel: .pong
            )
        case .nack:
            guard attached?.peer === peer, let nack = try? NackPacket(data) else { return }
            let repair = sender.repair(nack)
            for datagram in repair { peer.pacer.send(datagram, channel: .video) }
            status.repairs += 1
            log?.event("nack", "frame=\(nack.frame) needs=\(nack.needs.map { "\($0.block):\($0.count)" }.joined(separator: ",")) sent=\(repair.count)")
        case .feedback:
            guard attached?.peer === peer, let feedback = try? FeedbackPacket(data) else { return }
            feedbackArrived(peer, feedback)
        case .decoded:
            guard let decoded = try? DecodedPacket(data) else { return }
            if let present = presents[decoded.frame] {
                status.lastBoundMs = Double(receivedNs &- present) / 1e6
                log?.decoded(link: decoded.frame, echoNs: receivedNs, presentNs: present)
            }
        case .pad:
            guard attached?.peer === peer, let packet = try? PadPacket(data) else { return }
            if let last = lastPad[packet.pad.player], !VideoShards.precedes(last, packet.sequence) { return }
            lastPad[packet.pad.player] = packet.sequence
            socket?.send(.pad(packet.pad))
        default:
            break
        }
    }

    private func feedbackArrived(_ peer: LinkPeer, _ feedback: FeedbackPacket) {
        lastFeedbackNs = LinkClock.nowNs()
        status.lostFrames = feedback.lostFrames
        status.decodeP95Us = feedback.decodeP95Us
        if status.stalled, let attached {
            status.stalled = false
            log?.event("resume", "feedback is back")
            sendAttach(attached.attach)
            server.broadcast(.state(linkState()))
            publish()
        }
        let fresh = feedback.ltrAcks.filter { !ackedTokens.contains($0) }
        if !fresh.isEmpty {
            ackedTokens += fresh
            if ackedTokens.count > 256 { ackedTokens.removeFirst(ackedTokens.count - 256) }
            socket?.send(.ltrAck(fresh))
        }
        let seen = refreshSeen[peer.id] ?? 0
        if feedback.refreshRequest != seen {
            refreshSeen[peer.id] = feedback.refreshRequest
            if VideoShards.precedes(seen, feedback.refreshRequest) {
                socket?.send(.refresh)
                sender.resendConfiguration()
                status.refreshes += 1
                log?.event("refresh", "request=\(feedback.refreshRequest) lost=\(feedback.lostFrames)")
            }
        }
    }

    private func checkFeedback() {
        ticks += 1
        if ticks % 10 == 0, attached != nil { publish() }
        guard let attached, !status.stalled else { return }
        guard LinkClock.nowNs() &- lastFeedbackNs > settings.feedbackTimeoutNs else { return }
        status.stalled = true
        socket?.send(.detach(pause: true))
        attached.peer.pacer.clearBulk()
        log?.event("stall", "no feedback for \(settings.feedbackTimeoutNs / 1_000_000) ms")
        server.send(.state(linkState()), to: attached.peer)
        publish()
    }
}

private final class Relay: @unchecked Sendable {
    weak var target: StreamBridge?

    func forward(_ event: LinkServer.Event) {
        target?.linkEvent(event)
    }
}

final class FrameLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.frame-log", qos: .utility)
    private var handle: FileHandle?

    init(directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/stream-" + GuardState.format("yyyy-MM-dd-HHmmss", Date()) + ".tsv"
        FileManager.default.createFile(atPath: path, contents: Data("event\tlink_frame\tdm_frame\tflags\tbytes\tdata\tparity\tpresent_ns\tdm_sent_ns\thub_recv_ns\tqueued\tdetail\n".utf8))
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    func frame(
        link: UInt32, video: DMStream.VideoFrame, payload: Int, data: Int, parity: Int, sentNs: UInt64, receivedNs: UInt64, queued: Int
    ) {
        write("frame\t\(link)\t\(video.frameNumber)\t\(video.flags.rawValue)\t\(payload)\t\(data)\t\(parity)\t\(video.presentNs)\t\(sentNs)\t\(receivedNs)\t\(queued)\t")
    }

    func decoded(link: UInt32, echoNs: UInt64, presentNs: UInt64) {
        write("decoded\t\(link)\t\t\t\t\t\t\(presentNs)\t\t\(echoNs)\t\tbound_ms=\(String(format: "%.3f", Double(echoNs &- presentNs) / 1e6))")
    }

    func event(_ name: String, _ detail: String) {
        write("\(name)\t\t\t\t\t\t\t\t\t\(LinkClock.nowNs())\t\t\(detail.replacingOccurrences(of: "\t", with: " "))")
    }

    private func write(_ line: String) {
        queue.async { [self] in handle?.write(Data((line + "\n").utf8)) }
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }
}
