import Foundation
import HorizonLink

struct OptionError: Error {
    let message: String
}

struct ReceiverOptions: Sendable {
    var hub: (host: String, port: UInt16)?
    var hubName: String?
    var name: String
    var window = false
    var seconds: Double?
    var tsvPath: String?
    var drop = LinkDrop()
    var pngDirectory: String?
    var pngEvery: Double = 5
    var attach = DMStream.Attach(refreshHz: 60, width: 1920, height: 1080, codec: DMStream.Codec.avc1.rawValue, bitrateKbps: 0)
    var audio = true
    var limitMs: Double = 25
    var help = false

    static let usage = """
        Usage: horizon-receiver [options]
          --hub host:port         connect straight to the hub (without it, looks for _horizonhub._tcp over Bonjour)
          --hub-name name         pick the Mac by name when Bonjour finds more than one
          --name name             this receiver's name (default: "Receiver <machine>")
          --headless              decode without showing the video (default)
          --window                open a window with the video
          --seconds N             stop after N seconds
          --tsv path              write one line per frame (a new connection writes to path-2, -3...)
          --drop list             simulated loss: media=0.01,feedback=0.01,burst=200x20,seed=7
          --png folder            save PNGs of the decoded frames
          --png-every seconds     interval between PNGs (default 5)
          --attach WxH@Hz         size and rate asked of the game (default 1920x1080@60)
          --codec avc1|hvc1       codec asked for (default avc1)
          --kbps N                bitrate in kbit/s (0 = the hub's default)
          --no-audio              do not play the audio
          --limit ms              latency limit for the summary (default 25)
        """

    static func defaultName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        return "Receiver \(trimmed)"
    }

    static func parse(_ arguments: [String]) throws -> ReceiverOptions {
        var options = ReceiverOptions(name: defaultName())
        var headless = false
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw OptionError(message: "\(flag) needs a value") }
            return arguments[index]
        }
        func number(_ flag: String) throws -> Double {
            let text = try value(flag)
            guard let parsed = Double(text.replacingOccurrences(of: ",", with: ".")), parsed >= 0 else {
                throw OptionError(message: "\(flag) expects a number, got \(text)")
            }
            return parsed
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--hub": options.hub = try hostPort(try value(flag))
            case "--hub-name": options.hubName = try value(flag)
            case "--name": options.name = try value(flag)
            case "--headless": headless = true
            case "--window": options.window = true
            case "--seconds":
                let seconds = try number(flag)
                guard seconds > 0 else { throw OptionError(message: "--seconds must be greater than zero") }
                options.seconds = seconds
            case "--tsv": options.tsvPath = try value(flag)
            case "--drop": options.drop = try drop(try value(flag))
            case "--png": options.pngDirectory = try value(flag)
            case "--png-every":
                let every = try number(flag)
                guard every > 0 else { throw OptionError(message: "--png-every must be greater than zero") }
                options.pngEvery = every
            case "--attach": options.attach = try attach(try value(flag), base: options.attach)
            case "--codec":
                let text = try value(flag)
                switch text {
                case "avc1": options.attach.codec = DMStream.Codec.avc1.rawValue
                case "hvc1": options.attach.codec = DMStream.Codec.hvc1.rawValue
                default: throw OptionError(message: "--codec takes avc1 or hvc1, got \(text)")
                }
            case "--kbps":
                let kbps = try number(flag)
                guard kbps <= Double(UInt32.max) else { throw OptionError(message: "--kbps is too large") }
                options.attach.bitrateKbps = UInt32(kbps)
            case "--no-audio": options.audio = false
            case "--limit": options.limitMs = try number(flag)
            case "--help", "-h": options.help = true
            default: throw OptionError(message: "unknown option: \(flag)")
            }
            index += 1
        }
        if headless, options.window { throw OptionError(message: "use --headless or --window, not both") }
        return options
    }

    static func hostPort(_ text: String) throws -> (host: String, port: UInt16) {
        let missing = OptionError(
            message: "--hub needs the port (host:port); the hub picks its port when it opens, so without --hub the receiver finds the Mac over Bonjour"
        )
        let host: String
        let portText: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw OptionError(message: "IPv6 address without ]: \(text)") }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":") else { throw missing }
            portText = rest.dropFirst()
        } else {
            guard let colon = text.lastIndex(of: ":"), text.firstIndex(of: ":") == colon else { throw missing }
            host = String(text[..<colon])
            portText = text[text.index(after: colon)...]
        }
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else { throw OptionError(message: "invalid port in \(text)") }
        return (host, port)
    }

    static func drop(_ text: String) throws -> LinkDrop {
        var drop = LinkDrop()
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { throw OptionError(message: "--drop expects key=value, got \(part)") }
            switch pair[0] {
            case "media":
                guard let value = Double(pair[1]), (0...1).contains(value) else { throw OptionError(message: "media must be between 0 and 1") }
                drop.mediaLoss = value
            case "feedback":
                guard let value = Double(pair[1]), (0...1).contains(value) else { throw OptionError(message: "feedback must be between 0 and 1") }
                drop.feedbackLoss = value
            case "burst":
                let numbers = pair[1].split(separator: "x").compactMap { Int($0) }
                guard numbers.count == 2, numbers[0] > 0, numbers[1] >= 0, numbers[1] < numbers[0] else {
                    throw OptionError(message: "burst expects <every>x<length>, for example 200x20")
                }
                drop.burstEvery = numbers[0]
                drop.burstLength = numbers[1]
            case "seed":
                guard let value = UInt64(pair[1]) else { throw OptionError(message: "seed expects an integer") }
                drop.seed = value
            default:
                throw OptionError(message: "--drop does not know \(pair[0]); use media, feedback, burst and seed")
            }
        }
        return drop
    }

    static func attach(_ text: String, base: DMStream.Attach) throws -> DMStream.Attach {
        let invalid = OptionError(message: "--attach expects WxH@Hz, for example 1920x1080@60")
        let sizeAndRate = text.split(separator: "@")
        guard sizeAndRate.count == 2, let rate = UInt16(sizeAndRate[1]), rate > 0 else { throw invalid }
        let size = sizeAndRate[0].split(separator: "x")
        guard size.count == 2, let width = UInt16(size[0]), let height = UInt16(size[1]), width > 0, height > 0 else { throw invalid }
        var attach = base
        attach.width = width
        attach.height = height
        attach.refreshHz = rate
        return attach
    }
}
