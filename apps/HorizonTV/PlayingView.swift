import HorizonPlayer
import SwiftUI

struct PlayingView: View {
    @Environment(TVModel.self) private var model
    @State private var confirmClose = false
    @FocusState private var menuFocus: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                PlayerView(session: player).ignoresSafeArea()
            }
            if !model.gameStarted {
                VStack(spacing: 24) {
                    ProgressView()
                    Text("Opening \(model.playingTitle) on the Mac…").font(.title3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.showStats, !model.statsText.isEmpty {
                Text(model.statsText)
                    .font(.system(.caption, design: .monospaced))
                    .padding(16)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .padding(40)
            }
            if model.menuOpen {
                menu
            }
        }
        .onExitCommand { model.closeMenu() }
        .confirmationDialog("Close \(model.playingTitle)?", isPresented: $confirmClose) {
            Button("Close game", role: .destructive) { model.closeGame() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The game closes on the Mac. Any progress the game has not saved is lost.")
        }
    }

    private var menu: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 28) {
            Text(model.playingTitle).font(.title2.bold())
            Button("Resume") { model.closeMenu() }
                .focused($menuFocus)
            Button("Return to the Mac") { model.returnToMac() }
            Button("Close game", role: .destructive) { confirmClose = true }
            Divider()
            OptionsRow()
            Toggle("On-screen stats", isOn: $model.showStats)
        }
        .padding(60)
        .frame(maxWidth: 1400, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { menuFocus = true }
    }
}
