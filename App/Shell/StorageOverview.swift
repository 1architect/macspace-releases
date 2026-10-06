import Foundation
import MacSpacePlatform

/// The startup disk at a glance, for the first tile: how much is used, out of how much. What can be freed is on the modules' tiles.
@MainActor
final class StorageOverview: ObservableObject {
    @Published private(set) var usedBytes: UInt64?
    @Published private(set) var totalBytes: UInt64?

    var isLoaded: Bool { usedBytes != nil }

    /// How much of the disk is used, 0...1.
    var usedFraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    func status() -> (title: String, detail: String) {
        guard let usedBytes else { return ("disk", "reading…") }
        let percent = usedFraction.map { "\(Int(($0 * 100).rounded()))% " } ?? ""
        return ("\(ByteFormat.string(usedBytes)) used", totalBytes.map { "\(percent)of \(ByteFormat.string($0))" } ?? "")
    }

    func refresh() async {
        let reading = await Task.detached(priority: .utility) { () -> (UInt64?, UInt64?) in
            // Space macOS frees by itself when it is needed (purgeable) counts as available, as System Settings counts it: with the
            // plain free space the tile said 230.9 GB used where System Settings said 203.3 GB (2026-10-06).
            let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            guard let capacity = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage,
                  available >= 0, Int64(capacity) >= available else { return (nil, nil) }
            return (UInt64(Int64(capacity) - available), UInt64(capacity))
        }.value
        usedBytes = reading.0
        totalBytes = reading.1
    }
}
