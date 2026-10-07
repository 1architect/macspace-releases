import AppKit
import Combine
import Foundation
import MacSpacePlatform

/// The startup disk at a glance, for the first tile: how much is used, out of how much. What can be freed is on the modules' tiles.
@MainActor
final class StorageOverview: ObservableObject {
    /// One reading for every window and the menu bar, so a cleanup run from one shows in all of them.
    static let shared = StorageOverview()

    @Published private(set) var usedBytes: UInt64?
    @Published private(set) var totalBytes: UInt64?

    var isLoaded: Bool { usedBytes != nil }

    /// How much of the disk is used, 0...1.
    var usedFraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    func status() -> (title: String, detail: String) {
        guard let usedBytes else { return (String(localized: "disk"), String(localized: "reading…")) }
        let detail: String = totalBytes.map { total in
            let size = ByteFormat.string(total)
            guard let fraction = usedFraction else { return String(localized: "of \(size)") }
            return String(localized: "\(Int((fraction * 100).rounded()))% of \(size)")
        } ?? ""
        return (String(localized: "\(ByteFormat.string(usedBytes)) used"), detail)
    }

    private var observers: [AnyCancellable] = []
    private var followUps: Task<Void, Never>?
    private var lastRead: Date?

    /// Reads the disk again whenever something may have changed it: a cleanup ending (a module's action or automatic cleanup), a
    /// module's figures changing (after its own reading, a background task, or space freed outside MacSpace), and coming back to the
    /// app. macOS deletes purgeable files after it has answered, so a cleanup is followed by two later readings.
    func follow(_ host: ModuleHost) {
        guard observers.isEmpty else { return }
        observers.append(host.$isCleaning.removeDuplicates().dropFirst().filter { !$0 }.sink { [weak self] _ in
            self?.readSoon(after: [0, 5, 20])
        })
        observers.append(host.$reclaimable.dropFirst().debounce(for: .seconds(1), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.readSoon(after: [0])
        })
        observers.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.readSoon(after: [0])
        })
    }

    /// Reads now and after each delay, in seconds; a later call replaces the readings still to come.
    private func readSoon(after delays: [Double]) {
        followUps?.cancel()
        followUps = Task { [weak self] in
            var waited = 0.0
            for delay in delays.sorted() {
                try? await Task.sleep(for: .seconds(delay - waited))
                waited = delay
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    /// While a window shows the disk: reads it every `interval` seconds, so space freed or taken by anything shows within it.
    /// Ends when the calling view goes away (its task is cancelled).
    func watch(every interval: Double = 30) async {
        while !Task.isCancelled {
            if lastRead.map({ Date().timeIntervalSince($0) >= interval / 2 }) ?? true { await refresh() }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    func refresh() async {
        lastRead = Date()
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
