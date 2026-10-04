import Foundation
import MacSpacePlatform

/// The startup disk at a glance, for the first tile: how much is used, and the purgeable files the Other System Files module frees.
///
/// "Purgeable" here is CacheDelete's fspurgeable_data at urgency 3: files apps marked purgeable. It is not macOS's own purgeable
/// estimate (available for important use minus free), which also counts app container caches and Quick Look thumbnails; purging
/// those freed next to nothing (Docs/Research.md, CacheDelete).
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

    var status: (title: String, detail: String) {
        guard let usedBytes else { return ("disk", "reading…") }
        let used = "\(ByteFormat.string(usedBytes)) used"
        if let purgeableBytes, purgeableBytes >= 50_000_000 { return (used, "\(ByteFormat.string(purgeableBytes)) purgeable") }
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
            return (used, total, Self.purgeableFiles())
        }.value
        usedBytes = reading.0
        totalBytes = reading.1
        purgeableBytes = reading.2
    }

    /// The purgeable files, asked in the CLI child process (a changed private interface crashes it, not the app). nil when
    /// CacheDelete is unavailable or does not answer.
    nonisolated static func purgeableFiles() -> UInt64? {
        let service = CacheDeleteService.fsPurgeableData, urgency = CacheDeleteService.fsPurgeableDataUrgency
        if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli, urgency: urgency)?[service] }
        return CacheDeleteClient().purgeableByService(urgency: urgency)?[service]
    }
}
