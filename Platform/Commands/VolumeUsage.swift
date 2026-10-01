import Foundation

/// One APFS volume's consumption, from `diskutil apfs list`.
public struct VolumeUsage: Codable, Equatable, Sendable {
    public let name: String
    public let roles: [String]
    public let usedBytes: UInt64?

    public init(name: String, roles: [String], usedBytes: UInt64?) {
        self.name = name
        self.roles = roles
        self.usedBytes = usedBytes
    }
}

public enum VolumeUsageReader {
    /// Reads every APFS volume. Empty when `diskutil` cannot be run.
    public static func live(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 30)) -> [VolumeUsage] {
        guard let result = try? runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]) else { return [] }
        return parse(result.stdout)
    }

    public static func parse(_ data: Data) -> [VolumeUsage] {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return [] }
        return containers.flatMap { container -> [VolumeUsage] in
            (container["Volumes"] as? [[String: Any]] ?? []).map { volume in
                VolumeUsage(name: volume["Name"] as? String ?? "?", roles: volume["Roles"] as? [String] ?? [],
                            usedBytes: (volume["CapacityInUse"] as? NSNumber)?.uint64Value)
            }
        }
    }
}
