import Foundation
import MacSpacePlatform

/// What macOS counts as purgeable on the Data volume, per CacheDelete service, at the urgency the disk's "purgeable" figure uses (3).
struct PurgeableSnapshot: Sendable, Equatable {
    /// Bytes each service reports; nil when CacheDelete is unavailable or failed its self-test on this macOS build.
    var services: [String: UInt64]?
    var takenAt: Date

    /// What MacSpace frees: the files apps marked purgeable. The other services are listed, not purged (see `PurgeableService`).
    var freeableBytes: UInt64 { services?[CacheDeleteService.fsPurgeableData] ?? 0 }
    var totalBytes: UInt64 { services?.values.reduce(0, +) ?? 0 }
}

/// The services worth naming, and why each is or is not freed. Measured on the development Mac, 2026-10-02 (Docs/Research.md, CacheDelete).
struct PurgeableService: Equatable {
    let id: String
    let title: String
    let detail: String
    /// The row's symbol on the page.
    let symbol: String

    static let known: [PurgeableService] = [
        PurgeableService(id: CacheDeleteService.fsPurgeableData, title: "Purgeable app files",
                         detail: "Caches and downloads apps told macOS it may delete. macOS deletes them only when the disk is nearly full; this does it now. Apps download again what they need.", symbol: "arrow.down.circle.dotted"),
        PurgeableService(id: CacheDeleteService.appContainerCaches, title: "App container caches",
                         detail: "macOS reports them, but purging freed under 100 MB at any urgency, and they keep being reported. Left alone.", symbol: "shippingbox"),
        PurgeableService(id: CacheDeleteService.fsPurgeableDocument, title: "Purgeable documents",
                         detail: "Most likely local copies of documents kept in the cloud. Not offered until it is measured what removing them does.", symbol: "icloud.and.arrow.down"),
        PurgeableService(id: CacheDeleteService.quickLookThumbnails, title: "Quick Look thumbnails",
                         detail: "Previews of files. macOS reports them, but purging removed nothing. Left alone.", symbol: "photo.on.rectangle"),
        PurgeableService(id: CacheDeleteService.mobileAsset, title: "System assets",
                         detail: "Assets macOS downloaded. The unused ones are removed from System Data.", symbol: "square.stack.3d.down.right"),
    ]

    static func describe(_ id: String) -> PurgeableService {
        known.first { $0.id == id } ?? PurgeableService(id: id, title: id, detail: "Reported by macOS. MacSpace leaves it alone.", symbol: "internaldrive")
    }
}

actor PurgeableStore {
    private var cached: PurgeableSnapshot?

    func snapshot(maxAge: TimeInterval = 60) async -> PurgeableSnapshot {
        if let cached, Date().timeIntervalSince(cached.takenAt) < maxAge { return cached }
        let fresh = await Task.detached(priority: .utility) { Self.liveSnapshot() }.value
        cached = fresh
        return fresh
    }

    func invalidate() { cached = nil }

    /// Asked in the CLI child process, so a changed private interface crashes it and not the app. Each macOS build is self-tested
    /// once before CacheDelete is trusted.
    static func liveSnapshot() -> PurgeableSnapshot {
        let client = CacheDeleteClient()
        let urgency = CacheDeleteService.fsPurgeableDataUrgency
        var services: [String: UInt64]?
        if let cli = ToolLocator.cli() {
            client.ensureValidated(executable: cli)
            if client.support == .validated { services = CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli, urgency: urgency) }
        } else if client.support == .validated {
            services = client.purgeableByService(urgency: urgency)
        }
        return PurgeableSnapshot(services: services, takenAt: Date())
    }
}
