import Foundation

public enum DataVolume {
    public static let path = "/System/Volumes/Data"

    /// Free bytes on the Data volume: the one trustworthy number for what a cleanup freed (APFS clones make `du` overstate).
    public static func freeBytes() -> UInt64? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        return UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
    }

    /// Free bytes once a deletion has settled. APFS hands freed blocks back a moment after the files go, so a reading taken right after
    /// a purge can miss what it freed: read again until two readings agree (or `limit` seconds pass) and keep the highest.
    public static func settledFreeBytes(limit: TimeInterval = 3, interval: TimeInterval = 0.5,
                                        read: () -> UInt64? = DataVolume.freeBytes) -> UInt64? {
        var best = read()
        var previous = best
        var waited: TimeInterval = 0
        while waited < limit {
            Thread.sleep(forTimeInterval: interval)
            waited += interval
            let next = read()
            if let next { best = max(best ?? 0, next) }
            if next == previous { break }
            previous = next
        }
        return best
    }

    /// Space macOS can reclaim by itself when needed (available for important use minus free), or nil if unreadable.
    public static func purgeableEstimate() -> UInt64? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacity, let important = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return important > Int64(free) ? UInt64(important - Int64(free)) : 0
    }
}
