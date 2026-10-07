import Foundation
import MacSpacePlatform

/// What macOS counts as purgeable on the Data volume, per CacheDelete service, at the urgency the disk's "purgeable" figure uses (3).
struct PurgeableSnapshot: Sendable, Equatable {
    /// Bytes each service reports; nil when CacheDelete is unavailable or did not answer.
    var services: [String: UInt64]?
    var takenAt: Date
    /// macOS kept the files apps marked purgeable when MacSpace asked, and MacSpace is asking it again in the background
    /// (`PurgeRetrier`). They still count as freeable.
    var retrying = false
    /// The cloud folders holding the purgeable documents (`PurgeableDocuments`); empty when there are none or they were not looked for.
    var documents: [PurgeableDocuments.Source] = []
    /// macOS updates downloaded and prepared, waiting for a restart (`PreparedUpdate`): System Settings counts them under macOS, so
    /// they are other system files, not System Data.
    var updates: [PreparedUpdate] = []
    /// Removals of cloud downloads running now, by cloud folder (`CloudDownloadRemovals`).
    var removing: [String: CloudDownloadRemovals.Progress] = [:]

    /// macOS's estimate of the files apps marked purgeable.
    var estimatedBytes: UInt64 { services?[CacheDeleteService.fsPurgeableData] ?? 0 }

    /// What MacSpace frees: the files apps marked purgeable. The other services are listed, not purged (see `PurgeableService`).
    var freeableBytes: UInt64 { estimatedBytes }
    /// What macOS counts as purgeable.
    var totalBytes: UInt64 { services?.values.reduce(0, +) ?? 0 }
    var updateBytes: UInt64 { updates.map(\.bytes).reduce(0, +) }
}

/// The services worth naming, and why each is or is not freed. Measured on the development Mac, 2026-10-02 (Docs/Research.md, CacheDelete).
struct PurgeableService: Equatable {
    let id: String
    let title: String
    let detail: String
    /// The row's symbol on the page.
    let symbol: String

    static let known: [PurgeableService] = [
        PurgeableService(id: CacheDeleteService.fsPurgeableData, title: loc("Purgeable app files"),
                         detail: loc("Files apps marked as safe to delete. macOS only deletes them when the disk is nearly full."), symbol: "arrow.down.circle.dotted"),
        PurgeableService(id: CacheDeleteService.appContainerCaches, title: loc("App container caches"),
                         detail: "", symbol: "shippingbox"),
        PurgeableService(id: CacheDeleteService.fsPurgeableDocument, title: loc("Purgeable documents"),
                         detail: "", symbol: "icloud.and.arrow.down"),
        PurgeableService(id: CacheDeleteService.spotlightIndex, title: loc("Spotlight index"),
                         detail: "", symbol: "magnifyingglass"),
        PurgeableService(id: CacheDeleteService.quickLookThumbnails, title: loc("Quick Look thumbnails"),
                         detail: "", symbol: "photo.on.rectangle"),
        PurgeableService(id: CacheDeleteService.mobileAsset, title: loc("System assets"),
                         detail: "", symbol: "square.stack.3d.down.right"),
    ]

    static func describe(_ id: String) -> PurgeableService {
        known.first { $0.id == id } ?? PurgeableService(id: id, title: readableName(id), detail: "", symbol: "internaldrive")
    }

    /// A service macOS reports that MacSpace does not know, named from its identifier ("com.apple.geod.cachedelete" -> "geod cache"),
    /// so any service on any Mac reads as words.
    static func readableName(_ id: String) -> String {
        var name = id.hasPrefix("com.apple.") ? String(id.dropFirst("com.apple.".count)) : id
        for suffix in [".cachedelete", ".cache-delete", ".CacheDelete", ".cacheDelete", "-cache-delete", ".CacheDeleteExtension", ".cache-delete_fspurgeable"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return loc("\(name.replacingOccurrences(of: ".", with: " ")) cache")
    }
}

actor PurgeableStore {
    private var cached: PurgeableSnapshot?
    /// Where an earlier version kept what macOS declined; nothing is hidden any more, so it is only removed.
    static let legacyDeclinedKeys = ["otherSystemFiles.declinedEstimate", "purge.declined.\(CacheDeleteService.fsPurgeableData)",
                                     "purge.declined.\(CacheDeleteService.mobileAsset)"]

    init() {
        for key in Self.legacyDeclinedKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// What MacSpace last freed, and macOS's estimate when it did.
    private var removed: (estimate: UInt64, bytes: UInt64)?
    /// macOS's own estimate in the last snapshot, before what was freed is taken off it.
    private var rawEstimate: UInt64 = 0
    /// One query at a time: the tile and the page asked together and started two CLI processes.
    private var inflight: Task<PurgeableSnapshot, Never>?
    /// Bumped by `invalidate`: a scan that started before it (before an action) is not kept or handed out after it, or the page
    /// came back with the figures from before the action.
    private var generation = 0

    func snapshot(maxAge: TimeInterval = 60) async -> PurgeableSnapshot {
        if let cached, Date().timeIntervalSince(cached.takenAt) < maxAge { return cached }
        let started = generation
        if let inflight {
            let raw = await inflight.value
            return started == generation ? settle(raw) : await snapshot(maxAge: maxAge)
        }
        let task = Task.detached(priority: .utility) { Self.liveSnapshot() }
        inflight = task
        let raw = await task.value
        guard started == generation else { return await snapshot(maxAge: maxAge) }
        inflight = nil
        return settle(raw)
    }

    /// macOS's answer with what MacSpace knows on top: what macOS kept, and what was just freed. The same for every caller that
    /// waited on one query (applying it twice to the same answer gives the same result).
    private func settle(_ raw: PurgeableSnapshot) -> PurgeableSnapshot {
        var fresh = raw
        fresh.retrying = PurgeRetrier.shared.isRetrying(CacheDeleteService.fsPurgeableData)
        rawEstimate = fresh.services?[CacheDeleteService.fsPurgeableData] ?? 0
        fresh.services = Self.accounting(for: &removed, in: fresh.services)
        // Without what macOS estimates but would not delete when asked (`PurgeHoldouts`).
        if let estimate = fresh.services?[CacheDeleteService.fsPurgeableData] {
            fresh.services?[CacheDeleteService.fsPurgeableData] = PurgeHoldouts.shared.freeable(CacheDeleteService.fsPurgeableData, estimate: estimate)
        }
        cached = fresh
        return fresh
    }

    /// macOS's estimate lags behind what it removed: right after freeing 1 GB it could still give the figure from before. While it
    /// gives that same figure, what was freed is taken off it; once the figure moves, macOS has measured again and is believed.
    static func accounting(for removed: inout (estimate: UInt64, bytes: UInt64)?, in services: [String: UInt64]?) -> [String: UInt64]? {
        guard var services, let freed = removed, let current = services[CacheDeleteService.fsPurgeableData] else { return services }
        let tolerance = max(freed.estimate / 50, 5_000_000)
        guard current + tolerance >= freed.estimate, current <= freed.estimate + tolerance else {
            removed = nil
            return services
        }
        services[CacheDeleteService.fsPurgeableData] = current > freed.bytes ? current - freed.bytes : 0
        return services
    }

    /// macOS's own estimate of the files apps marked purgeable, as it gave it last.
    func currentRawEstimate() async -> UInt64 {
        _ = await snapshot()
        return rawEstimate
    }

    /// MacSpace freed `bytes` while macOS estimated `estimate`.
    func noteRemoved(_ bytes: UInt64, estimate: UInt64) { removed = (estimate, bytes) }

    func invalidate() {
        cached = nil
        inflight = nil
        generation += 1
    }

    /// Asked in the CLI child process, so a changed private interface crashes it and not the app.
    static func liveSnapshot() -> PurgeableSnapshot {
        let urgency = CacheDeleteService.fsPurgeableDataUrgency
        let services: [String: UInt64]?
        if let cli = ToolLocator.cli() { services = CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli, urgency: urgency) }
        else { services = CacheDeleteClient().purgeableByService(urgency: urgency) }
        // Where the purgeable documents are, only when macOS counts some: a few seconds for a large cloud folder.
        let documents = (services?[CacheDeleteService.fsPurgeableDocument] ?? 0) >= 50_000_000 ? PurgeableDocuments.scan(maxAge: 600) : []
        return PurgeableSnapshot(services: services, takenAt: Date(), documents: documents, updates: PreparedUpdate.find())
    }
}
