import Foundation
import HorizonLink
import HorizonPlayer
import Network
import Observation
import UIKit

final class MediaRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var player: PlayerSession?

    func set(_ player: PlayerSession?) { lock.withLock { self.player = player } }

    func video(_ video: ReceivedVideo) { lock.withLock { player }?.video(video) }

    func audio(_ packet: AudioPacket, receivedNs: UInt64) { lock.withLock { player }?.audio(packet, receivedNs: receivedNs) }
}

@MainActor
@Observable
final class TVModel {
    static let shared = TVModel()

    enum Screen: Equatable {
        case hubs
        case connecting
        case pairing
        case catalog
        case playing
    }

    private(set) var screen = Screen.hubs {
        didSet { updateCapture() }
    }
    private(set) var discovered: [DiscoveredHub] = []
    private(set) var known: [KnownHub] = []
    private(set) var hubName = ""
    private(set) var profiles: [LinkProfile] = []
    private(set) var games: [LinkGame] = []
    private(set) var state = LinkState()
    private(set) var code: String?
    private(set) var pairingError: String?
    private(set) var connectionNote: String?
    private(set) var notice: String?
    private(set) var player: PlayerSession?
    private(set) var playingTitle = ""
    private(set) var gameStarted = false
    private(set) var menuOpen = false {
        didSet { updateCapture() }
    }
    private(set) var statsText = ""
    private(set) var controllers: [String] = []
    private(set) var options = StreamOptions.load()
    var showStats = false
    var profile: String? {
        didSet { UserDefaults.standard.set(profile, forKey: "profile") }
    }

    @ObservationIgnored var onCapture: ((Bool) -> Void)?
    @ObservationIgnored private let store = HubStore()
    @ObservationIgnored private let media = MediaRoute()
    @ObservationIgnored private var browser: HubBrowser?
    @ObservationIgnored private var input: ControllerInput?
    @ObservationIgnored private var client: LinkClient?
    @ObservationIgnored private var identity: LinkIdentity?
    @ObservationIgnored private var target: DiscoveredHub?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playingGame: String?
    @ObservationIgnored private var wantsStream = false
    @ObservationIgnored private var resumeOnForeground = false
    @ObservationIgnored private var leftHub = false
    @ObservationIgnored private var autoConnected = false
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var statsTick = 0
    @ObservationIgnored private var lastAttachNs: UInt64 = 0

    private init() {
        profile = UserDefaults.standard.string(forKey: "profile")
    }

    var capturesControllers: Bool { screen == .playing && !menuOpen }

    func start() {
        guard browser == nil else { return }
        known = store.all
        let browser = HubBrowser { hubs in
            Task { @MainActor in TVModel.shared.discoveredChanged(hubs) }
        }
        self.browser = browser
        browser.start()
        let input = ControllerInput(
            menu: { Task { @MainActor in TVModel.shared.openMenu() } },
            changed: { names in Task { @MainActor in TVModel.shared.controllers = names } }
        )
        input.setLayout(options.layout)
        input.start()
        self.input = input
    }

    func connect(_ hub: DiscoveredHub) {
        leftHub = false
        target = hub
        hubName = hub.name
        code = nil
        pairingError = nil
        open(hub)
    }

    func leave() {
        leftHub = true
        if screen == .playing { client?.send(.detach(pause: false)) }
        endPlay()
        drop()
        target = nil
        connectionNote = nil
        screen = .hubs
    }

    func forget(_ hub: KnownHub) {
        store.forget(hub.id)
        known = store.all
    }

    func pair() {
        code = nil
        pairingError = nil
        guard let client else {
            if let target { open(target) }
            return
        }
        client.pair()
    }

    func play(_ game: LinkGame) {
        guard let client, let profile else { return }
        if state.game != game.id { client.send(.open(profile: profile, game: game.id)) }
        playingGame = game.id
        playingTitle = game.title
        gameStarted = state.game == game.id
        wantsStream = true
        startStreaming()
    }

    func openMenu() {
        guard screen == .playing, !menuOpen else { return }
        menuOpen = true
        input?.setMuted(true)
    }

    func closeMenu() {
        guard menuOpen else { return }
        menuOpen = false
        input?.setMuted(false)
    }

    func returnToMac() {
        client?.send(.detach(pause: false))
        endPlay()
        screen = client == nil ? .hubs : .catalog
    }

    func closeGame() {
        client?.send(.detach(pause: false))
        client?.send(.close)
        endPlay()
        screen = client == nil ? .hubs : .catalog
    }

    func cycleResolution() { change { $0.resolution = $0.resolution.next() } }

    func cycleCodec() { change { $0.codec = $0.codec.next() } }

    func cycleLayout() {
        options.layout = options.layout.next()
        options.save()
        input?.setLayout(options.layout)
    }

    func cycleBitrate() {
        options.bitrate = options.bitrate.next()
        options.save()
        guard screen == .playing, let client else { return }
        if options.bitrate == .automatic { sendAttach() } else { client.send(.bitrate(options.bitrate.rawValue)) }
    }

    func enteredBackground() {
        browser?.stop()
        guard client != nil else { return }
        resumeOnForeground = screen == .playing
        if resumeOnForeground { client?.send(.detach(pause: true)) }
        tearDownMedia()
        drop()
        connectionNote = resumeOnForeground ? "Returning to \(playingTitle)…" : "Reconnecting to \(hubName)…"
        screen = .connecting
    }

    func enteredForeground() {
        browser?.start()
        guard let target, !leftHub, client == nil else { return }
        resumeOnForeground = false
        open(target)
    }

    private func open(_ hub: DiscoveredHub) {
        drop()
        let identity: LinkIdentity
        do {
            identity = try self.identity ?? store.identity()
        } catch {
            show("Couldn't read the TV's identity: \(error)")
            screen = .hubs
            return
        }
        self.identity = identity
        generation += 1
        let generation = generation
        let media = media
        let store = store
        let settings = LinkClientSettings(name: UIDevice.current.name)
        let client = LinkClient(identity: identity, settings: settings, knownHub: { store.key(for: $0) }) { event in
            switch event {
            case .video(let video): media.video(video)
            case .audio(let packet, let receivedNs): media.audio(packet, receivedNs: receivedNs)
            default: Task { @MainActor in TVModel.shared.handle(event, generation: generation) }
            }
        }
        self.client = client
        screen = .connecting
        client.connect(to: hub.endpoint)
    }

    private func drop() {
        generation += 1
        client?.disconnect()
        client = nil
    }

    private func handle(_ event: LinkClient.Event, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .needsPairing(let name):
            hubName = name
            code = nil
            pairingError = nil
            endPlay()
            screen = .pairing
        case .showCode(let code):
            self.code = String(code.prefix(3)) + " " + String(code.dropFirst(3))
        case .paired(let hubId, let hubKey, let name):
            store.remember(hubId: hubId, key: hubKey, name: name)
            known = store.all
            code = nil
        case .pairingFailed(let reason):
            code = nil
            pairingError = reason
        case .established(let welcome):
            hubName = welcome.hubName
            connectionNote = nil
            if let target { store.touch(target.id) }
            known = store.all
            if wantsStream, playingGame != nil {
                startStreaming()
            } else {
                screen = .catalog
            }
        case .control(let message):
            control(message)
        case .disconnected(let reason):
            disconnected(reason)
        case .video, .audio:
            break
        }
    }

    private func control(_ message: ControlMessage) {
        switch message {
        case .catalog(let profiles, let games):
            self.profiles = profiles
            self.games = games
            if profile == nil || !profiles.contains(where: { $0.id == profile }) { profile = profiles.first?.id }
        case .state(let state):
            self.state = state
            guard screen == .playing, let playingGame else { return }
            if state.game == playingGame {
                gameStarted = true
            } else if gameStarted {
                show("\(playingTitle) was closed on the Mac")
                endPlay()
                screen = .catalog
            }
        case .notice(let text):
            show(text)
            if screen == .playing, !gameStarted {
                endPlay()
                screen = .catalog
            }
        default:
            break
        }
    }

    private func disconnected(_ reason: String) {
        client = nil
        tearDownMedia()
        if leftHub { return }
        if screen == .pairing {
            code = nil
            if pairingError == nil { pairingError = "Lost the connection to the Mac: \(reason)" }
            return
        }
        connectionNote = "Reconnecting to \(hubName)…"
        screen = .connecting
        let generation = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard generation == self.generation, !leftHub, client == nil, let target else { return }
            open(target)
        }
    }

    private func discoveredChanged(_ hubs: [DiscoveredHub]) {
        discovered = hubs
        if let target, let fresh = hubs.first(where: { $0.id == target.id }) { self.target = fresh }
        guard !autoConnected, screen == .hubs, !leftHub else { return }
        let knownIds = Set(store.all.map(\.id))
        guard let last = store.all.first, knownIds.contains(last.id), let hub = hubs.first(where: { $0.id == last.id && $0.compatible })
        else { return }
        autoConnected = true
        connect(hub)
    }

    private func startStreaming() {
        guard let client else { return }
        player?.stop()
        let player = PlayerSession(client: client)
        self.player = player
        media.set(player)
        menuOpen = false
        screen = .playing
        sendAttach()
        input?.activate(ControllerSink(pad: { client.sendPad($0) }, pads: { client.send(.pads($0)) }))
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in TVModel.shared.refreshStats() }
        }
    }

    private func tearDownMedia() {
        input?.deactivate()
        media.set(nil)
        player?.stop()
        player = nil
        statsTimer?.invalidate()
        statsTimer = nil
        menuOpen = false
    }

    private func endPlay() {
        tearDownMedia()
        wantsStream = false
        playingGame = nil
        gameStarted = false
        statsText = ""
    }

    private func change(_ edit: (inout StreamOptions) -> Void) {
        edit(&options)
        options.save()
        guard screen == .playing else { return }
        sendAttach()
    }

    private func sendAttach() {
        lastAttachNs = LinkClock.nowNs()
        client?.send(.attach(options.attach))
    }

    private func refreshStats() {
        guard let player else { return }
        let stats = player.stats
        let now = LinkClock.nowNs()
        if gameStarted, stats.waitingForKeyFrame, let since = stats.waitingSinceNs, now &- since > 2_000_000_000,
           now &- lastAttachNs > 3_000_000_000 {
            sendAttach()
        }
        let line = StatsText.describe(stats)
        statsText = line
        statsTick += 1
        if statsTick % 5 == 0 { client?.send(.stats(line)) }
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            TVModel.shared.notice = nil
        }
    }

    private func updateCapture() {
        UIApplication.shared.isIdleTimerDisabled = screen == .playing
        onCapture?(capturesControllers)
    }
}
