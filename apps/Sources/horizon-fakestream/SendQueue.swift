import Foundation
import HorizonLink
import Synchronization

struct OutgoingItem: Sendable {
    enum Kind: Sendable {
        case control
        case video
        case audio
    }

    var data: Data
    var headers: [Int]
    var kind: Kind
    var generation: UInt32 = 0

    static func control(_ data: Data) -> OutgoingItem {
        OutgoingItem(data: data, headers: [0], kind: .control)
    }
}

final class SendQueue: Sendable {
    static let maxVideo = 8
    static let maxAudio = 40

    private struct State {
        var items: [OutgoingItem] = []
        var video = 0
        var audio = 0
        var up = false
        var broken = false
        var untilRefresh = false
        var generation: UInt32 = 0

        mutating func dropQueued(keepControl: Bool) {
            items.removeAll { !keepControl || $0.kind != .control }
            video = 0
            audio = 0
        }
    }

    private let state = Mutex(State())
    private let ready = DispatchSemaphore(value: 0)
    private let stats: Stats

    init(stats: Stats) {
        self.stats = stats
    }

    func linkUp() {
        state.withLock { state in
            state.up = true
            state.broken = false
            state.untilRefresh = false
            state.dropQueued(keepControl: false)
        }
    }

    func linkDown() {
        state.withLock { state in
            state.up = false
            state.dropQueued(keepControl: false)
        }
    }

    func markBroken() {
        state.withLock { $0.broken = true }
        ready.signal()
    }

    func setGeneration(_ value: UInt32) {
        state.withLock { state in
            state.generation = value
            state.dropQueued(keepControl: true)
        }
    }

    func enqueue(_ item: OutgoingItem, frameFlags: DMStream.FrameFlags = []) -> Bool {
        let (queued, full) = state.withLock { state -> (Bool, Bool) in
            guard state.up else { return (false, false) }
            switch item.kind {
            case .video:
                guard item.generation == state.generation else { return (false, false) }
                let fresh = !frameFlags.isDisjoint(with: [.sync, .refresh])
                let full = state.video >= Self.maxVideo
                if (state.untilRefresh && !fresh) || full {
                    if full { state.untilRefresh = true }
                    stats.queueDrops.add(1, ordering: .relaxed)
                    return (false, full)
                }
                state.untilRefresh = false
                state.video += 1
            case .audio:
                if state.audio >= Self.maxAudio, let oldest = state.items.firstIndex(where: { $0.kind == .audio }) {
                    state.items.remove(at: oldest)
                    state.audio -= 1
                }
                state.audio += 1
            case .control:
                break
            }
            state.items.append(item)
            return (true, false)
        }
        if queued { ready.signal() }
        return full
    }

    func pop() -> OutgoingItem? {
        while true {
            ready.wait()
            let next = state.withLock { state -> (item: OutgoingItem?, broken: Bool) in
                if state.broken { return (nil, true) }
                guard !state.items.isEmpty else { return (nil, false) }
                let item = state.items.removeFirst()
                switch item.kind {
                case .video: state.video -= 1
                case .audio: state.audio -= 1
                case .control: break
                }
                return (item, false)
            }
            if next.broken { return nil }
            if let item = next.item { return item }
        }
    }
}
