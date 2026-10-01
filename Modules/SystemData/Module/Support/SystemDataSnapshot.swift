import Foundation
import MacSpacePlatform

/// Everything the System Data screens are built from, measured once and shared by the dashboard tile and the page.
struct SystemDataSnapshot: Sendable {
    var report: SystemDataReport
    /// Bytes mobileassetd would delete under disk pressure; nil when CacheDelete is unavailable or not validated.
    var purgeableAssetsBytes: UInt64?
    var reports: CleanupPlan
    /// What fills the system assets, grouped by the setting that releases it.
    var assetFamilies: [AssetFamily] = []
    var takenAt: Date
}

/// Builds snapshots off the main thread and lets concurrent callers share one scan.
actor SystemDataStore {
    typealias Builder = @Sendable () -> SystemDataSnapshot

    private var cached: SystemDataSnapshot?
    private var inflight: Task<SystemDataSnapshot, Never>?
    private let builder: Builder

    init(builder: @escaping Builder = SystemDataStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 120, now: Date = Date()) async -> SystemDataSnapshot {
        if let cached, now.timeIntervalSince(cached.takenAt) < maxAge { return cached }
        if let inflight { return await inflight.value }
        let builder = self.builder
        let task = Task.detached(priority: .utility) { builder() }
        inflight = task
        let fresh = await task.value
        cached = fresh
        inflight = nil
        return fresh
    }

    func invalidate() { cached = nil }

    static func liveSnapshot() -> SystemDataSnapshot {
        let report = SystemDataInspector().inspect()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let reports = DiagnosticReportCleaner(directories: ["/Library/Logs/DiagnosticReports", home + "/Library/Logs/DiagnosticReports"])
            .plan(olderThanDays: DiagnosticReportCleaner.defaultOlderThanDays)
        return SystemDataSnapshot(report: report, purgeableAssetsBytes: livePurgeableAssets(), reports: reports, assetFamilies: AssetFamilyScanner().scan(), takenAt: Date())
    }

    /// Tests CacheDelete on this macOS build the first time (in the CLI child process), then asks how much is purgeable.
    static func livePurgeableAssets() -> UInt64? {
        let client = CacheDeleteClient()
        if let cli = ToolLocator.cli() {
            client.ensureValidated(executable: cli)
            guard client.support == .validated else { return nil }
            return CacheDeleteClient.purgeableInSubprocess(executable: cli)
        }
        // Without the bundled tool (a development run) only builds checked by hand are queried in this process.
        return client.support == .validated ? client.purgeableByService()?[CacheDeleteService.mobileAsset] : nil
    }
}
