import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged

/// Everything the System Data screens are built from, measured once and shared by the dashboard tile and the page.
struct SystemDataSnapshot: Sendable {
    var report: SystemDataReport
    /// Bytes mobileassetd would delete under disk pressure; nil when CacheDelete is unavailable or not validated.
    var purgeableAssetsBytes: UInt64?
    var reports: CleanupPlan
    /// What fills the system assets, grouped by the setting that releases it.
    var assetFamilies: [AssetFamily] = []
    var takenAt: Date
    /// The helper was asked to measure the places only root can read.
    var helperTried = false
    /// Why the helper could not measure (it was not reachable), when that is the reason.
    var helperError: String?
}

/// Measures the root-only locations through the helper and folds the sizes into the report.
enum RootMeasurements {
    static func apply(to snapshot: SystemDataSnapshot, channel: any PrivilegedChannel) async -> SystemDataSnapshot {
        let wanted = snapshot.report.unreadable.filter(RootMeasuredLocations.allowed.contains)
        var result = snapshot
        result.helperTried = true
        guard !wanted.isEmpty else { return result }
        do {
            let data = try await channel.perform(operation: SystemDataPrivilegedOperations.measure, arguments: ["paths": wanted.joined(separator: "\n")])
            let response = try JSONDecoder().decode(RootMeasurementResponse.self, from: data)
            return response.sizes.isEmpty ? result : merge(response.sizes, into: result)
        } catch {
            result.helperError = error.localizedDescription
            return result
        }
    }

    static func merge(_ sizes: [String: UInt64], into snapshot: SystemDataSnapshot) -> SystemDataSnapshot {
        var result = snapshot
        var report = snapshot.report
        for index in report.items.indices where report.items[index].bytes == nil {
            let known = report.items[index].paths.compactMap { sizes[$0] }
            guard !known.isEmpty else { continue }
            report.items[index].bytes = known.reduce(0, +)
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

    init(builder: @escaping Builder = SystemDataStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 120, now: Date = Date(), privileged: (any PrivilegedChannel)? = nil) async -> SystemDataSnapshot {
        if let cached, now.timeIntervalSince(cached.takenAt) < maxAge, cached.helperTried || privileged == nil { return cached }
        if let inflight { return await inflight.value }
        let builder = self.builder
        let task = Task.detached(priority: .utility) { () -> SystemDataSnapshot in
            let scanned = builder()
            guard let privileged else { return scanned }
            return await RootMeasurements.apply(to: scanned, channel: privileged)
        }
        inflight = task
        let fresh = await task.value
        cached = fresh
        inflight = nil
        return fresh
    }

    func invalidate() { cached = nil }

    static func liveSnapshot() -> SystemDataSnapshot {
        let report = SystemDataInspector().inspect()
        let purgeable = livePurgeable()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let reports = DiagnosticReportCleaner(directories: ["/Library/Logs/DiagnosticReports", home + "/Library/Logs/DiagnosticReports"])
            .plan(olderThanDays: DiagnosticReportCleaner.defaultOlderThanDays)
        return SystemDataSnapshot(report: report, purgeableAssetsBytes: purgeable, reports: reports, assetFamilies: AssetFamilyScanner().scan(), takenAt: Date())
    }

    /// Tests CacheDelete on this macOS build the first time (in the CLI child process), then asks how much is purgeable.
    /// Only mobileassetd's figure is used: the app-container-caches service also reports a figure (1.15 GB on 26B5091g), but
    /// purging it removed under 100 MB at any urgency, so it is not offered.
    static func livePurgeable() -> UInt64? {
        let client = CacheDeleteClient()
        let all: [String: UInt64]?
        if let cli = ToolLocator.cli() {
            client.ensureValidated(executable: cli)
            guard client.support == .validated else { return nil }
            all = CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli)
        } else {
            all = client.support == .validated ? client.purgeableByService() : nil
        }
        return all?[CacheDeleteService.mobileAsset]
    }
}
