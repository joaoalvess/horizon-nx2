import AppKit
import HorizonPlayer
import Observation
import SwiftUI

@MainActor
@Observable
final class ReceiverWindowModel {
    var session: PlayerSession?
    var status = "Connecting…"
}

struct ReceiverWindowContent: View {
    let model: ReceiverWindowModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let session = model.session {
                PlayerView(session: session)
            } else {
                Color.black
            }
            Text(model.status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .padding(8)
        }
        .frame(minWidth: 480, minHeight: 270)
    }
}

@MainActor
final class ReceiverWindow: NSObject, NSWindowDelegate {
    private let receiver: Receiver
    private let model = ReceiverWindowModel()
    private var window: NSWindow?

    init(receiver: Receiver) {
        self.receiver = receiver
        super.init()
        let model = self.model
        receiver.onSession = { session in
            Task { @MainActor in model.session = session }
        }
        receiver.onStatus = { line in
            Task { @MainActor in model.status = line }
        }
    }

    func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "HorizonReceiver — \(receiver.options.name)"
        window.contentView = NSHostingView(rootView: ReceiverWindowContent(model: model))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        application.activate()
        application.run()
        exit(0)
    }

    func windowWillClose(_ notification: Notification) {
        receiver.shutdown("Window closed.")
    }
}
