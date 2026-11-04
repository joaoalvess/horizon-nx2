import HubKit
import HorizonLink
import SwiftUI

struct TVSection: View {
    @Environment(TVHub.self) private var tv

    var body: some View {
        @Bindable var tv = tv
        Section("TV") {
            if let error = tv.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else {
                LabeledContent("Hub", value: tv.status.listening ? "Waiting for the TV on the network" : "Starting…")
            }
            if tv.status.hostConnected {
                LabeledContent("Game video", value: "The game is connected")
            }
            if let client = tv.status.attachedClient {
                LabeledContent("On the TV", value: client + (tv.status.clientAddress.map { " (\($0))" } ?? ""))
                LabeledContent(
                    "Stream",
                    value: "\(tv.status.framesSent) frames, \(tv.status.repairs) repairs, \(tv.status.refreshes) refreshes, \(tv.status.lostFrames) lost"
                )
                if let bound = tv.status.lastBoundMs {
                    LabeledContent("Present to decoded", value: String(format: "up to %.1f ms", bound))
                }
                if tv.status.stalled {
                    Label("The TV stopped responding: the game is paused", systemImage: "pause.circle").foregroundStyle(.orange)
                }
            }
            if let awaiting = tv.status.awaitingCode {
                Text("Type the code shown on \(awaiting)")
                HStack {
                    TextField("Code", text: $tv.code)
                        .frame(width: 120)
                        .onSubmit { tv.submitCode() }
                    Button("Confirm") { tv.submitCode() }
                        .disabled(Pairing.normalized(tv.code).count != Pairing.codeDigits)
                    Button("Cancel") { tv.cancelPairing() }
                }
            } else if tv.pairingOpen {
                HStack {
                    Text(tv.status.pairingMessage ?? "Waiting for the TV…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { tv.cancelPairing() }
                }
            } else {
                HStack {
                    if let message = tv.status.pairingMessage { Text(message).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Pair a TV…") { tv.openPairing() }
                        .disabled(tv.error != nil)
                }
            }
            ForEach(tv.paired) { client in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.name)
                        Text(client.lastSeen.map { "Seen \(Format.relative($0))" } ?? "Paired \(Format.relative(client.pairedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { tv.forget(client) }
                }
            }
            if let notice = tv.notice {
                HStack(alignment: .top) {
                    Text(notice).textSelection(.enabled)
                    Spacer()
                    Button("OK") { tv.dismissNotice() }
                }
            }
        }
    }
}
