import Foundation
import Network

public struct LinkDrop: Sendable, Equatable {
    public var mediaLoss: Double
    public var feedbackLoss: Double
    public var burstEvery: Int
    public var burstLength: Int
    public var seed: UInt64

    public init(mediaLoss: Double = 0, feedbackLoss: Double = 0, burstEvery: Int = 0, burstLength: Int = 0, seed: UInt64 = 1) {
        self.mediaLoss = mediaLoss
        self.feedbackLoss = feedbackLoss
        self.burstEvery = burstEvery
        self.burstLength = burstLength
        self.seed = seed
    }

    public var isActive: Bool { mediaLoss > 0 || feedbackLoss > 0 || (burstEvery > 0 && burstLength > 0) }
}

struct DropDice: Sendable {
    private var state: UInt64
    private let drop: LinkDrop
    private var media = 0

    init(_ drop: LinkDrop) {
        self.drop = drop
        state = drop.seed
    }

    private mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((value ^ (value >> 31)) >> 11) / Double(1 << 53)
    }

    mutating func dropsMedia() -> Bool {
        media += 1
        if drop.burstEvery > 0, drop.burstLength > 0, media % drop.burstEvery < drop.burstLength { return true }
        return drop.mediaLoss > 0 && unit() < drop.mediaLoss
    }

    mutating func dropsFeedback() -> Bool {
        drop.feedbackLoss > 0 && unit() < drop.feedbackLoss
    }
}

public struct LinkClientSettings: Sendable {
    public var name: String
    public var receiver = VideoReceiverSettings()
    public var feedbackIntervalNs: UInt64 = 20_000_000
    public var pingIntervalNs: UInt64 = 250_000_000
    public var helloIntervalNs: UInt64 = 1_000_000_000
    public var keepaliveIntervalNs: UInt64 = 2_000_000_000
    public var tickMicroseconds = 1000
    public var drop = LinkDrop()

    public init(name: String) {
        self.name = name
    }
}

public struct LinkClientStats: Sendable, Equatable {
    public var video = VideoReceiverStats()
    public var audioPackets: UInt64 = 0
    public var openFailures: UInt64 = 0
    public var droppedBySimulation: UInt64 = 0
    public var roundTripNs: Int64?
    public var offsetNs: Int64?
    public var decodedFrames: UInt64 = 0
}

public final class LinkClient: @unchecked Sendable {
    public enum Event: Sendable {
        case needsPairing(hubName: String)
        case showCode(String)
        case paired(hubId: Data, hubKey: Data, hubName: String)
        case pairingFailed(String)
        case established(Welcome)
        case control(ControlMessage)
        case video(ReceivedVideo)
        case audio(AudioPacket, receivedNs: UInt64)
        case disconnected(String)
    }

    public let identity: LinkIdentity
    public let settings: LinkClientSettings
    private let events: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.link-client", qos: .userInteractive)
    private let lock = NSLock()
    private let delivery = NSRecursiveLock()
    private var link: ClientLink
    private var connection: NWConnection?
    private var framer = LinkFramer(limit: LinkProtocol.maxSecureMessage)
    private var socket: MediaSocket?
    private var pacer: PacedSender?
    private var hubAddress: SocketAddress?
    private var opener: DatagramOpener?
    private var receiver: VideoReceiver
    private var clock = ClockSync()
    private var dice: DropDice
    private var timer: DispatchSourceTimer?
    private var welcome: Welcome?
    private var ended = false
    private var counters = LinkClientStats()
    private var lastDecoded: UInt32 = 0
    private var acks: [Int64] = []
    private var decodeTimes: [UInt32] = []
    private var pingSequence: UInt32 = 0
    private var lastFeedbackNs: UInt64 = 0
    private var lastPingNs: UInt64 = 0
    private var lastHelloNs: UInt64 = 0
    private var lastKeepaliveNs: UInt64 = 0
    private var sentRefresh: UInt32 = 0

    public init(
        identity: LinkIdentity, settings: LinkClientSettings, knownHub: @escaping @Sendable (Data) -> Data?,
        events: @escaping @Sendable (Event) -> Void
    ) {
        self.identity = identity
        self.settings = settings
        self.events = events
        link = ClientLink(identity: identity, name: settings.name, knownHub: knownHub)
        receiver = VideoReceiver(settings: settings.receiver)
        dice = DropDice(settings.drop)
    }

    public var stats: LinkClientStats {
        lock.withLock {
            var stats = counters
            stats.video = receiver.stats
            stats.roundTripNs = clock.roundTripNs
            stats.offsetNs = clock.offsetNs
            return stats
        }
    }

    public var hubWelcome: Welcome? { lock.withLock { welcome } }

    public func hubTime(clientNs: UInt64) -> UInt64? { lock.withLock { clock.hubTime(clientNs: clientNs) } }

    public func clientTime(hubNs: UInt64) -> UInt64? { lock.withLock { clock.clientTime(hubNs: hubNs) } }

    public func connect(to endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.serviceClass = .interactiveVideo
        let connection = NWConnection(to: endpoint, using: parameters)
        queue.async { [self] in
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    handle(link.start())
                case .failed(let error):
                    finish("the connection to the Mac failed: \(error)")
                case .waiting(let error):
                    finish("the Mac did not respond: \(error)")
                case .cancelled:
                    finish("the connection to the Mac closed")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receive(connection)
        }
    }

    public func pair() {
        queue.async { [self] in handle(link.pair()) }
    }

    public func send(_ message: ControlMessage) {
        queue.async { [self] in
            guard link.isEstablished, let body = try? link.seal(message) else { return }
            write(body)
        }
    }

    public func disconnect() {
        queue.async { [self] in finish("disconnected") }
    }

    public func decoded(frame: UInt32, ltrToken: Int64, at decodedNs: UInt64, decodeMicroseconds: UInt32) {
        let pacer = lock.withLock { () -> PacedSender? in
            if VideoShards.precedes(lastDecoded, frame) || lastDecoded == 0 { lastDecoded = frame }
            counters.decodedFrames += 1
            if ltrToken >= 0, !acks.contains(ltrToken) {
                acks.append(ltrToken)
                if acks.count > FeedbackPacket.maxAcks { acks.removeFirst(acks.count - FeedbackPacket.maxAcks) }
            }
            decodeTimes.append(decodeMicroseconds)
            if decodeTimes.count > 120 { decodeTimes.removeFirst(decodeTimes.count - 120) }
            return dice.dropsFeedback() ? nil : self.pacer
        }
        pacer?.send(DecodedPacket(frame: frame, decodedNs: decodedNs).encoded(), channel: .decoded)
    }

    public func requestRefresh() {
        let now = LinkClock.nowNs()
        delivery.withLock { handle(lock.withLock { receiver.requestRefresh(now: now) }, now: now) }
    }

    public func sendPad(_ pad: PadPacket) {
        lock.withLock { pacer }?.send(pad.encoded(), channel: .pad)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                framer.append(data)
                do {
                    while let body = try framer.next() { handle(try link.receive(body)) }
                } catch {
                    finish(Self.reason(error))
                    return
                }
            }
            if complete {
                finish("the Mac closed the connection")
            } else if let error {
                finish("reading from the connection failed: \(error)")
            } else {
                receive(connection)
            }
        }
    }

    private static func reason(_ error: Error) -> String {
        if case LinkError.refused(let reason) = error { return reason }
        return "\(error)"
    }

    private func write(_ body: Data) {
        connection?.send(content: LinkFramer.frame(body), completion: .contentProcessed { _ in })
    }

    private func handle(_ outputs: [ClientLink.Event]) {
        for output in outputs {
            switch output {
            case .send(let body): write(body)
            case .needsPairing(let name): events(.needsPairing(hubName: name))
            case .showCode(let code): events(.showCode(code))
            case .paired(let id, let key, let name): events(.paired(hubId: id, hubKey: key, hubName: name))
            case .pairingFailed(let reason): events(.pairingFailed(reason))
            case .established(let keys): establish(keys)
            case .control(.welcome(let welcome)): begin(welcome)
            case .control(let message): events(.control(message))
            }
        }
    }

    private var pendingKeys: LinkKeys?

    private func establish(_ keys: LinkKeys) {
        pendingKeys = keys
    }

    private func begin(_ welcome: Welcome) {
        guard let keys = pendingKeys, let address = hubMediaAddress(port: welcome.udpPort) else {
            finish("the Mac sent no media address")
            return
        }
        let socket: MediaSocket
        do { socket = try MediaSocket() } catch {
            finish("no UDP socket: \(error)")
            return
        }
        let pacer = PacedSender(socket: socket)
        pacer.configure(key: keys.send)
        pacer.setDestination(address)
        lock.withLock {
            self.welcome = welcome
            self.socket = socket
            self.pacer = pacer
            hubAddress = address
            opener = DatagramOpener(key: keys.receive, windowSize: 4096)
        }
        socket.receive { [weak self] data, from in self?.datagram(data, from: from) }
        pacer.send(HelloPacket(sessionId: welcome.sessionId).encoded(), channel: .hello)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .microseconds(settings.tickMicroseconds), leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        events(.established(welcome))
    }

    private func hubMediaAddress(port: UInt16) -> SocketAddress? {
        guard case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return SocketAddress(host: text, port: port)
    }

    private func datagram(_ data: Data, from: SocketAddress) {
        let now = LinkClock.nowNs()
        let opened = lock.withLock { () -> (channel: UInt8, plaintext: Data)? in
            guard from.mapped() == hubAddress?.mapped() else { return nil }
            guard let result = try? opener?.open(data) else {
                counters.openFailures += 1
                return nil
            }
            return result
        }
        guard let opened, let channel = MediaChannel(rawValue: opened.channel) else { return }
        switch channel {
        case .video:
            delivery.withLock {
                let outputs = lock.withLock { () -> [VideoReceiver.Output] in
                    if dice.dropsMedia() {
                        counters.droppedBySimulation += 1
                        return []
                    }
                    return receiver.receive(opened.plaintext, now: now)
                }
                handle(outputs, now: now)
            }
        case .audio:
            guard let packet = try? AudioPacket(opened.plaintext) else { return }
            let dropped = lock.withLock { () -> Bool in
                if dice.dropsMedia() {
                    counters.droppedBySimulation += 1
                    return true
                }
                counters.audioPackets += 1
                return false
            }
            if !dropped { events(.audio(packet, receivedNs: now)) }
        case .pong:
            guard let pong = try? PongPacket(opened.plaintext) else { return }
            lock.withLock { clock.add(pong.sample(clientReceiveNs: now)) }
        default:
            break
        }
    }

    private func handle(_ outputs: [VideoReceiver.Output], now: UInt64) {
        guard !outputs.isEmpty else { return }
        var refresh = false
        for output in outputs {
            switch output {
            case .deliver(let video):
                events(.video(video))
            case .nack(let nack):
                let pacer = lock.withLock { dice.dropsFeedback() ? nil : self.pacer }
                pacer?.send(nack.encoded(), channel: .nack)
            case .refresh:
                refresh = true
            }
        }
        if refresh { sendFeedback(now: now) }
    }

    private func sendFeedback(now: UInt64) {
        let (packet, pacer) = lock.withLock { () -> (FeedbackPacket, PacedSender?) in
            lastFeedbackNs = now
            sentRefresh = receiver.refreshRequest
            let sorted = decodeTimes.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
            let stats = receiver.stats
            let packet = FeedbackPacket(
                lastCompleteFrame: receiver.lastComplete, lastDecodedFrame: lastDecoded, refreshRequest: receiver.refreshRequest,
                receivedShards: stats.receivedShards, recoveredShards: stats.recoveredShards, lostFrames: stats.lostFrames,
                decodeP95Us: p95, ltrAcks: acks
            )
            return (packet, dice.dropsFeedback() ? nil : self.pacer)
        }
        pacer?.send(packet.encoded(), channel: .feedback)
    }

    private func tick() {
        let now = LinkClock.nowNs()
        delivery.withLock { handle(lock.withLock { receiver.tick(now: now) }, now: now) }
        let (feedback, ping, hello, keepalive, pacer, sessionId) = lock.withLock {
            () -> (Bool, UInt32?, Bool, Bool, PacedSender?, UInt32) in
            let feedback = now &- lastFeedbackNs >= settings.feedbackIntervalNs
            var ping: UInt32?
            if now &- lastPingNs >= settings.pingIntervalNs {
                lastPingNs = now
                pingSequence &+= 1
                ping = pingSequence
            }
            let hello = now &- lastHelloNs >= settings.helloIntervalNs
            if hello { lastHelloNs = now }
            let keepalive = now &- lastKeepaliveNs >= settings.keepaliveIntervalNs
            if keepalive { lastKeepaliveNs = now }
            return (feedback, ping, hello, keepalive, self.pacer, welcome?.sessionId ?? 0)
        }
        if feedback { sendFeedback(now: now) }
        if let ping { pacer?.send(PingPacket(sequence: ping, clientSendNs: now).encoded(), channel: .ping) }
        if hello { pacer?.send(HelloPacket(sessionId: sessionId).encoded(), channel: .hello) }
        if keepalive { send(.keepalive) }
    }

    private func finish(_ reason: String) {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        connection?.cancel()
        let (socket, pacer) = lock.withLock { (self.socket, self.pacer) }
        pacer?.stop()
        socket?.close()
        events(.disconnected(reason))
    }
}
