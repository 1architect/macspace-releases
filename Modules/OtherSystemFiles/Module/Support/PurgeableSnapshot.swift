import Foundation
import MacSpaceOtherSystemFilesPrivileged
import MacSpacePlatform
import MacSpaceSdk

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
    /// Time Machine: the local snapshots, whose space is macOS's purge figure for them, and the backup disks.
    var timeMachine = TimeMachineState()

    /// macOS's estimate of the files apps marked purgeable.
    var estimatedBytes: UInt64 { services?[CacheDeleteService.fsPurgeableData] ?? 0 }

    /// What MacSpace frees: the files apps marked purgeable. The other services are listed, not purged (see `PurgeableService`).
    var freeableBytes: UInt64 { estimatedBytes }
    /// What macOS counts as purgeable.
    var totalBytes: UInt64 { services?.values.reduce(0, +) ?? 0 }
    var updateBytes: UInt64 { updates.map(\.bytes).reduce(0, +) }
}

/// What Time Machine keeps: local snapshots on this Mac, and backups on its backup disks.
struct TimeMachineState: Sendable, Equatable {
    /// nil when `tmutil` could not be asked.
    var snapshots: TimeMachine.LocalSnapshots?
    var disks: [BackupDisk] = []
    /// A backup is running; nil when unknown. Nothing is freed then.
    var backingUp: Bool?

    struct BackupDisk: Sendable, Equatable {
        var destination: TimeMachine.Destination
        /// Oldest first; nil when the disk is not connected or its backups could not be read.
        var backups: [TimeMachine.Backup]?
        var totalBytes: UInt64?
        var freeBytes: UInt64?

        /// What the disk holds: its size less its free space.
        var usedBytes: UInt64? {
            guard let total = totalBytes, let free = freeBytes else { return nil }
            return total > free ? total - free : 0
        }
    }

    static func live(progress: LoadProgressSink = { _ in }) -> TimeMachineState {
        var state = TimeMachineState(snapshots: TimeMachine.localSnapshots())
        progress(0.25)
        let destinations = TimeMachine.destinations() ?? []
        progress(0.5)
        state.disks = destinations.enumerated().map { index, destination in
            defer { progress(0.5 + 0.4 * Double(index + 1) / Double(destinations.count)) }
            guard let mount = destination.mountPoint else { return BackupDisk(destination: destination) }
            let capacity = TimeMachine.capacity(of: mount)
            return BackupDisk(destination: destination, backups: TimeMachine.backups(at: mount), totalBytes: capacity?.total, freeBytes: capacity?.free)
        }
        state.backingUp = TimeMachine.isBackingUp()
        progress(1)
        return state
    }
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
        // One figure, no folders: the caches of third-party apps' containers are listed and freed on System Data's caches page
        // (`CachesPage`), and an item is listed on one page only. Apple's are macOS's.
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
        PurgeableService(id: CacheDeleteService.timeMachineSnapshots, title: loc("Time Machine snapshots"),
                         detail: "", symbol: "clock.arrow.circlepath"),
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
    typealias Builder = @Sendable (LoadProgressRelay) async -> PurgeableSnapshot
    private var cached: PurgeableSnapshot?
    private let builder: Builder
    private var relay: LoadProgressRelay?
    /// Where an earlier version kept what macOS declined; nothing is hidden any more, so it is only removed.
    static let legacyDeclinedKeys = ["otherSystemFiles.declinedEstimate", "purge.declined.\(CacheDeleteService.fsPurgeableData)",
                                     "purge.declined.\(CacheDeleteService.mobileAsset)"]

    init(builder: @escaping Builder = PurgeableStore.liveSnapshot) {
        self.builder = builder
        for key in Self.legacyDeclinedKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// What MacSpace last freed, and macOS's estimate when it did.
    private var removed: (estimate: UInt64, bytes: UInt64)?
    /// The same for Time Machine's snapshots: macOS's figure for them stayed at 971.4 MB for more than two minutes after 635 MB of
    /// them were deleted (26B5101f, 2026-10-13).
    private var snapshotsRemoved: (estimate: UInt64, bytes: UInt64)?
    private var rawSnapshotsEstimate: UInt64 = 0
    /// macOS's own estimate in the last snapshot, before what was freed is taken off it.
    private var rawEstimate: UInt64 = 0
    /// One query at a time: the tile and the page asked together and started two CLI processes.
    private var inflight: Task<PurgeableSnapshot, Never>?
    /// Bumped by `invalidate`: a scan that started before it (before an action) is not kept or handed out after it, or the page
    /// came back with the figures from before the action.
    private var generation = 0
    private var followingRemovals = false

    func beginRemoval() { followingRemovals = true }

    /// Keep the measured data during removal, even past its TTL; only live counters change. Completion forces one fresh reading.
    func status(removing: [String: CloudDownloadRemovals.Progress]) -> PurgeableSnapshot? {
        guard !removing.isEmpty else {
            if followingRemovals {
                followingRemovals = false
                PurgeableDocuments.forget()
                invalidate()
            }
            return nil
        }
        guard var snapshot = cached else { return nil }
        snapshot.removing = follow(removing)
        return snapshot
    }

    func follow(_ removing: [String: CloudDownloadRemovals.Progress]) -> [String: CloudDownloadRemovals.Progress] {
        followingRemovals = !removing.isEmpty
        return removing
    }

    func snapshot(maxAge: TimeInterval = 60, progress: LoadProgressSink? = nil) async -> PurgeableSnapshot {
        if let cached, Date().timeIntervalSince(cached.takenAt) < maxAge { return cached }
        let started = generation
        if let inflight {
            if let progress { relay?.attach(progress) }
            let raw = await inflight.value
            return started == generation ? settle(raw) : await snapshot(maxAge: maxAge, progress: progress)
        }
        let relay = LoadProgressRelay()
        if let progress { relay.attach(progress) }
        relay.report(0)
        let builder = self.builder
        let task = Task.detached(priority: .utility) {
            defer { relay.report(1) }
            return await builder(relay)
        }
        inflight = task
        self.relay = relay
        let raw = await task.value
        guard started == generation else { return await snapshot(maxAge: maxAge, progress: progress) }
        inflight = nil
        self.relay = nil
        return settle(raw)
    }

    /// macOS's answer with what MacSpace knows on top: what macOS kept, and what was just freed. The same for every caller that
    /// waited on one query (applying it twice to the same answer gives the same result).
    private func settle(_ raw: PurgeableSnapshot) -> PurgeableSnapshot {
        var fresh = raw
        fresh.retrying = PurgeRetrier.shared.isRetrying(CacheDeleteService.fsPurgeableData)
        rawEstimate = fresh.services?[CacheDeleteService.fsPurgeableData] ?? 0
        rawSnapshotsEstimate = fresh.services?[CacheDeleteService.timeMachineSnapshots] ?? 0
        fresh.services = Self.accounting(for: &removed, in: fresh.services)
        fresh.services = Self.accounting(for: &snapshotsRemoved, in: fresh.services, service: CacheDeleteService.timeMachineSnapshots)
        // Without what macOS estimates but would not delete when asked (`PurgeHoldouts`).
        if let estimate = fresh.services?[CacheDeleteService.fsPurgeableData] {
            fresh.services?[CacheDeleteService.fsPurgeableData] = PurgeHoldouts.shared.freeable(CacheDeleteService.fsPurgeableData, estimate: estimate)
        }
        cached = fresh
        return fresh
    }

    /// macOS's estimate lags behind what it removed: right after freeing 1 GB it could still give the figure from before. While it
    /// gives that same figure, what was freed is taken off it; once the figure moves, macOS has measured again and is believed.
    static func accounting(for removed: inout (estimate: UInt64, bytes: UInt64)?, in services: [String: UInt64]?,
                           service: String = CacheDeleteService.fsPurgeableData) -> [String: UInt64]? {
        guard var services, let freed = removed, let current = services[service] else { return services }
        let tolerance = max(freed.estimate / 50, 5_000_000)
        guard current + tolerance >= freed.estimate, current <= freed.estimate + tolerance else {
            removed = nil
            return services
        }
        services[service] = current > freed.bytes ? current - freed.bytes : 0
        return services
    }

    /// macOS's own estimate of the files apps marked purgeable, as it gave it last.
    func currentRawEstimate() async -> UInt64 {
        _ = await snapshot()
        return rawEstimate
    }

    /// MacSpace freed `bytes` while macOS estimated `estimate`.
    func noteRemoved(_ bytes: UInt64, estimate: UInt64) { removed = (estimate, bytes) }

    /// macOS's own figure for Time Machine's snapshots, as it gave it last.
    func currentRawSnapshotsEstimate() async -> UInt64 {
        _ = await snapshot()
        return rawSnapshotsEstimate
    }

    /// MacSpace freed `bytes` of Time Machine's snapshots while macOS's figure for them was `estimate`.
    func noteSnapshotsRemoved(_ bytes: UInt64, estimate: UInt64) { snapshotsRemoved = (estimate, bytes) }

    func invalidate() {
        cached = nil
        inflight = nil
        relay = nil
        generation += 1
    }

    /// Asked in the CLI child process, so a changed private interface crashes it and not the app.
    static func liveSnapshot(progress: LoadProgressRelay) async -> PurgeableSnapshot {
        let parts = progress.parallelParts(weights: [0.2, 0.65, 0.05, 0.1])
        async let services = Task.detached(priority: .utility) {
            defer { parts[0](1) }
            let urgency = CacheDeleteService.fsPurgeableDataUrgency
            if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli, urgency: urgency) }
            return CacheDeleteClient().purgeableByService(urgency: urgency)
        }.value
        // Explicit eviction is independent of APFS's pressure-based purge estimate. File Provider can evict uploaded local
        // copies that have not been marked purgeable, and CacheDelete can report only a small fraction of their allocated sizes.
        async let documents = Task.detached(priority: .utility) { PurgeableDocuments.scan(maxAge: 600, progress: parts[1]) }.value
        async let updates = Task.detached(priority: .utility) {
            defer { parts[2](1) }
            return PreparedUpdate.find()
        }.value
        async let timeMachine = Task.detached(priority: .utility) { TimeMachineState.live(progress: parts[3]) }.value
        let values = await (services, documents, updates, timeMachine)
        var snapshot = PurgeableSnapshot(services: values.0, takenAt: Date(), documents: values.1, updates: values.2)
        snapshot.timeMachine = values.3
        // macOS's figure for the snapshots lags: it stayed at 1.72 GB after both were deleted (26B5101f). With none listed, it is 0.
        if snapshot.timeMachine.snapshots?.all.isEmpty == true, snapshot.services?[CacheDeleteService.timeMachineSnapshots] != nil {
            snapshot.services?[CacheDeleteService.timeMachineSnapshots] = 0
        }
        return snapshot
    }
}
