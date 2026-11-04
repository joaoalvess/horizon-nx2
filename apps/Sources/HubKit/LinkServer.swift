import Foundation
import HorizonLink
import Network

public final class LinkPeer: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let key: Data
    public let sessionId: UInt32
    public let pacer: PacedSender
    private let lock = NSLock()
    private var opener: DatagramOpener
    private var learned: SocketAddress?
    private var heard: UInt64

    init(keys: LinkKeys, socket: MediaSocket, pacer settings: PacerSettings) {
        name = keys.peerName
        key = keys.peerKey
        sessionId = UInt32.random(in: 1...UInt32.max)
        pacer = PacedSender(socket: socket, settings: settings)
        pacer.configure(key: keys.send)
        opener = DatagramOpener(key: keys.receive, windowSize: 4096)
        heard = LinkClock.nowNs()
    }

    public var address: SocketAddress? { lock.withLock { learned } }

    public var lastHeardNs: UInt64 { lock.withLock { heard } }

    func open(_ datagram: Data) -> (channel: UInt8, plaintext: Data)? {
        lock.withLock { try? opener.open(datagram) }
    }

    func heard(from address: SocketAddress, at now: UInt64) -> Bool {
        lock.withLock {
            heard = now
            guard learned != address else { return false }
            learned = address
            return true
        }
    }
}

public final class LinkServer: @unchecked Sendable {
    public enum Event: Sendable {
        case listening(port: UInt16, mediaPort: UInt16)
        case failed(String)
        case codeNeeded(clientName: String)
        case pairingFinished(clientName: String, paired: Bool, reason: String)
        case connected(LinkPeer)
        case control(LinkPeer, ControlMessage)
        case media(LinkPeer, MediaChannel, Data, receivedNs: UInt64)
        case moved(LinkPeer, SocketAddress)
        case disconnected(LinkPeer, String)
        case refused(String)
    }

    public struct Settings: Sendable {
        public var hubName: String
        public var port: UInt16 = 0
        public var mediaPort: UInt16 = 0
        public var advertise = true
        public var pacer = PacerSettings()

        public init(hubName: String) {
            self.hubName = hubName
        }
    }

    public let identity: LinkIdentity
    public let store: PairingStore
    public let gate: PairingGate
    public let settings: Settings
    let queue = DispatchQueue(label: "dev.joaoalvess.horizon.link", qos: .userInteractive)
    private let events: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var listener: NWListener?
    private var media: MediaSocket?
    private var connections: [ObjectIdentifier: ControlConnection] = [:]
    private var established: [LinkPeer] = []

    public init(
        identity: LinkIdentity, store: PairingStore, gate: PairingGate = PairingGate(), settings: Settings,
        events: @escaping @Sendable (Event) -> Void
    ) {
        self.identity = identity
        self.store = store
        self.gate = gate
        self.settings = settings
        self.events = events
    }

    public var peers: [LinkPeer] { lock.withLock { established } }

    public var mediaPort: UInt16? { lock.withLock { media?.port } }

    public func start() throws {
        let socket = try MediaSocket(port: settings.mediaPort)
        socket.receive { [weak self] data, from in self?.datagram(data, from: from) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.serviceClass = .interactiveVideo
        let listener: NWListener
        do {
            listener = try settings.port == 0
                ? NWListener(using: parameters)
                : NWListener(using: parameters, on: NWEndpoint.Port(rawValue: settings.port) ?? .any)
        } catch {
            socket.close()
            throw GamesError.unavailable("the link listener could not start: \(error)")
        }
        if settings.advertise {
            let record = NWTXTRecord(["v": String(LinkProtocol.version), "id": identity.hubId.map { String(format: "%02x", $0) }.joined()])
            listener.service = NWListener.Service(name: settings.hubName, type: LinkProtocol.serviceType, txtRecord: record)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                events(.listening(port: listener?.port?.rawValue ?? 0, mediaPort: socket.port))
            case .failed(let error):
                events(.failed("the link listener failed: \(error)"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        lock.withLock {
            self.listener = listener
            media = socket
        }
        listener.start(queue: queue)
    }

    public func stop() {
        let (listener, media, connections, peers) = lock.withLock {
            defer {
                self.listener = nil
                self.media = nil
                self.connections = [:]
                established = []
            }
            return (self.listener, self.media, Array(self.connections.values), established)
        }
        listener?.cancel()
        for connection in connections { connection.connection.cancel() }
        for peer in peers { peer.pacer.stop() }
        media?.close()
    }

    public var port: UInt16? { lock.withLock { listener?.port?.rawValue } }

    public func send(_ message: ControlMessage, to peer: LinkPeer) {
        queue.async { [self] in
            lock.withLock { connections.values.first { $0.peer === peer } }?.send(message)
        }
    }

    public func broadcast(_ message: ControlMessage) {
        queue.async { [self] in
            for connection in lock.withLock({ Array(connections.values) }) where connection.peer != nil { connection.send(message) }
        }
    }

    public func submitCode(_ code: String) {
        queue.async { [self] in
            lock.withLock { connections.values.first { $0.link.isAwaitingCode } }?.submitCode(code)
        }
    }

    public func cancelPairing() {
        queue.async { [self] in
            for connection in lock.withLock({ Array(connections.values) }) { connection.cancelPairing() }
        }
    }

    public func disconnect(_ peer: LinkPeer) {
        queue.async { [self] in
            lock.withLock { connections.values.first { $0.peer === peer } }?.connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        let link = HubLink(identity: identity, hubName: settings.hubName, gate: gate) { [store] in store.isPaired($0) }
        let control = ControlConnection(connection: connection, link: link, server: self)
        lock.withLock { connections[ObjectIdentifier(control)] = control }
        control.start()
    }

    fileprivate func emit(_ event: Event) {
        events(event)
    }

    fileprivate func establish(_ keys: LinkKeys) -> LinkPeer? {
        guard let socket = lock.withLock({ media }) else { return nil }
        let peer = LinkPeer(keys: keys, socket: socket, pacer: settings.pacer)
        store.touch(key: keys.peerKey)
        lock.withLock { established.append(peer) }
        return peer
    }

    fileprivate func ended(_ control: ControlConnection, reason: String) {
        let removed = lock.withLock { () -> Bool in
            let had = connections.removeValue(forKey: ObjectIdentifier(control)) != nil
            if let peer = control.peer { established.removeAll { $0 === peer } }
            return had
        }
        guard removed else { return }
        if let peer = control.peer {
            peer.pacer.stop()
            events(.disconnected(peer, reason))
        } else {
            events(.refused(reason))
        }
    }

    private func datagram(_ data: Data, from address: SocketAddress) {
        let now = LinkClock.nowNs()
        for peer in peers {
            guard let opened = peer.open(data), let channel = MediaChannel(rawValue: opened.channel) else { continue }
            if channel == .hello {
                guard let hello = try? HelloPacket(opened.plaintext), hello.sessionId == peer.sessionId else { return }
            } else if peer.address == nil {
                return
            }
            if peer.heard(from: address, at: now) {
                peer.pacer.setDestination(address)
                events(.moved(peer, address))
            }
            if channel != .hello { events(.media(peer, channel, opened.plaintext, receivedNs: now)) }
            return
        }
    }
}

final class ControlConnection: @unchecked Sendable {
    let connection: NWConnection
    private(set) var link: HubLink
    private(set) var peer: LinkPeer?
    private weak var server: LinkServer?
    private var framer = LinkFramer(limit: LinkProtocol.maxSecureMessage)
    private var ended = false

    init(connection: NWConnection, link: HubLink, server: LinkServer) {
        self.connection = connection
        self.link = link
        self.server = server
    }

    func start() {
        guard let server else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish("the connection failed: \(error)")
            case .cancelled: self?.finish("the connection closed")
            default: break
            }
        }
        connection.start(queue: server.queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                framer.append(data)
                do {
                    while let body = try framer.next() { handle(try link.receive(body)) }
                } catch {
                    refuse(error)
                    return
                }
            }
            if complete {
                finish("the client closed the connection")
            } else if let error {
                finish("reading the connection failed: \(error)")
            } else {
                receive()
            }
        }
    }

    private func refuse(_ error: Error) {
        if case LinkError.refused(let reason) = error, !link.isEstablished {
            write(ClearMessage.refused(reason).encoded())
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        finish("\(error)", cancel: false)
    }

    func send(_ message: ControlMessage) {
        guard link.isEstablished, let body = try? link.seal(message) else { return }
        write(body)
    }

    func submitCode(_ code: String) {
        handle(link.submitCode(code))
    }

    func cancelPairing() {
        handle(link.cancelPairing())
    }

    private func write(_ body: Data) {
        connection.send(content: LinkFramer.frame(body), completion: .contentProcessed { _ in })
    }

    private func handle(_ events: [HubLink.Event]) {
        guard let server else { return }
        for event in events {
            switch event {
            case .send(let body):
                write(body)
            case .codeNeeded(let name):
                server.emit(.codeNeeded(clientName: name))
            case .paired(let key, let name):
                do {
                    try server.store.add(key: key, name: name)
                    server.emit(.pairingFinished(clientName: name, paired: true, reason: ""))
                } catch {
                    server.emit(.pairingFinished(clientName: name, paired: false, reason: "\(error)"))
                }
            case .pairingFailed(let reason):
                server.emit(.pairingFinished(clientName: link.clientName ?? "", paired: false, reason: reason))
            case .established(let keys):
                guard let peer = server.establish(keys) else {
                    connection.cancel()
                    return
                }
                self.peer = peer
                send(.welcome(Welcome(udpPort: server.mediaPort ?? 0, sessionId: peer.sessionId, hubName: server.settings.hubName)))
                server.emit(.connected(peer))
            case .control(let message):
                if let peer { server.emit(.control(peer, message)) }
            }
        }
    }

    private func finish(_ reason: String, cancel: Bool = true) {
        guard !ended else { return }
        ended = true
        link.close()
        if cancel { connection.cancel() }
        server?.ended(self, reason: reason)
    }
}
