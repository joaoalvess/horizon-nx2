import Darwin
import Foundation
import HorizonLink
import Synchronization

enum Log {
    private static let queue = DispatchQueue(label: "fakestream.log", qos: .utility)

    static func line(_ text: String) {
        let bytes = Array("[dm] \(text)\n".utf8)
        queue.async {
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(STDOUT_FILENO, base + offset, buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    static func info(_ text: String) { line("fake stream: \(text)") }
    static func red(_ text: String) { line("[RED] fake stream: \(text)") }

    static func exit(_ code: Int32) -> Never {
        let flushed = DispatchSemaphore(value: 0)
        queue.async { flushed.signal() }
        _ = flushed.wait(timeout: .now() + .milliseconds(500))
        _exit(code)
    }
}

struct FakeStreamError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Settings: Sendable {
    static let defaultTitle: UInt64 = 0x0400_C3F0_0006_E000
    static let defaultFps = 60

    let program: String
    let socketPath: String?
    let titleId: UInt64
    let fps: Int
    let sendBuffer: Int32
    let build: String

    static func load() -> Settings {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, !arguments[1].isEmpty else {
            Log.red("usage: horizon-fakestream <recording.h264> (environment: DM_STREAM, FAKESTREAM_TITLE, FAKESTREAM_FPS)")
            Log.exit(2)
        }
        let environment = ProcessInfo.processInfo.environment
        var titleId = defaultTitle
        if let text = environment["FAKESTREAM_TITLE"], !text.isEmpty {
            let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
            if let value = UInt64(digits, radix: 16) { titleId = value } else {
                Log.red("FAKESTREAM_TITLE=\(text) is not a hex title id, using \(hex(defaultTitle))")
            }
        }
        var fps = defaultFps
        if let text = environment["FAKESTREAM_FPS"], !text.isEmpty {
            if let value = Int(text), (1...240).contains(value) { fps = value } else {
                Log.red("FAKESTREAM_FPS=\(text) is not 1 to 240, using \(defaultFps)")
            }
        }
        var sendBuffer: Int32 = 4 << 20
        if let text = environment["DM_STREAM_SNDBUF"], let value = Int32(text), value > 0 { sendBuffer = value }
        let socketPath = environment["DM_STREAM"].flatMap { $0.isEmpty ? nil : $0 }
        return Settings(program: arguments[1], socketPath: socketPath, titleId: titleId, fps: fps, sendBuffer: sendBuffer, build: build())
    }

    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    private static func build() -> String {
        var date = Date()
        if let path = Bundle.main.executablePath,
           let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            date = modified
        }
        return "horizon-fakestream \(ISO8601DateFormatter().string(from: date))"
    }
}

final class FakeStream: Sendable {
    private let host: Host
    private let pump: FramePump
    private let exiting = Atomic<Bool>(false)

    private init(host: Host, pump: FramePump) {
        self.host = host
        self.pump = pump
    }

    static func main() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "game")
        let settings = Settings.load()
        let recording: Recording
        let decoder: SourceDecoder
        do {
            recording = try Recording(path: settings.program)
            decoder = try SourceDecoder(recording: recording)
        } catch {
            Log.red("\(error)")
            Log.exit(1)
        }
        Log.info("\(settings.build), title \(Settings.hex(settings.titleId)), looping \(recording.path) "
            + "(\(recording.width)x\(recording.height), \(recording.size >> 20) MB mapped) at \(settings.fps) fps")
        let stats = Stats()
        let queue = SendQueue(stats: stats)
        let host = Host(settings: settings, width: recording.width, height: recording.height, queue: queue, stats: stats)
        let pump = FramePump(host: host, decoder: decoder, stats: stats, fps: settings.fps)
        let app = FakeStream(host: host, pump: pump)
        pump.start()
        if let path = settings.socketPath {
            if path.utf8.count > DMStream.maxSocketPath {
                Log.red("DM_STREAM=\(path) is longer than \(DMStream.maxSocketPath) bytes, the socket path limit: no stream")
            } else {
                HubLink(path: path, host: host, queue: queue, sendBuffer: settings.sendBuffer).start()
            }
        } else {
            Log.info("no DM_STREAM: nothing to stream")
        }
        let sources = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            let name = number == SIGTERM ? "SIGTERM" : "SIGINT"
            source.setEventHandler { app.shutdown(name) }
            source.resume()
            return source
        }
        withExtendedLifetime((sources, activity)) { dispatchMain() }
    }

    private func shutdown(_ why: String) {
        guard !exiting.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let start = LinkClock.nowNs()
        Log.line("received \(why): graceful exit")
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(1500)) {
            Log.line("[RED] graceful exit not done in 1.5 seconds, exiting at once")
            Log.exit(0)
        }
        pump.stop()
        host.stopForExit()
        Log.line(String(format: "graceful exit done (%.3f s)", Double(LinkClock.nowNs() - start) / 1e9))
        Log.exit(0)
    }
}
