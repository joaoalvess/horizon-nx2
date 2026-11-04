import Foundation
import HorizonLink

enum Resolution: Int, CaseIterable, Sendable {
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440

    var size: (width: UInt16, height: UInt16) {
        switch self {
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        case .p1440: (2560, 1440)
        }
    }

    var label: String { "\(rawValue)p" }
}

enum Bitrate: UInt32, CaseIterable, Sendable {
    case automatic = 0
    case low = 15000
    case medium = 25000
    case high = 40000
    case highest = 60000

    var label: String { self == .automatic ? "Automatic" : "\(rawValue / 1000) Mbps" }
}

extension DMStream.Codec {
    var label: String {
        switch self {
        case .avc1: "H.264"
        case .hvc1: "HEVC"
        }
    }
}

extension ButtonLayout {
    var label: String {
        switch self {
        case .positional: "By position"
        case .labeled: "By letter"
        }
    }
}

struct StreamOptions: Equatable, Sendable {
    var resolution = Resolution.p1080
    var bitrate = Bitrate.automatic
    var codec = DMStream.Codec.avc1
    var layout = ButtonLayout.positional

    var attach: DMStream.Attach {
        let size = resolution.size
        return DMStream.Attach(refreshHz: 60, width: size.width, height: size.height, codec: codec.rawValue, bitrateKbps: bitrate.rawValue)
    }

    static func load(_ defaults: UserDefaults = .standard) -> StreamOptions {
        var options = StreamOptions()
        if let value = Resolution(rawValue: defaults.integer(forKey: "resolution")) { options.resolution = value }
        if let value = Bitrate(rawValue: UInt32(clamping: defaults.integer(forKey: "bitrate"))) { options.bitrate = value }
        if let value = DMStream.Codec(rawValue: UInt32(clamping: defaults.integer(forKey: "codec"))) { options.codec = value }
        if let raw = defaults.string(forKey: "layout"), let value = ButtonLayout(rawValue: raw) { options.layout = value }
        return options
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(resolution.rawValue, forKey: "resolution")
        defaults.set(Int(bitrate.rawValue), forKey: "bitrate")
        defaults.set(Int(codec.rawValue), forKey: "codec")
        defaults.set(layout.rawValue, forKey: "layout")
    }
}

extension CaseIterable where Self: Equatable, AllCases: BidirectionalCollection {
    func next() -> Self {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let following = all.index(after: index)
        return following == all.endIndex ? all[all.startIndex] : all[following]
    }
}
