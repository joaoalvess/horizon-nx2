import AppKit
import Foundation
import HubKit
import HorizonLink
import Observation

private struct HubSnapshot: Sendable, Equatable {
    var profiles: [LinkProfile] = []
    var games: [LinkGame] = []
    var state = LinkState()
    var process: ProcessIdentity?
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = HubSnapshot()

    var current: HubSnapshot { lock.withLock { snapshot } }

    func set(_ value: HubSnapshot) { lock.withLock { snapshot = value } }
}

@MainActor
@Observable
final class TVHub {
    static let shared = TVHub()

    private(set) var status = BridgeStatus()
    private(set) var paired: [PairedClient] = []
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var pairingOpen = false
    var code = ""

    @ObservationIgnored private var bridge: StreamBridge?
    @ObservationIgnored private var store: PairingStore?
    @ObservationIgnored private let snapshot = SnapshotBox()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?

    func start(games: GamesModel) {
        guard !started else { return }
        started = true
        let support = HubHome.supportDirectory + "/games"
        let store = PairingStore(file: support + "/clients.json")
        self.store = store
        paired = store.all
        let name = Host.current().localizedName ?? "Mac"
        var server = LinkServer.Settings(hubName: name)
        server.advertise = true
        var settings = BridgeSettings(socketPath: games.settings.streamSocket, server: server)
        settings.logDirectory = support + "/stream-logs"
        let box = snapshot
        let hubGames = HubGames(
            catalog: { (box.current.profiles, box.current.games) },
            state: { box.current.state },
            open: { profile, game in
                let current = box.current
                guard let entry = current.games.first(where: { $0.id == game }) else { return "Unknown game: \(game)" }
                guard entry.status == .available else { return entry.detail.isEmpty ? "\(entry.title) is not available" : entry.detail }
                guard current.profiles.contains(where: { $0.id == profile }) else { return "Unknown profile: \(profile)" }
                Task { @MainActor in await GamesModel.shared.open(game: game, profile: profile) }
                return nil
            },
            close: { Task { @MainActor in GamesModel.shared.close() } },
            gameProcess: { box.current.process }
        )
        games.onChange = { [weak self, weak games] in
            guard let self, let games else { return }
            publish(games)
        }
        publish(games)
        Task {
            do {
                let identity = try await Background.run { try PairingStore.identity() }
                let bridge = StreamBridge(settings: settings, identity: identity, store: store, games: hubGames) { event in
                    Task { @MainActor in TVHub.shared.handle(event) }
                }
                try await Background.run { try bridge.start() }
                self.bridge = bridge
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in TVHub.shared.tick() }
                }
            } catch {
                self.error = "The TV hub did not start: \(GamesModel.explain(error))"
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        bridge?.stop()
        bridge = nil
    }

    func openPairing() {
        code = ""
        bridge?.openPairing()
        pairingOpen = true
    }

    func cancelPairing() {
        code = ""
        bridge?.closePairing()
        pairingOpen = false
    }

    func submitCode() {
        let typed = Pairing.normalized(code)
        guard typed.count == Pairing.codeDigits else { return }
        bridge?.submitCode(typed)
        code = ""
    }

    func forget(_ client: PairedClient) {
        do {
            try bridge?.unpair(client.key)
            paired = store?.all ?? []
        } catch {
            notice = "Could not forget \(client.name): \(GamesModel.explain(error))"
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func tick() {
        pairingOpen = bridge?.gate.isOpen ?? false
        paired = store?.all ?? []
    }

    private func handle(_ event: StreamBridge.Event) {
        switch event {
        case .status(let status):
            self.status = status
            pairingOpen = bridge?.gate.isOpen ?? false
            paired = store?.all ?? []
        case .notice(let text):
            notice = text
        }
    }

    private func publish(_ games: GamesModel) {
        var next = HubSnapshot()
        if let catalog = games.catalog {
            next.profiles = catalog.profiles.map { LinkProfile(id: $0.id, name: $0.name, nick: $0.nick) }
            next.games = catalog.games.map { game in
                switch games.availability(game) {
                case .available: LinkGame(id: game.id, title: game.title, status: .available)
                case .running: LinkGame(id: game.id, title: game.title, status: .running)
                case .blocked: LinkGame(id: game.id, title: game.title, status: .blocked, detail: "Blocked on the Mac")
                case .busy(let reason): LinkGame(id: game.id, title: game.title, status: .busy, detail: reason)
                case .unavailable(let reason): LinkGame(id: game.id, title: game.title, status: .unavailable, detail: reason)
                }
            }
        }
        if let record = games.session?.record {
            next.state = LinkState(game: record.game, title: record.title, profile: record.profile)
            next.process = record.process
        }
        guard next != snapshot.current else { return }
        snapshot.set(next)
        bridge?.gamesChanged()
    }
}
