import Foundation

public enum DataVolume {
    public static let path = "/System/Volumes/Data"

    /// Free bytes on the Data volume: the one trustworthy number for what a cleanup freed (APFS clones make `du` overstate).
    public static func freeBytes() -> UInt64? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        return UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
    }

    /// Space macOS can reclaim by itself when needed (available for important use minus free), or nil if unreadable.
    public static func purgeableEstimate() -> UInt64? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacity, let important = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return important > Int64(free) ? UInt64(important - Int64(free)) : 0
    }
}
