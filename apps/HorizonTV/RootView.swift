import HorizonLink
import SwiftUI

struct RootView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            switch model.screen {
            case .hubs: HubsView()
            case .connecting: ConnectingView()
            case .pairing: PairingView()
            case .catalog: CatalogView()
            case .playing: PlayingView()
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.notice)
    }
}

struct HubsView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text("HorizonTV").font(.largeTitle.bold())
                Text("Choose the Mac that runs the game").font(.title3).foregroundStyle(.secondary)
            }
            if model.discovered.isEmpty {
                HStack(spacing: 24) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Looking for HorizonHub on the network…").font(.headline)
                        Text("Keep HorizonHub open on a Mac on the same network as this Apple TV.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 40) {
                        ForEach(model.discovered) { hub in
                            Button { model.connect(hub) } label: {
                                HubCard(
                                    name: hub.name,
                                    detail: hub.compatible ? (isKnown(hub) ? "Paired" : "New") : "Different HorizonHub version",
                                    symbol: "desktopcomputer"
                                )
                            }
                            .buttonStyle(.card)
                            .disabled(!hub.compatible)
                        }
                    }
                    .padding(40)
                }
            }
            let offline = model.known.filter { known in !model.discovered.contains { $0.id == known.id } }
            if !offline.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paired, not on the network now").font(.headline).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        ForEach(offline) { hub in
                            Button(role: .destructive) { model.forget(hub) } label: {
                                Label("Forget \(hub.name)", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(80)
    }

    private func isKnown(_ hub: DiscoveredHub) -> Bool { model.known.contains { $0.id == hub.id } }
}

struct HubCard: View {
    let name: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 56))
            Text(name).font(.title3.bold()).lineLimit(1)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(width: 420, height: 240, alignment: .leading)
        .padding(32)
    }
}

struct ConnectingView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        VStack(spacing: 32) {
            ProgressView()
            Text(model.connectionNote ?? "Connecting to \(model.hubName)…").font(.title3)
            Button("Choose another Mac") { model.leave() }
        }
    }
}

struct PairingView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        VStack(spacing: 40) {
            Text("Pair with \(model.hubName)").font(.title.bold())
            if let code = model.code {
                Text("Enter this code on the Mac").font(.title3).foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 140, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 60)
                    .padding(.vertical, 24)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))
                Text("In HorizonHub on the Mac: TV › Pair a TV…").foregroundStyle(.secondary)
                Button("Cancel") { model.leave() }
            } else {
                if let error = model.pairingError {
                    Text(error).font(.title3).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text("On the Mac, open HorizonHub and choose TV › Pair a TV…, then continue here.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                HStack(spacing: 40) {
                    Button(model.pairingError == nil ? "Continue" : "Try again") { model.pair() }
                    Button("Back") { model.leave() }
                }
            }
        }
        .padding(80)
    }
}

struct CatalogView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.hubName).font(.largeTitle.bold())
                        Text(model.controllers.isEmpty ? "No controller connected" : model.controllers.joined(separator: " · "))
                            .foregroundStyle(model.controllers.isEmpty ? .orange : .secondary)
                    }
                    Spacer()
                    Button("Switch Mac") { model.leave() }
                }
                profilesRow
                gamesRow
                OptionsRow()
            }
            .padding(80)
        }
    }

    private var profilesRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Profile").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                ForEach(model.profiles) { profile in
                    Button {
                        model.profile = profile.id
                    } label: {
                        Label("\(profile.name) · \(profile.nick)", systemImage: model.profile == profile.id ? "checkmark.circle.fill" : "person.circle")
                    }
                }
            }
        }
    }

    private var gamesRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Games").font(.headline).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 40) {
                    ForEach(model.games) { game in
                        Button { model.play(game) } label: {
                            HubCard(name: game.title, detail: detail(game), symbol: game.status == .running ? "play.tv.fill" : "gamecontroller")
                        }
                        .buttonStyle(.card)
                        .disabled(!playable(game))
                    }
                }
                .padding(40)
            }
        }
    }

    private func playable(_ game: LinkGame) -> Bool {
        guard model.profile != nil else { return false }
        return game.status == .available || game.status == .running
    }

    private func detail(_ game: LinkGame) -> String {
        switch game.status {
        case .available: "Open here"
        case .running: model.state.game == game.id ? "Running on the Mac — play here" : "Running"
        case .blocked, .busy, .unavailable: game.detail.isEmpty ? "Unavailable" : game.detail
        }
    }
}

struct OptionsRow: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Picture and controls").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button("Resolution: \(model.options.resolution.label)") { model.cycleResolution() }
                Button("Bitrate: \(model.options.bitrate.label)") { model.cycleBitrate() }
                Button("Codec: \(model.options.codec.label)") { model.cycleCodec() }
                Button("Buttons: \(model.options.layout.label)") { model.cycleLayout() }
            }
        }
    }
}
