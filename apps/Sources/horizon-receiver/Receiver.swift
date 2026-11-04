import Foundation
import HorizonLink
import HorizonPlayer
import Network
import Synchronization

final class SessionBox: Sendable {
    let value = Mutex<PlayerSession?>(nil)

    var session: PlayerSession? { value.withLock { $0 } }
}

final class Receiver: @unchecked Sendable {
    let options: ReceiverOptions
    let queue = DispatchQueue(label: "dev.joaoalvess.horizon.receiver", qos: .userInitiated)
    var onSession: (@Sendable (PlayerSession) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    private let store: ReceiverStore
    private let identity: LinkIdentity
    private let finder = HubFinder()
    private let snapshots: Snapshots?
    private let startNs = LinkClock.nowNs()
    private var endpoint: NWEndpoint?
    private var hubLabel = ""
    private var connection = 0
    private var client: LinkClient?
    private var session: PlayerSession?
    private var established = false
    private var stopping = false
    private var totals = RunTotals()
    private var previous: (connection: Int, stats: PlayerStats, ns: UInt64)?
    private var lastAttachNs: UInt64 = 0
    private var connectedNs: UInt64 = 0
    private var lastReason: String?
    private var lastState: LinkState?
    private var catalogShown = false
    private var timers: [DispatchSourceTimer] = []
    private var signals: [DispatchSourceSignal] = []

    init(options: ReceiverOptions) throws {
        self.options = options
        store = try ReceiverStore()
        identity = try store.identity()
        snapshots = try options.pngDirectory.map { try Snapshots(directory: $0) }
    }

    func start() {
        installSignals()
        queue.async { [self] in
            Console.line("Receiver \(options.name); identity and known Macs in \(store.directory)")
            if let deadline = options.seconds {
                queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
                    self?.shutdown("Time is up (\(decimal(deadline, 0)) s).")
                }
            }
            if let hub = options.hub {
                hubLabel = "\(hub.host):\(hub.port)"
                endpoint = .hostPort(host: NWEndpoint.Host(hub.host), port: NWEndpoint.Port(rawValue: hub.port) ?? .any)
                begin()
            } else {
                Console.line("Looking for the Mac over Bonjour (\(LinkProtocol.serviceType))…")
                finder.find(name: options.hubName) { [weak self] result in
                    guard let self else { return }
                    queue.async { [self] in
                        switch result {
                        case .success(let found):
                            Console.line("Found \(found.name).")
                            hubLabel = found.name
                            endpoint = found.endpoint
                            begin()
                        case .failure(let error):
                            Console.error(error.message)
                            exit(1)
                        }
                    }
                }
            }
        }
    }

    func shutdown(_ reason: String) {
        queue.async { [self] in
            guard !stopping else { return }
            stopping = true
            Console.line(reason)
            guard let client, established else {
                finish()
                return
            }
            client.send(.detach(pause: false))
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in finish() }
        }
    }

    private func finish() {
        closeSession()
        timers.forEach { $0.cancel() }
        let seconds = Double(LinkClock.nowNs() &- startNs) / 1e9
        totals.summary(seconds: seconds, hub: hubLabel, limitMs: options.limitMs, window: options.window).forEach(Console.line)
        exit(0)
    }

    private func begin() {
        schedule(every: 5) { [weak self] in self?.status() }
        schedule(every: 0.5) { [weak self] in self?.watchdog() }
        if snapshots != nil { schedule(every: options.pngEvery) { [weak self] in self?.snapshot() } }
        connect()
    }

    private func connect() {
        guard !stopping, let endpoint else { return }
        connection += 1
        let id = connection
        established = false
        connectedNs = LinkClock.nowNs()
        let box = SessionBox()
        var settings = LinkClientSettings(name: options.name)
        settings.drop = options.drop
        let store = self.store
        let client = LinkClient(identity: identity, settings: settings, knownHub: { store.key(for: $0) }) { [weak self] event in
            switch event {
            case .video(let video):
                box.session?.video(video)
            case .audio(let packet, let receivedNs):
                box.session?.audio(packet, receivedNs: receivedNs)
            default:
                guard let self else { return }
                queue.async { [self] in handle(event, connection: id) }
            }
        }
        let session = PlayerSession(client: client, settings: PlayerSettings(tsvPath: tsvPath(for: id), audio: options.audio))
        if let error = session.tsvError { Console.error(error) }
        box.value.withLock { $0 = session }
        self.client = client
        self.session = session
        onSession?(session)
        Console.line(id == 1 ? "Connecting to \(hubLabel)…" : "Reconnecting to \(hubLabel) (connection \(id))…")
        client.connect(to: endpoint)
    }

    private func tsvPath(for connection: Int) -> String? {
        guard let path = options.tsvPath else { return nil }
        guard connection > 1 else { return path }
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(connection)\(suffix)").path
    }

    private func handle(_ event: LinkClient.Event, connection id: Int) {
        guard id == connection, let client else { return }
        switch event {
        case .needsPairing(let hubName):
            Console.line("The Mac \(hubName) does not know this receiver yet: in HorizonHub, choose TV › Pair a TV…")
            client.pair()
        case .showCode(let code):
            Console.line("")
            Console.line("    Enter on the Mac: \(code.prefix(3)) \(code.dropFirst(3))")
            Console.line("")
        case .paired(let hubId, let hubKey, let hubName):
            do {
                try store.remember(hubId: hubId, key: hubKey, name: hubName)
                Console.line("Paired with \(hubName).")
            } catch {
                Console.error("Paired with \(hubName), but could not remember the Mac: \(error)")
            }
        case .pairingFailed(let reason):
            Console.line("Pairing failed: \(reason)")
            client.disconnect()
        case .established(let welcome):
            established = true
            lastReason = nil
            Console.line("Connected to \(welcome.hubName); asking for \(options.attach.width)x\(options.attach.height)@\(options.attach.refreshHz) video.")
            sendAttach()
        case .control(.state(let state)):
            guard state != lastState else { return }
            lastState = state
            let game = state.title ?? state.game
            let text = game.map { "game \($0)" + (state.profile.map { ", profile \($0)" } ?? "") } ?? "no game open"
            Console.line("Mac: \(text); \(state.streaming ? "streaming" : "not streaming")\(state.paused ? ", paused" : "")")
        case .control(.notice(let text)):
            Console.line("Mac: \(text)")
        case .control(.catalog(let profiles, let games)):
            guard !catalogShown else { return }
            catalogShown = true
            Console.line("Catalog: \(profiles.count) profiles, \(games.count) games.")
        case .control:
            break
        case .disconnected(let reason):
            closeSession()
            if reason != lastReason { Console.line("Disconnected: \(reason)") }
            lastReason = reason
            guard !stopping else { return }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
        case .video, .audio:
            break
        }
    }

    private func sendAttach() {
        lastAttachNs = LinkClock.nowNs()
        client?.send(.attach(options.attach))
    }

    private func closeSession() {
        established = false
        guard let session else {
            client = nil
            return
        }
        session.stop()
        totals.add(session.stats)
        self.session = nil
        let client = self.client
        self.client = nil
        client?.disconnect()
    }

    private func status() {
        let elapsed = Double(LinkClock.nowNs() &- startNs) / 1e9
        guard let session else {
            Console.line("[\(String(format: "%5.0f", elapsed)) s] not connected\(lastReason.map { ": \($0)" } ?? "")")
            return
        }
        let now = LinkClock.nowNs()
        let stats = session.stats
        let before = previous.flatMap { $0.connection == connection ? $0 : nil }
        let seconds = Double(now &- (before?.ns ?? connectedNs)) / 1e9
        let line = StatusLine.text(elapsed: elapsed, current: stats, previous: before?.stats, seconds: seconds, limitMs: options.limitMs)
        previous = (connection, stats, now)
        Console.line(line)
        onStatus?(line)
    }

    private func watchdog() {
        guard established, let session else { return }
        let stats = session.stats
        let now = LinkClock.nowNs()
        guard stats.waitingForKeyFrame, let since = stats.waitingSinceNs, now &- since > 2_000_000_000,
              now &- lastAttachNs > 3_000_000_000 else { return }
        Console.line("No key frame for \(decimal(Double(now &- since) / 1e9)) s: asking for the video again.")
        sendAttach()
    }

    private func snapshot() {
        guard let snapshots, let shot = session?.snapshot() else { return }
        let elapsed = Double(LinkClock.nowNs() &- startNs) / 1e9
        snapshots.write(shot, elapsed: elapsed)
    }

    private func schedule(every seconds: Double, _ action: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        timers.append(timer)
    }

    private func installSignals() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if stopping { exit(130) }
                shutdown(number == SIGINT ? "Interrupted (Ctrl+C)." : "Terminated (SIGTERM).")
            }
            source.resume()
            signals.append(source)
        }
    }
}
