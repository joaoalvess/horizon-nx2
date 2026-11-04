import Foundation
import Testing
@testable import HubKit

struct CatalogTests {
    static let json = #"""
    {
      "version": 1,
      "state": "/Volumes/Hangar/Games/overnight/state",
      "profiles": [
        { "id": "zoe", "name": "Zoë", "nick": "Zoe", "saves": { "mkw": "/Games/mkw-work/run/save" } },
        { "id": "test-j1", "name": "Test J1", "nick": "Test", "sync": { "mkw": "/Sync/test" } }
      ],
      "games": [
        {
          "id": "mkw",
          "title": "Mario Kart World",
          "titleId": "0400C3F00006E000",
          "host": "/Games/mkw-work/run2/hosts/play/dmhost",
          "program": "/Games/mkw_build/patched_v917504",
          "directory": "/Games/mkw-work/run/cwd",
          "logs": "/Games/mkw-work/run2",
          "saves": "/Games/mkw-work/saves",
          "psoUser": "/Games/mkw-work/run/pso_user.tsv",
          "environment": { "DM_ROMFS": "/Games/mkw_build/RomFS.img", "DM_LANG": "en-US" }
        }
      ]
    }
    """#

    @Test func buildsTheExactLaunchEnvironment() throws {
        let catalog = try GameCatalog.decode(Data(Self.json.utf8), source: "test")
        let game = try #require(catalog.game("mkw"))
        let zoe = try #require(catalog.profile("zoe"))
        let tester = try #require(catalog.profile("test-j1"))

        let environment = catalog.launchEnvironment(profile: tester, game: game, streamSocket: "/support/stream.sock")
        #expect(environment["DM_SAVE"] == "/Games/mkw-work/saves/test-j1")
        #expect(environment["DM_NICK"] == "Test")
        #expect(environment["DM_PSO_USER"] == "/Games/mkw-work/run/pso_user.tsv")
        #expect(environment["DM_SAVE_SYNC"] == "/Sync/test")
        #expect(environment["DM_AUDIO"] == "1")
        #expect(environment["DM_WINDOW"] == "1")
        #expect(environment["DM_STREAM"] == "/support/stream.sock")
        #expect(environment["DM_ROMFS"] == "/Games/mkw_build/RomFS.img")
        let expected: Set<String> = [
            "PATH", "HOME", "LANG", "DM_ROMFS", "DM_LANG", "DM_SAVE", "DM_NICK", "DM_PSO_USER", "DM_SAVE_SYNC", "DM_AUDIO", "DM_WINDOW",
            "DM_STREAM",
        ]
        #expect(Set(environment.keys).subtracting(["USER", "TMPDIR"]) == expected)

        let zoeEnvironment = catalog.launchEnvironment(profile: zoe, game: game, streamSocket: "/s")
        #expect(zoeEnvironment["DM_SAVE"] == "/Games/mkw-work/run/save")
        #expect(zoeEnvironment["DM_SAVE_SYNC"] == "0")
        #expect(catalog.hasExplicitSave(profile: zoe, game: game))
        #expect(!catalog.hasExplicitSave(profile: tester, game: game))
    }

    @Test func rejectsTwoProfilesOnOneSave() throws {
        var catalog = try GameCatalog.decode(Data(Self.json.utf8), source: "test")
        catalog.profiles[1].saves = ["mkw": "/Games/mkw-work/run/save/"]
        #expect(throws: GamesError.self) { try catalog.validate() }

        catalog.profiles[1].saves = nil
        catalog.profiles[0].saves = ["mkw": "/Games/mkw-work/saves/test-j1"]
        #expect(throws: GamesError.self) { try catalog.validate() }
    }

    @Test func rejectsTwoProfilesOnOneSyncFolder() throws {
        var catalog = try GameCatalog.decode(Data(Self.json.utf8), source: "test")
        catalog.profiles[0].sync = ["mkw": "/Sync/test"]
        #expect(throws: GamesError.self) { try catalog.validate() }
    }

    @Test(arguments: ["DM_SAVE", "DM_CTL", "DM_NICK", "DM_STREAM"])
    func rejectsVariablesTheHubOwns(_ name: String) throws {
        var catalog = try GameCatalog.decode(Data(Self.json.utf8), source: "test")
        catalog.games[0].environment[name] = "/x"
        #expect(throws: GamesError.self) { try catalog.validate() }
    }

    @Test func rejectsBadFields() throws {
        let base = try GameCatalog.decode(Data(Self.json.utf8), source: "test")
        var catalog = base
        catalog.profiles[0].nick = String(repeating: "a", count: 33)
        #expect(throws: GamesError.self) { try catalog.validate() }
        catalog = base
        catalog.games[0].id = "Mario Kart"
        #expect(throws: GamesError.self) { try catalog.validate() }
        catalog = base
        catalog.games[0].host = "dmhost"
        #expect(throws: GamesError.self) { try catalog.validate() }
        catalog = base
        catalog.profiles[0].saves = ["dk": "/x"]
        #expect(throws: GamesError.self) { try catalog.validate() }
        catalog = base
        catalog.profiles.append(base.profiles[0])
        #expect(throws: GamesError.self) { try catalog.validate() }
    }

    @Test func pathComesFromTheEnvironment() {
        #expect(GameCatalog.path(environment: [:]) == "/Volumes/Hangar/Games/hangar-games.json")
        #expect(GameCatalog.path(environment: ["HORIZON_GAMES_CATALOG": "/tmp/c.json"]) == "/tmp/c.json")
    }
}

struct GuardStateTests {
    @Test func eventLinesMatchTheGuardFormat() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let now = Date(timeIntervalSince1970: 1_793_738_385)
        try games.state.appendEvent(game: "mkw", reason: "closed", seconds: 1800, log: "/l.log", note: "profile x;\texit 0\nmore", now: now)
        let line = games.scratch.read("state/events.tsv")
        let fields = line.dropLast().split(separator: "\t", omittingEmptySubsequences: false)
        #expect(line.hasSuffix("\n"))
        #expect(fields.count == 6)
        #expect(fields[0] == Substring(GuardState.stamp(now)))
        #expect(fields[0].count == 19)
        #expect(Array(fields[1...4]) == ["mkw", "closed", "1800", "/l.log"])
        #expect(fields[5] == "profile x; exit 0 more")
    }

    @Test func countsOnlyRecentGPUErrors() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let now = Date()
        let lines = [
            "\(GuardState.stamp(now.addingTimeInterval(-7200)))\tdk\tgpu\t10\t/a\t",
            "\(GuardState.stamp(now.addingTimeInterval(-1800)))\tdk\tgpu\t10\t/b\t",
            "\(GuardState.stamp(now.addingTimeInterval(-600)))\tmkw\tgpu-other\t10\t/c\t",
            "\(GuardState.stamp(now.addingTimeInterval(-60)))\tmkw\tgpu\t10\t/d\t",
        ]
        try games.scratch.write("state/events.tsv", lines.joined(separator: "\n") + "\n")
        #expect(games.state.gpuErrorsInLastHour(now: now) == 2)
    }

    @Test func listsAndReleasesBlocks() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let state = games.state
        try state.writeStop(game: "dk", log: "/l.log", note: "Caused GPU Hang")
        try state.writeStopAll(why: "three GPU errors within an hour", game: "dk")
        try games.scratch.write("state/STOP_mkw.resolved-0430", "old")
        #expect(state.allBlocks().map(\.name) == ["STOP_ALL", "STOP_dk"])
        #expect(state.blocks(for: "dk").map(\.name) == ["STOP_ALL", "STOP_dk"])
        #expect(state.blocks(for: "mkw").map(\.name) == ["STOP_ALL"])
        #expect(throws: GamesError.self) { try state.ensureNotBlocked(game: "mkw") }

        let now = Date()
        let block = try #require(state.allBlocks().last)
        #expect(block.text.hasSuffix("/l.log: Caused GPU Hang"))
        let first = try state.release(block, now: now)
        #expect(first == block.path + ".resolved-" + GuardState.format("HHmm", now))
        try state.writeStop(game: "dk", log: "/l.log", note: "again")
        let second = try state.release(try #require(state.blocks(for: "dk").last), now: now)
        #expect(second == first + "-2")
        #expect(state.blocks(for: "dk").map(\.name) == ["STOP_ALL"])
        #expect(games.scratch.read("state/events.tsv").contains("\tdk\treleased\t0\t\treleased from HorizonHub: "))
    }

    @Test func bootLockIsExclusiveUntilClosed() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let path = games.state.lockPath
        let lock = try BootLock.acquire(path: path)
        #expect(BootLock.isHeld(path: path))
        #expect(throws: GamesError.busy) { try BootLock.acquire(path: path) }
        lock.close()
        #expect(!BootLock.isHeld(path: path))
        _ = try BootLock.acquire(path: path)
    }

    @Test func probingTheLockNeverTakesIt() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let path = games.state.lockPath
        try BootLock.acquire(path: path).close()
        let descriptor = open(path, O_RDWR | O_CLOEXEC)
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(1)
        let prober = Thread {
            while Date() < deadline { _ = BootLock.isHeld(path: path) }
        }
        prober.start()
        var refused = 0
        while Date() < deadline {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { flock(descriptor, LOCK_UN) } else { refused += 1 }
        }
        #expect(refused == 0)
    }
}

struct GPUErrorsTests {
    @Test func victimLinesAloneAreVictimOnly() {
        #expect(GPUErrors.isVictimOnly([victimLine, victimLine]))
        #expect(!GPUErrors.isVictimOnly([victimLine, ownLine]))
        #expect(!GPUErrors.isVictimOnly([ownLine]))
        #expect(!GPUErrors.isVictimOnly([]))
        #expect(!GPUErrors.isVictimOnly(["dmhost[812:1a] IOGPUMetalError: something"]))
        #expect(!GPUErrors.isVictimOnly(["Ignored (for causing prior/excessive GPU errors) (00000004:kIOGPUCommandBufferCallbackErrorSubmissionsIgnored)"]))
    }

    @Test func classifiesByLinesThenReports() {
        #expect(GPUErrors.classify(lines: [ownLine], reportProcesses: ["AirPlayXPCHelper"], gameProcess: "dmhost") == .own)
        #expect(GPUErrors.classify(lines: [victimLine], reportProcesses: [], gameProcess: "dmhost") == .own)
        #expect(GPUErrors.classify(lines: [victimLine], reportProcesses: ["WindowServer", "WindowServer"], gameProcess: "dmhost") == .own)
        #expect(GPUErrors.classify(lines: [victimLine], reportProcesses: ["WindowServer", "dmhost_mkw", "ghostty"], gameProcess: "dmhost") == .own)
        #expect(
            GPUErrors.classify(lines: [victimLine], reportProcesses: ["AirPlayXPCHelper", "WindowServer"], gameProcess: "dmhost")
                == .victim(culprits: ["AirPlayXPCHelper"])
        )
    }

    @Test func readsReportsInTheWindowFromBothFolders() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        try games.report(process: "AirPlayXPCHelper")
        try games.scratch.write("reports/Retired/gpuEvent-ghostty-2026-11-02-131040.ips", "not json")
        try games.report(process: "WindowServer", name: "gpuEvent-WindowServer-2026-11-01-101010.ips")
        let old = games.scratch.path("reports/gpuEvent-WindowServer-2026-11-01-101010.ips")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old)
        let names = GPUErrors.reportProcesses(
            in: [games.scratch.path("reports"), games.scratch.path("reports/Retired")],
            from: Date().addingTimeInterval(-60),
            to: Date().addingTimeInterval(1)
        )
        #expect(names.sorted() == ["AirPlayXPCHelper", "ghostty"])
    }

    @Test func findsAMarkerAnywhereInAChunk() {
        let data = Data("line one\nfoo kIOGPUCommandBufferCallbackErrorHang bar\n".utf8)
        let range = GPUErrors.firstMatch(in: data)
        #expect(range.map { String(decoding: data[$0], as: UTF8.self) } == "kIOGPUCommandBufferCallbackError")
        #expect(GPUErrors.firstMatch(in: Data("[dm] fs mount save: ok\n".utf8)) == nil)
    }
}

struct SSDUnlockTests {
    func plist(locked: Bool, name: String = "Hangar") throws -> Data {
        let root: [String: Any] = [
            "Containers": [
                ["Volumes": [["Name": "Macintosh HD", "Locked": false, "DeviceIdentifier": "disk3s1"]]],
                ["Volumes": [["Name": name, "Locked": locked, "DeviceIdentifier": "disk9s1", "APFSVolumeUUID": "716C"]]],
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    @Test func findsOnlyALockedHangarVolume() throws {
        #expect(try SSDUnlock.lockedVolume(named: "Hangar", plist: plist(locked: true)) == LockedVolume(device: "disk9s1", name: "Hangar", uuid: "716C"))
        #expect(try SSDUnlock.lockedVolume(named: "Hangar", plist: plist(locked: false)) == nil)
        #expect(try SSDUnlock.lockedVolume(named: "Hangar", plist: plist(locked: true, name: "Other")) == nil)
    }
}
