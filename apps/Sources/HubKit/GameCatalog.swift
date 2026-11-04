import Foundation

public enum GamesError: Error, Equatable, CustomStringConvertible {
    case catalog(String)
    case blocked(name: String, text: String)
    case busy
    case alreadyRunning
    case unavailable(String)
    case launch(String)

    public var description: String {
        switch self {
        case .catalog(let message): "game catalog: \(message)"
        case .blocked(let name, let text): "refused, \(name): \(text)"
        case .busy: "refused, another boot holds boot.lock"
        case .alreadyRunning: "refused, a game started by HorizonHub is still running"
        case .unavailable(let message): message
        case .launch(let message): message
        }
    }
}

public struct GameProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var nick: String
    public var saves: [String: String]?
    public var sync: [String: String]?

    public init(id: String, name: String, nick: String, saves: [String: String]? = nil, sync: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.nick = nick
        self.saves = saves
        self.sync = sync
    }
}

public struct Game: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var titleId: String
    public var host: String
    public var program: String
    public var directory: String
    public var logs: String
    public var saves: String
    public var psoUser: String
    public var environment: [String: String]

    public init(
        id: String,
        title: String,
        titleId: String,
        host: String,
        program: String,
        directory: String,
        logs: String,
        saves: String,
        psoUser: String,
        environment: [String: String]
    ) {
        self.id = id
        self.title = title
        self.titleId = titleId
        self.host = host
        self.program = program
        self.directory = directory
        self.logs = logs
        self.saves = saves
        self.psoUser = psoUser
        self.environment = environment
    }
}

public struct GameCatalog: Codable, Sendable, Equatable {
    public static let defaultPath = "/Volumes/Hangar/Games/hangar-games.json"
    public static let reservedVariables: Set<String> = [
        "DM_SAVE", "DM_NICK", "DM_PSO_USER", "DM_SAVE_SYNC", "DM_STREAM", "DM_AUDIO", "DM_WINDOW", "DM_CTL", "DM_LAUNCHER",
    ]

    public var version: Int
    public var state: String
    public var profiles: [GameProfile]
    public var games: [Game]

    public init(version: Int = 1, state: String, profiles: [GameProfile], games: [Game]) {
        self.version = version
        self.state = state
        self.profiles = profiles
        self.games = games
    }

    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["HORIZON_GAMES_CATALOG"], !path.isEmpty { return path }
        return defaultPath
    }

    public static func load(path: String) throws -> GameCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw GamesError.catalog("\(path) could not be read: \(error.localizedDescription)")
        }
        return try decode(data, source: path)
    }

    public static func decode(_ data: Data, source: String) throws -> GameCatalog {
        let catalog: GameCatalog
        do {
            catalog = try JSONDecoder().decode(GameCatalog.self, from: data)
        } catch {
            throw GamesError.catalog("\(source) is not a valid catalog: \(error)")
        }
        try catalog.validate()
        return catalog
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func game(_ id: String) -> Game? { games.first { $0.id == id } }

    public func profile(_ id: String) -> GameProfile? { profiles.first { $0.id == id } }

    public func validate() throws {
        guard version == 1 else { throw GamesError.catalog("version \(version) is not supported") }
        try Self.requireAbsolute(state, "state")
        try Self.requireUnique(profiles.map(\.id), "profile")
        try Self.requireUnique(games.map(\.id), "game")
        for game in games {
            try Self.requireIdentifier(game.id, "game")
            for (field, value) in [
                ("host", game.host), ("program", game.program), ("directory", game.directory),
                ("logs", game.logs), ("saves", game.saves), ("psoUser", game.psoUser),
            ] {
                try Self.requireAbsolute(value, "\(game.id).\(field)")
            }
            let reserved = Set(game.environment.keys).intersection(Self.reservedVariables)
            guard reserved.isEmpty else {
                throw GamesError.catalog("\(game.id) sets \(reserved.sorted().joined(separator: ", ")), which the hub sets itself")
            }
        }
        for profile in profiles {
            try Self.requireIdentifier(profile.id, "profile")
            guard !profile.nick.isEmpty, profile.nick.utf8.count <= 32 else {
                throw GamesError.catalog("\(profile.id).nick must have 1 to 32 bytes")
            }
            for (field, map) in [("saves", profile.saves ?? [:]), ("sync", profile.sync ?? [:])] {
                for (gameId, path) in map {
                    guard game(gameId) != nil else { throw GamesError.catalog("\(profile.id).\(field) names unknown game \(gameId)") }
                    try Self.requireAbsolute(path, "\(profile.id).\(field).\(gameId)")
                }
            }
        }
        for game in games {
            var saveOwners: [String: String] = [:]
            var syncOwners: [String: String] = [:]
            for profile in profiles {
                let save = Self.standardized(savePath(profile: profile, game: game))
                if let other = saveOwners[save] {
                    throw GamesError.catalog("\(other) and \(profile.id) share the \(game.id) save \(save)")
                }
                saveOwners[save] = profile.id
                if let sync = syncPath(profile: profile, game: game).map(Self.standardized) {
                    if let other = syncOwners[sync] {
                        throw GamesError.catalog("\(other) and \(profile.id) share the \(game.id) sync folder \(sync)")
                    }
                    syncOwners[sync] = profile.id
                }
            }
        }
    }

    public func savePath(profile: GameProfile, game: Game) -> String {
        profile.saves?[game.id] ?? game.saves + "/" + profile.id
    }

    public func hasExplicitSave(profile: GameProfile, game: Game) -> Bool {
        profile.saves?[game.id] != nil
    }

    public func syncPath(profile: GameProfile, game: Game) -> String? {
        profile.sync?[game.id]
    }

    public func launchEnvironment(profile: GameProfile, game: Game, streamSocket: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        for key in ["USER", "TMPDIR"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment.merge(game.environment) { _, new in new }
        environment["DM_SAVE"] = savePath(profile: profile, game: game)
        environment["DM_NICK"] = profile.nick
        environment["DM_PSO_USER"] = game.psoUser
        environment["DM_SAVE_SYNC"] = syncPath(profile: profile, game: game) ?? "0"
        environment["DM_AUDIO"] = "1"
        environment["DM_WINDOW"] = "1"
        environment["DM_STREAM"] = streamSocket
        return environment
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func requireAbsolute(_ path: String, _ field: String) throws {
        guard path.hasPrefix("/") else { throw GamesError.catalog("\(field) must be an absolute path: \(path)") }
    }

    private static func requireUnique(_ ids: [String], _ kind: String) throws {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            throw GamesError.catalog("two \(kind)s have the id \(id)")
        }
    }

    private static func requireIdentifier(_ id: String, _ kind: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !id.isEmpty, id.allSatisfy(allowed.contains) else {
            throw GamesError.catalog("\(kind) id \(id) must use only a-z, 0-9, - and _")
        }
    }
}
