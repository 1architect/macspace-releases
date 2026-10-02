import Foundation
import MacSpacePlatform

/// The startup disk at a glance, for the first tile: how much is used and how much macOS could reclaim by itself.
@MainActor
final class StorageOverview: ObservableObject {
    @Published private(set) var usedBytes: UInt64?
    @Published private(set) var totalBytes: UInt64?
    @Published private(set) var purgeableBytes: UInt64?

    var isLoaded: Bool { usedBytes != nil }

    /// How much of the disk is used, 0...1.
    var usedFraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// What macOS could purge by itself, as a share of the disk.
    var purgeableFraction: Double? {
        guard let purgeableBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(purgeableBytes) / Double(totalBytes)
    }

    var status: (title: String, detail: String) {
        guard let usedBytes else { return ("disk", "reading…") }
        let used = "\(ByteFormat.string(usedBytes)) used"
        if let purgeableBytes, purgeableBytes >= 100_000_000 { return (used, "\(ByteFormat.string(purgeableBytes)) purgeable") }
        if let totalBytes, totalBytes > usedBytes { return (used, "\(ByteFormat.string(totalBytes - usedBytes)) free") }
        return (used, "")
    }

    func refresh() async {
        let reading = await Task.detached(priority: .utility) { () -> (UInt64?, UInt64?, UInt64?) in
            let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            var used: UInt64?
            var total: UInt64?
            if let capacity = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity, capacity >= free {
                used = UInt64(capacity - free)
                total = UInt64(capacity)
            }
            return (used, total, DataVolume.purgeableEstimate())
        }.value
        usedBytes = reading.0
        totalBytes = reading.1
        purgeableBytes = reading.2
    }
}
