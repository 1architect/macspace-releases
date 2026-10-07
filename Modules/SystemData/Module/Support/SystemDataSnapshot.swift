import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged

/// Everything the System Data screens are built from, measured once and shared by the dashboard tile and the page.
struct SystemDataSnapshot: Sendable {
    var report: SystemDataReport
    /// Bytes mobileassetd would delete under disk pressure; nil when CacheDelete is unavailable or not validated.
    var purgeableAssetsBytes: UInt64?
    /// What every CacheDelete service says it may purge, by service; empty when CacheDelete did not answer.
    var purgeableServices: [String: UInt64] = [:]
    var reports: CleanupPlan
    /// What fills the system assets, grouped by the setting that releases it.
    var assetFamilies: [AssetFamily] = []
    var takenAt: Date
    /// macOS kept the unused assets when asked; MacSpace is asking it again in the background (`PurgeRetrier`).
    var assetsRetrying = false
    /// The helper was asked to measure the places only root can read.
    var helperTried = false
    /// Why the helper could not measure (it was not reachable), when that is the reason.
    var helperError: String?
    /// The disk as System Settings divides it; System Data's total is its remainder. nil when it could not be read.
    var settings: SettingsStorage?
}

/// Measures the root-only locations through the helper and folds the sizes into the report.
enum RootMeasurements {
    static func apply(to snapshot: SystemDataSnapshot, channel: any PrivilegedChannel) async -> SystemDataSnapshot {
        let wanted = snapshot.report.unreadable.filter(RootMeasuredLocations.isAllowed)
        var result = snapshot
        result.helperTried = true
        guard !wanted.isEmpty else { return result }
        do {
            let data = try await channel.perform(operation: SystemDataPrivilegedOperations.measure, arguments: ["paths": wanted.joined(separator: "\n")])
            let response = try JSONDecoder().decode(RootMeasurementResponse.self, from: data)
            return response.sizes.isEmpty ? result : merge(response.sizes, purgeable: response.purgeable ?? [:], into: result)
        } catch {
            result.helperError = error.localizedDescription
            return result
        }
    }

    static func merge(_ sizes: [String: UInt64], purgeable: [String: UInt64] = [:], into snapshot: SystemDataSnapshot) -> SystemDataSnapshot {
        var result = snapshot
        var report = snapshot.report
        // The folders of each item this process could not read, measured by the helper, are added to what it did read: one item can
        // span folders of both kinds (the system databases).
        let unread = Set(report.unreadable)
        for index in report.items.indices {
            let paths = report.items[index].paths.filter { unread.contains($0) && sizes[$0] != nil }
            guard !paths.isEmpty else { continue }
            report.items[index].bytes = (report.items[index].bytes ?? 0) + paths.compactMap { sizes[$0] }.reduce(0, +)
            report.items[index].purgeableBytes = (report.items[index].purgeableBytes ?? 0) + paths.compactMap { purgeable[$0] }.reduce(0, +)
            report.items[index].readable = true
        }
        report.unreadable = report.unreadable.filter { sizes[$0] == nil }
        report.warnings = report.unreadable.isEmpty ? [] : report.warnings
        report.measuredBytes = report.items.compactMap(\.bytes).reduce(0, +)
        result.report = report
        return result
    }
}

/// Builds snapshots off the main thread and lets concurrent callers share one scan.
actor SystemDataStore {
    typealias Builder = @Sendable () -> SystemDataSnapshot

    private var cached: SystemDataSnapshot?
    private var inflight: Task<SystemDataSnapshot, Never>?
    private let builder: Builder
    /// Bumped by `invalidate`: a scan that started before it (before an action) is not kept or handed out after it, or the page
    /// came back with the figures from before the action.
    private var generation = 0

    init(builder: @escaping Builder = SystemDataStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 120, now: Date = Date(), privileged: (any PrivilegedChannel)? = nil) async -> SystemDataSnapshot {
        if let cached, now.timeIntervalSince(cached.takenAt) < maxAge, cached.helperTried || privileged == nil { return cached }
        // A caller that waited on a scan an `invalidate` made obsolete (an action finished meanwhile) asks again instead of taking
        // the figures from before the action.
        if let inflight {
            let waitedFor = generation
            let fresh = await inflight.value
            return waitedFor == generation ? fresh : await snapshot(maxAge: maxAge, privileged: privileged)
        }
        let builder = self.builder
        let task = Task.detached(priority: .utility) { () -> SystemDataSnapshot in
            let scanned = builder()
            guard let privileged else { return scanned }
            return await RootMeasurements.apply(to: scanned, channel: privileged)
        }
        let started = generation
        inflight = task
        let fresh = await task.value
        guard started == generation else { return await snapshot(maxAge: maxAge, privileged: privileged) }
        cached = fresh
        inflight = nil
        return fresh
    }

    func invalidate() {
        cached = nil
        inflight = nil
        generation += 1
    }

    static func liveSnapshot() -> SystemDataSnapshot {
        let report = SystemDataInspector().inspect()
        let services = livePurgeableServices()
        let purgeable = services[CacheDeleteService.mobileAsset].map { PurgeHoldouts.shared.freeable(CacheDeleteService.mobileAsset, estimate: $0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let reports = DiagnosticReportCleaner(directories: ["/Library/Logs/DiagnosticReports", home + "/Library/Logs/DiagnosticReports"])
            .plan(olderThanDays: DiagnosticReportCleaner.defaultOlderThanDays)
        var snapshot = SystemDataSnapshot(report: report, purgeableAssetsBytes: purgeable, reports: reports, assetFamilies: AssetFamilyScanner().scan(), takenAt: Date(),
                                          assetsRetrying: PurgeRetrier.shared.isRetrying(CacheDeleteService.mobileAsset))
        snapshot.purgeableServices = services
        snapshot.settings = SettingsStorageMeter().measure()
        // Development (MACSPACE_DEBUG=1): the items as measured, for comparing them with System Settings' figure.
        if ProcessInfo.processInfo.environment["MACSPACE_DEBUG"] == "1", let data = try? JSONEncoder().encode(report) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("macspace-systemdata-report.json"))
        }
        return snapshot
    }

    /// Every CacheDelete service's figure, asked in the CLI child process; empty when CacheDelete did not answer.
    static func livePurgeableServices() -> [String: UInt64] {
        if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli) ?? [:] }
        return CacheDeleteClient().purgeableByService() ?? [:]
    }

    /// How much is purgeable, asked in the CLI child process. Only mobileassetd's figure is used: the app-container-caches service
    /// also reports a figure (1.15 GB on 26B5091g), but purging it removed under 100 MB at any urgency, so it is not offered.
    static func livePurgeable() -> UInt64? {
        let all: [String: UInt64]?
        if let cli = ToolLocator.cli() { all = CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli) }
        else { all = CacheDeleteClient().purgeableByService() }
        // Without what macOS estimates but would not delete when asked (`PurgeHoldouts`).
        return all?[CacheDeleteService.mobileAsset].map { PurgeHoldouts.shared.freeable(CacheDeleteService.mobileAsset, estimate: $0) }
    }
}
