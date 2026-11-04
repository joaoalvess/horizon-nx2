import Foundation

public struct LockedVolume: Sendable, Equatable {
    public let device: String
    public let name: String
    public let uuid: String
}

public enum SSDUnlock {
    public static let volumeName = "Hangar"
    public static let keychain = Keychain(service: "dev.joaoalvess.horizon.hub", account: "ssd-hangar")

    public static func lockedVolume(named name: String = volumeName, runner: ProcessRunner = ProcessRunner()) throws -> LockedVolume? {
        let result = try runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 30)
        guard result.status == 0 else { throw GamesError.unavailable("diskutil apfs list failed: \(result.stderrText)") }
        return try lockedVolume(named: name, plist: result.stdout)
    }

    static func lockedVolume(named name: String, plist: Data) throws -> LockedVolume? {
        let root = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        let containers = root?["Containers"] as? [[String: Any]] ?? []
        for container in containers {
            for volume in container["Volumes"] as? [[String: Any]] ?? [] {
                guard volume["Name"] as? String == name, volume["Locked"] as? Bool == true,
                    let device = volume["DeviceIdentifier"] as? String
                else { continue }
                return LockedVolume(device: device, name: name, uuid: volume["APFSVolumeUUID"] as? String ?? "")
            }
        }
        return nil
    }

    public static func unlock(_ volume: LockedVolume, runner: ProcessRunner = ProcessRunner()) throws {
        guard let password = try keychain.read() else {
            throw GamesError.unavailable("the SSD password (\(keychain.service) / \(keychain.account)) is not in the keychain")
        }
        let result = try runner.run(
            "/usr/sbin/diskutil",
            ["apfs", "unlockVolume", volume.device, "-stdinpassphrase"],
            input: Data(password.utf8),
            timeout: 60
        )
        guard result.status == 0 else {
            throw GamesError.unavailable("diskutil could not unlock \(volume.name): \(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
