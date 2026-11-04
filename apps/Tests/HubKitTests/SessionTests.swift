import Foundation
import Testing
@testable import HubKit

let sleeper = "echo started\nwhile :; do sleep 0.1; done\n"
let graceful = "trap 'echo \"[dm] graceful exit done (0.010 s)\"; exit 0' TERM\necho started\nwhile :; do sleep 0.1; done\n"

@Suite(.serialized)
struct LauncherTests {
    @Test func childGetsTheEnvironmentDirectoryAndItsOwnSession() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let script = "pwd > \"$HUB_TEST_ROOT/pwd\"\nenv | sort > \"$HUB_TEST_ROOT/env\"\necho \"$1\" > \"$HUB_TEST_ROOT/arg\"\n" + sleeper
        let session = try games.open(try games.catalog(script: script))
        try await waitUntil { games.scratch.exists("arg") && games.scratch.read("env").contains("DM_STREAM") }
        #expect(getsid(session.pid) == session.pid)
        #expect(getpgid(session.pid) == session.pid)
        #expect(games.scratch.read("pwd") == physical(games.scratch.path("run")) + "\n")
        #expect(games.scratch.read("arg") == games.scratch.path("program") + "\n")
        let environment = games.scratch.read("env")
        #expect(environment.contains("DM_SAVE=\(games.scratch.path("saves/test"))\n"))
        #expect(environment.contains("DM_NICK=Tester\n"))
        #expect(environment.contains("DM_AUDIO=1\n"))
        #expect(!environment.contains("DM_CTL="))
        #expect(!environment.contains("SSH_AUTH_SOCK="))
        #expect(games.scratch.exists("saves/test"))
        session.close()
        _ = try await finished(session)
    }

    @Test func onlyTheBootLockIsInherited() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let stray = open(games.scratch.path("stray"), O_CREAT | O_RDWR, 0o600)
        defer { close(stray) }
        let script = """
            /bin/sh -c 'fd=3; while [ $fd -lt 1024 ]; do [ -e /dev/fd/$fd ] && echo $fd; fd=$((fd + 1)); done' >> "$HUB_TEST_ROOT/fds"
            echo done >> "$HUB_TEST_ROOT/fds"

            """ + sleeper
        let session = try games.open(try games.catalog(script: script))
        try await waitUntil { games.scratch.read("fds").contains("done") }
        let inherited = games.scratch.read("fds").split(separator: "\n").dropLast().compactMap { Int32($0) }
        #expect(!inherited.contains(stray))
        #expect(inherited.count == 1, "inherited descriptors: \(inherited)")
        session.close()
        _ = try await finished(session)
    }

    @Test func theGameKeepsTheLockWhenTheHubDies() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let session = try games.open(try games.catalog(script: sleeper))
        session.detach()
        #expect(isAlive(session.pid))
        #expect(BootLock.isHeld(path: games.state.lockPath))
        #expect(throws: GamesError.busy) { try BootLock.acquire(path: games.state.lockPath) }
        if hasGuard {
            let result = try await runGuard(state: games.scratch.path("state"), game: "hubtest", lockWait: 0, log: games.scratch.path("guard.log"))
            #expect(result.status == 3)
            #expect(result.stdoutText.contains("refused, another boot held state/boot.lock"))
        }
        kill(-session.pid, SIGKILL)
        try await waitUntil { !BootLock.isHeld(path: games.state.lockPath) }
    }

    @Test func aSecondGameIsRefused() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let catalog = try games.catalog(script: sleeper, extraGames: ["other"])
        let session = try games.open(catalog)
        #expect(throws: GamesError.alreadyRunning) {
            try GameSession.open(catalog: catalog, profile: "test", game: "other", settings: games.settings)
        }
        var elsewhere = games.settings
        elsewhere.supportDirectory = games.scratch.path("support-2")
        #expect(throws: GamesError.busy) {
            try GameSession.open(catalog: catalog, profile: "test", game: "other", settings: elsewhere)
        }
        session.close()
        _ = try await finished(session)
    }

    @Test func blocksRefuseBeforeStarting() throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let catalog = try games.catalog(script: "echo started > \"$HUB_TEST_ROOT/ran\"\n")
        try games.state.writeStopAll(why: "test", game: "x")
        #expect(throws: GamesError.self) { try games.open(catalog) }
        try FileManager.default.removeItem(atPath: games.scratch.path("state/STOP_ALL"))
        try games.state.writeStop(game: "hubtest", log: "/l", note: "Caused GPU")
        #expect(throws: GamesError.self) { try games.open(catalog) }
        #expect(!games.scratch.exists("ran"))
        #expect(!BootLock.isHeld(path: games.state.lockPath))
    }
}

@Suite(.serialized)
struct SessionTests {
    @Test func aGPUErrorKillsTheGroupAndBlocksTheGame() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let script = "sleep 600 &\necho $! > \"$HUB_TEST_ROOT/grandchild\"\necho booting\nsleep 0.3\necho \(shellQuoted(ownLine))\nwhile :; do sleep 0.1; done\n"
        let session = try games.open(try games.catalog(script: script))
        let outcome = try await finished(session)
        #expect(outcome.kind == .gpu)
        #expect(outcome.exit == ExitStatus.signaled(SIGKILL))
        let grandchild = try #require(Int32(games.scratch.read("grandchild").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isAlive(grandchild))
        #expect(games.scratch.read("state/STOP_hubtest").contains("Caused GPU Address Fault"))
        #expect(games.scratch.read("state/events.tsv").contains("\thubtest\tgpu\t"))
        #expect(!games.scratch.exists("state/STOP_ALL"))
        #expect(!BootLock.isHeld(path: games.state.lockPath))
        #expect(!games.scratch.exists("support/session.json"))
    }

    @Test func aMarkerSplitAcrossReadsIsCaught() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let script = "printf 'error kIOGPUCommandBuff'\nsleep 0.4\nprintf 'erCallbackErrorHang\\n'\nwhile :; do sleep 0.1; done\n"
        let session = try games.open(try games.catalog(script: script))
        let outcome = try await finished(session)
        #expect(outcome.kind == .gpu)
    }

    @Test func aVictimOfAnotherProcessIsClosedWithoutABlock() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        try games.report(process: "AirPlayXPCHelper")
        let script = "echo booting\nsleep 0.2\necho \(shellQuoted(victimLine))\nwhile :; do sleep 0.1; done\n"
        let session = try games.open(try games.catalog(script: script))
        let outcome = try await finished(session)
        #expect(outcome.kind == .gpuOther)
        #expect(outcome.culprits == ["AirPlayXPCHelper"])
        #expect(!games.scratch.exists("state/STOP_hubtest"))
        #expect(games.scratch.read("state/events.tsv").contains("\thubtest\tgpu-other\t"))
        #expect(games.scratch.read("state/events.tsv").contains("AirPlayXPCHelper"))
        #expect(!isAlive(session.pid))
    }

    @Test(arguments: [["fakehost"], [], ["WindowServer"], ["WindowServer", "fakehost", "ghostty"]])
    func aVictimLineWithoutAnotherCulpritBlocks(_ reports: [String]) async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        for (index, process) in reports.enumerated() {
            try games.report(process: process, name: "gpuEvent-\(process)-2026-11-03-17394\(index).ips")
        }
        let script = "echo \(shellQuoted(victimLine))\nwhile :; do sleep 0.1; done\n"
        let session = try games.open(try games.catalog(script: script))
        let outcome = try await finished(session)
        #expect(outcome.kind == .gpu)
        #expect(games.scratch.exists("state/STOP_hubtest"))
    }

    @Test func aThirdGPUErrorInAnHourStopsEverything() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let recent = GuardState.stamp(Date().addingTimeInterval(-300))
        try games.scratch.write("state/events.tsv", "\(recent)\tdk\tgpu\t5\t/a\t\n\(recent)\tmkw\tgpu\t5\t/b\t\n")
        let session = try games.open(try games.catalog(script: "echo \(shellQuoted(ownLine))\nwhile :; do sleep 0.1; done\n"))
        let outcome = try await finished(session)
        #expect(outcome.kind == .gpu)
        #expect(outcome.stopAll == "three GPU errors within an hour")
        #expect(games.scratch.read("state/STOP_ALL").contains("out of control, three GPU errors within an hour (hubtest)"))
    }

    @Test(.enabled(if: hasGuard)) func theStopIsWrittenBeforeTheLockIsReleased() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let session = try games.open(try games.catalog(script: "sleep 1.5\necho \(shellQuoted(ownLine))\nwhile :; do sleep 0.1; done\n"))
        async let waiting = runGuard(state: games.scratch.path("state"), game: "hubtest", lockWait: 30, log: games.scratch.path("guard.log"))
        let outcome = try await finished(session)
        #expect(outcome.kind == .gpu)
        let result = try await waiting
        #expect(result.status == 3)
        #expect(result.stdoutText.contains("refused, STOP_hubtest"))
        #expect(!games.scratch.exists("guard.log"))
    }

    @Test func closeEndsWithAGracefulExit() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let session = try games.open(try games.catalog(script: graceful))
        try await waitUntil { (try? String(contentsOfFile: session.record.log, encoding: .utf8))?.contains("started") == true }
        session.close()
        let outcome = try await finished(session)
        #expect(outcome.kind == .closed)
        #expect(outcome.exit == ExitStatus.exited(0))
        #expect(outcome.gracefulExit)
        let events = games.scratch.read("state/events.tsv")
        #expect(events.contains("\thubtest\tclosed\t"))
        #expect(events.contains("profile test; exit 0; closed from HorizonHub, graceful exit done"))
        #expect(!games.scratch.exists("state/STOP_hubtest"))
    }

    @Test func closeKillsAGameThatIgnoresTerm() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let session = try games.open(try games.catalog(script: "trap '' TERM\n" + sleeper))
        try await waitUntil { (try? String(contentsOfFile: session.record.log, encoding: .utf8))?.contains("started") == true }
        session.close()
        let outcome = try await finished(session)
        #expect(outcome.kind == .closed)
        #expect(outcome.exit == ExitStatus.signaled(SIGKILL))
    }

    @Test func criticalMemoryOnlySendsTerm() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let script = "trap 'echo got-term' TERM\n" + sleeper
        let session = try games.open(try games.catalog(script: script))
        try await waitUntil { (try? String(contentsOfFile: session.record.log, encoding: .utf8))?.contains("started") == true }
        session.simulateCriticalMemory()
        try await waitUntil { (try? String(contentsOfFile: session.record.log, encoding: .utf8))?.contains("got-term") == true }
        try await Task.sleep(for: .seconds(3))
        #expect(isAlive(session.pid))
        #expect(session.currentStatus.memoryCritical)
        kill(-session.pid, SIGKILL)
        let outcome = try await finished(session)
        #expect(outcome.kind == .memory)
    }

    @Test func aLowMemoryLevelWarns() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        var settings = games.settings
        settings.memoryLevel = { 8 }
        let session = try games.open(try games.catalog(script: sleeper), settings: settings)
        try await waitUntil { session.currentStatus.memoryWarning }
        #expect(session.currentStatus.memoryLevel == 8)
        #expect(session.currentStatus.phase == .running)
        session.close()
        _ = try await finished(session)
    }

    @Test func aBusErrorWithTheVolumeGoneIsAnSSDLoss() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let session = try games.open(try games.catalog(script: "sleep 0.2\nrm -rf \"$HUB_TEST_VOLUME\"\nkill -BUS $$\n"))
        let outcome = try await finished(session)
        #expect(outcome.kind == .ssdLost)
        #expect(outcome.exit == ExitStatus.signaled(SIGBUS))
        #expect(games.scratch.read("state/events.tsv").contains("\thubtest\tssd-lost\t"))
    }

    @Test func aGameThatQuitsOnItsOwnHasEnded() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let session = try games.open(try games.catalog(script: "echo bye\nexit 0\n"))
        let outcome = try await finished(session)
        #expect(outcome.kind == .ended)
        #expect(outcome.exit == ExitStatus.exited(0))
    }

    @Test func aRestartedHubAdoptsTheGameAndClosesIt() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let first = try games.open(try games.catalog(script: graceful))
        try await waitUntil { (try? String(contentsOfFile: first.record.log, encoding: .utf8))?.contains("started") == true }
        first.detach()
        let adopted = try #require(GameSession.adopt(settings: games.settings))
        #expect(adopted.adopted)
        #expect(adopted.record.process == first.record.process)
        #expect(adopted.record.log == first.record.log)
        #expect(adopted.currentStatus.phase == .running)
        adopted.close()
        let outcome = try await finished(adopted)
        #expect(outcome.kind == .closed)
        #expect(outcome.exit == nil)
        #expect(outcome.gracefulExit)
        #expect(!games.scratch.exists("support/session.json"))
        #expect(games.scratch.read("state/events.tsv").contains("profile test; adopted; closed from HorizonHub, graceful exit done"))
    }

    @Test func anAdoptedGameKeepsTheLockHeldUntilItsEventIsWritten() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        var settings = games.settings
        settings.reportWait = 3
        let script = "echo started\nwhile [ ! -e \"$HUB_TEST_ROOT/go\" ]; do sleep 0.05; done\necho \(shellQuoted(victimLine))\nwhile :; do sleep 0.1; done\n"
        let first = try games.open(try games.catalog(script: script), settings: settings)
        try await waitUntil { (try? String(contentsOfFile: first.record.log, encoding: .utf8))?.contains("started") == true }
        first.detach()
        let adopted = try #require(GameSession.adopt(settings: settings))
        try games.scratch.write("go", "")
        try await waitUntil { !isAlive(first.pid) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(BootLock.isHeld(path: games.state.lockPath))
        #expect(!games.scratch.read("state/events.tsv").contains("\thubtest\t"))
        let outcome = try await finished(adopted)
        #expect(outcome.kind == .gpu)
        #expect(games.scratch.read("state/events.tsv").contains("\thubtest\tgpu\t"))
        #expect(!BootLock.isHeld(path: games.state.lockPath))
    }

    @Test func aRecordForAnotherProcessIsClosedWithoutTouchingIt() async throws {
        let games = try FakeGames()
        defer { games.scratch.remove() }
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        let identity = try #require(ProcessIdentity.of(other.processIdentifier))
        let record = SessionRecord(
            process: ProcessIdentity(pid: identity.pid, startSeconds: identity.startSeconds - 100, startMicroseconds: 0),
            game: "hubtest", title: "Fake", profile: "test", profileName: "Test",
            log: games.scratch.path("logs/old.log"), state: games.scratch.path("state"), processName: "fakehost",
            startedAt: Date().addingTimeInterval(-600)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: URL(fileURLWithPath: games.settings.sessionFile))
        let session = try #require(GameSession.adopt(settings: games.settings))
        let outcome = try await finished(session)
        #expect(outcome.kind == .ended)
        #expect(outcome.note == "ended while HorizonHub was not watching")
        #expect(other.isRunning)
        #expect(!games.scratch.exists("support/session.json"))
    }
}
