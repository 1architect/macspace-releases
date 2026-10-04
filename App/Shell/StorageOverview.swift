import Foundation
import MacSpacePlatform

/// The startup disk at a glance, for the first tile: how much is used, and what the app's modules can purge.
///
/// "Purgeable" is not asked of macOS here: it is what the modules report they free through macOS's purge
/// (`Tile.purgeableByService`, summed by `ModuleHost.purgeableTotal`), so the disk tile always says the same as the pages that
/// free it. macOS's own estimate counts services MacSpace does not purge, which made the tile promise space no page offered.
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

    func status(purgeable: UInt64) -> (title: String, detail: String) {
        guard let usedBytes else { return ("disk", "reading…") }
        let used = "\(ByteFormat.string(usedBytes)) used"
        if purgeable >= 50_000_000 { return (used, "\(ByteFormat.string(purgeable)) purgeable") }
        if let totalBytes, totalBytes > usedBytes { return (used, "\(ByteFormat.string(totalBytes - usedBytes)) free") }
        return (used, "")
    }

    func refresh() async {
        let reading = await Task.detached(priority: .utility) { () -> (UInt64?, UInt64?) in
            let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            guard let capacity = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity, capacity >= free else { return (nil, nil) }
            return (UInt64(capacity - free), UInt64(capacity))
        }.value
        usedBytes = reading.0
        totalBytes = reading.1
    }
}
