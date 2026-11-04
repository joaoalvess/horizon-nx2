import AppKit
import Observation
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let openMainWindow = Notification.Name("dev.joaoalvess.horizon.hub.open-main-window")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if let other = others.first(where: { $0 != current }) {
            other.activate()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GamesModel.shared.start()
        TVHub.shared.start(games: GamesModel.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TVHub.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let games = GamesModel.shared
        guard let record = games.session?.record else { return .terminateNow }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let scripted = event?.eventClass == AEEventClass(kCoreEventClass) && event?.eventID == AEEventID(kAEQuitApplication)
        if !scripted {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Close \(record.title) and quit?"
            alert.informativeText = "HorizonHub closes \(record.profileName)'s game before it quits. Anything the game has not saved yet is lost."
            alert.addButton(withTitle: "Close the Game and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await games.closeForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + games.settings.closeGrace + 10) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
@Observable
final class LoginItem {
    private(set) var enabled = SMAppService.mainApp.status == .enabled
    private(set) var error: String?

    var available: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Could not change Open at Login: \(error.localizedDescription)"
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

@main
struct HorizonHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var login = LoginItem()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(GamesModel.shared)
                .environment(login)
        } label: {
            MenuBarLabel()
                .environment(GamesModel.shared)
        }
        .menuBarExtraStyle(.menu)

        Window("HorizonHub", id: "main") {
            GamesView()
                .environment(GamesModel.shared)
                .environment(TVHub.shared)
                .environment(\.locale, Format.locale)
                .frame(minWidth: 520, minHeight: 480)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 640, height: 720)
    }
}

struct MenuBarLabel: View {
    @Environment(GamesModel.self) private var games
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: games.session == nil ? "gamecontroller" : "gamecontroller.fill")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuContent: View {
    @Environment(LoginItem.self) private var login
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GamesMenu()
        Divider()
        Button("Open HorizonHub…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Toggle("Open at Login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
            .disabled(!login.available)
        if let error = login.error {
            Text(error)
        }
        Button("Quit HorizonHub") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct GamesMenu: View {
    @Environment(GamesModel.self) private var games

    var body: some View {
        if let record = games.session?.record {
            Text("Playing \(record.title) as \(record.profileName)")
            if let status = games.status, status.memoryWarning {
                Text("Mac memory is low (level \(status.memoryLevel ?? 0))")
            }
            Button(games.closing ? "Closing the Game…" : "Close the Game") { games.close() }
                .disabled(games.closing)
        } else {
            Text("No game running")
        }
        ForEach(games.blocks) { block in
            Text("Blocked: \(games.blockTitle(block))")
            Button("Release \(games.blockTitle(block))…") { games.confirmRelease(block) }
        }
        if let message = games.message {
            Text(message.count > 90 ? message.prefix(89) + "…" : message)
        }
    }
}
