import AppKit
import HubKit
import SwiftUI

struct GamesView: View {
    @Environment(GamesModel.self) private var games

    var body: some View {
        @Bindable var games = games
        Form {
            if let record = games.session?.record {
                Section("Playing") {
                    LabeledContent("Game", value: record.title)
                    LabeledContent("Profile", value: record.profileName)
                    LabeledContent("Started", value: Format.relative(record.startedAt))
                    if let status = games.status, status.memoryWarning {
                        Label("Mac memory is low (level \(status.memoryLevel ?? 0))", systemImage: "memorychip")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button(games.closing ? "Closing…" : "Close the Game") { games.close() }
                            .disabled(games.closing)
                        Button("Show the Log") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.log)])
                        }
                    }
                }
            }
            if !games.blocks.isEmpty {
                Section("Blocks") {
                    ForEach(games.blocks) { block in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Blocked: \(games.blockTitle(block))").fontWeight(.medium)
                                Text(block.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Release…") { games.confirmRelease(block) }
                        }
                    }
                }
            }
            if let catalog = games.catalog {
                Section("Profile") {
                    Picker("Who is playing", selection: $games.selectedProfile) {
                        ForEach(catalog.profiles) { profile in
                            Text("\(profile.name) (\(profile.nick))").tag(Optional(profile.id))
                        }
                    }
                    .disabled(games.session != nil)
                }
                Section("Games") {
                    ForEach(catalog.games) { game in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title)
                                Text(games.availability(game).text).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { Task { await games.open(game) } }
                                .disabled(!games.canOpen(game))
                        }
                    }
                }
            }
            TVSection()
            if !games.catalogOnDisk {
                Section("Hangar SSD") {
                    Text(games.catalog == nil
                        ? "The game catalog is on the SSD. Connect the Hangar SSD to see the games."
                        : "The SSD is disconnected or locked: the games are unavailable.")
                        .foregroundStyle(.secondary)
                    Button("Unlock the SSD") { Task { await games.unlockSSD() } }
                        .disabled(games.working != nil)
                }
            }
            if let error = games.catalogError {
                Section("Catalog") {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let working = games.working {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(working)
                    }
                }
            }
            if let message = games.message {
                Section {
                    HStack(alignment: .top) {
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button("OK") { games.dismissMessage() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("HorizonHub")
        .task { await games.refresh() }
    }
}
