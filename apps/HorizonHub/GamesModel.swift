import AppKit
import Foundation
import HubKit
import Observation

enum GameAvailability: Equatable {
    case available
    case running
    case blocked
    case busy(String)
    case unavailable(String)

    var text: String {
        switch self {
        case .available: "Available"
        case .running: "Running"
        case .blocked: "Blocked"
        case .busy(let reason): reason
        case .unavailable(let reason): reason
        }
    }
}

private struct GamesSnapshot: Sendable {
    var catalog: GameCatalog?
    var fromCache = false
    var error: String?
    var blocks: [GameBlock] = []
    var lockHeld = false
}

@MainActor
@Observable
final class GamesModel {
    static let shared = GamesModel()

    let settings: GamesSettings
    let catalogPath: String

    private(set) var catalog: GameCatalog?
    private(set) var catalogOnDisk = false
    private(set) var catalogError: String?
    private(set) var blocks: [GameBlock] = []
    private(set) var lockHeld = false
    private(set) var session: GameSession?
    private(set) var status: SessionStatus?
    private(set) var working: String?
    private(set) var message: String?
    var selectedProfile: String?
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        settings = GamesSettings(supportDirectory: HubHome.supportDirectory + "/games")
        catalogPath = GameCatalog.path()
    }

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.unlockSSD(quietly: true) }
        })
        let settings = settings
        Task {
            if let adopted = try? await Background.run({ GameSession.adopt(settings: settings) }) { follow(adopted) }
            await refresh()
            await unlockSSD(quietly: true)
        }
    }

    func refresh() async {
        let path = catalogPath
        let cache = settings.catalogCache
        let keepsCache = path == GameCatalog.defaultPath
        let snapshot = try? await Background.run { () -> GamesSnapshot in
            var snapshot = GamesSnapshot()
            if FileManager.default.fileExists(atPath: path) {
                do {
                    let catalog = try GameCatalog.load(path: path)
                    snapshot.catalog = catalog
                    if keepsCache, let data = try? catalog.encoded() {
                        try? FileManager.default.createDirectory(
                            atPath: (cache as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true
                        )
                        if FileManager.default.contents(atPath: cache) != data {
                            try? data.write(to: URL(fileURLWithPath: cache), options: .atomic)
                        }
                    }
                } catch {
                    snapshot.error = String(describing: error)
                }
            } else if let data = FileManager.default.contents(atPath: cache) {
                snapshot.catalog = try? GameCatalog.decode(data, source: cache)
                snapshot.fromCache = true
            }
            if let catalog = snapshot.catalog, !snapshot.fromCache {
                let state = GuardState(directory: catalog.state)
                snapshot.blocks = state.allBlocks()
                snapshot.lockHeld = BootLock.isHeld(path: state.lockPath)
            }
            return snapshot
        }
        guard let snapshot else { return }
        catalog = snapshot.catalog
        catalogOnDisk = snapshot.catalog != nil && !snapshot.fromCache
        catalogError = snapshot.error
        blocks = snapshot.blocks
        lockHeld = snapshot.lockHeld
        if let catalog, selectedProfile.flatMap(catalog.profile) == nil {
            selectedProfile = catalog.profiles.first?.id
        }
        onChange?()
    }

    func availability(_ game: Game) -> GameAvailability {
        if session?.record.game == game.id { return .running }
        guard catalogOnDisk else { return .unavailable("Unavailable: the SSD is not connected") }
        if blocks.contains(where: { $0.game == nil || $0.game == game.id }) { return .blocked }
        if session != nil { return .busy("Another game is running") }
        if lockHeld { return .busy("Busy: another run is using the Mac") }
        return .available
    }

    func canOpen(_ game: Game) -> Bool {
        availability(game) == .available && selectedProfile != nil && working == nil
    }

    var closing: Bool { status?.phase == SessionPhase.closing }

    func open(game id: String, profile: String) async {
        guard let game = catalog?.game(id), catalog?.profile(profile) != nil else { return }
        selectedProfile = profile
        await open(game)
    }

    func open(_ game: Game) async {
        guard let catalog, let profile = selectedProfile, canOpen(game) else { return }
        working = "Opening \(game.title)…"
        message = nil
        defer { working = nil }
        let settings = settings
        do {
            let session = try await Background.run {
                try GameSession.open(catalog: catalog, profile: profile, game: game.id, settings: settings)
            }
            follow(session)
            bringToFront(session.pid)
        } catch {
            say("Could not open \(game.title): \(Self.explain(error))")
        }
        await refresh()
    }

    func close() {
        session?.close()
    }

    func closeForQuit() async {
        guard let session else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.onFinish { _ in continuation.resume() }
            session.close()
        }
    }

    func blockTitle(_ block: GameBlock) -> String {
        guard let id = block.game else { return "all games" }
        return catalog?.game(id)?.title ?? id
    }

    func confirmRelease(_ block: GameBlock) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Release \(blockTitle(block))?"
        alert.informativeText = block.text
            + "\n\nAfter a GPU error, open the game again only once the cause is known. A GPU hang flashes the whole Mac display."
        alert.addButton(withTitle: "Release")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await release(block) }
    }

    private func release(_ block: GameBlock) async {
        guard let catalog else { return }
        let state = GuardState(directory: catalog.state)
        do {
            _ = try await Background.run { try state.release(block) }
            say("\(blockTitle(block).capitalizedFirst) released.")
        } catch {
            say("Could not release: \(Self.explain(error))")
        }
        await refresh()
    }

    func unlockSSD(quietly: Bool = false) async {
        guard working == nil else { return }
        let volume: LockedVolume?
        do {
            volume = try await Background.run { try SSDUnlock.lockedVolume() }
        } catch {
            if !quietly { say("Could not look for the SSD: \(Self.explain(error))") }
            return
        }
        guard let volume else {
            if !quietly { say("No locked \(SSDUnlock.volumeName) volume was found. Check that the SSD is connected.") }
            return
        }
        working = "Unlocking the SSD…"
        defer { working = nil }
        do {
            try await Background.run { try SSDUnlock.unlock(volume) }
            say("SSD \(volume.name) unlocked.")
        } catch {
            say("Could not unlock the SSD: \(Self.explain(error))")
        }
        await refresh()
    }

    func dismissMessage() {
        message = nil
    }

    private func follow(_ session: GameSession) {
        self.session = session
        onChange?()
        session.onChange { [weak self] status in
            Task { @MainActor in self?.update(session, status) }
        }
    }

    private func update(_ session: GameSession, _ status: SessionStatus) {
        guard self.session === session else { return }
        self.status = status
        guard case .finished(let outcome) = status.phase else { return }
        self.session = nil
        self.status = nil
        onChange?()
        say(Self.describe(outcome, session.record))
        Task { await refresh() }
    }

    private func bringToFront(_ pid: pid_t) {
        Task { [weak self] in
            var yielded = false
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.session?.pid == pid else { return }
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                if !yielded {
                    NSApp.yieldActivation(to: app)
                    yielded = true
                }
                if Self.hasWindow(pid) {
                    app.activate(from: NSRunningApplication.current, options: [])
                    return
                }
            }
        }
    }

    private static func hasWindow(_ pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    private func say(_ text: String) {
        message = text
    }

    static func describe(_ outcome: GameOutcome, _ record: SessionRecord) -> String {
        let title = record.title
        switch outcome.kind {
        case .closed:
            return outcome.gracefulExit ? "\(title) was closed (clean exit)." : "\(title) was closed (\(outcome.exit?.description ?? "no exit code"))."
        case .ended:
            return outcome.exit == nil ? "\(title) ended while HorizonHub was closed." : "\(title) was closed by the game itself."
        case .gpu:
            let all = outcome.stopAll.map { " All games are blocked: \($0)." } ?? ""
            return "\(title) was closed by a GPU error and is now blocked.\(all)"
        case .gpuOther:
            return "The GPU hung because of \(outcome.culprits.joined(separator: ", ")); \(title) was closed without a block."
        case .memory:
            return "\(title) was closed because the Mac's memory became critical."
        case .ssdLost:
            return "\(title) stopped because the SSD was disconnected."
        case .crash:
            return "\(title) stopped (\(outcome.exit?.description ?? "unknown reason")). The log is at \(record.log)."
        }
    }

    static func explain(_ error: Error) -> String {
        switch error {
        case GamesError.blocked(let name, let text):
            return (name == GameBlock.all ? "all games are blocked: " : "the game is blocked: ") + text
        case GamesError.busy:
            return "another game or an agent run is using the Mac (boot.lock is held)"
        case GamesError.alreadyRunning:
            return "HorizonHub already has a game running"
        case GamesError.unavailable(let text), GamesError.launch(let text), GamesError.catalog(let text):
            return text
        default:
            return Format.explain(error)
        }
    }
}
