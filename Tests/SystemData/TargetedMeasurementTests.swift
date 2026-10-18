import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceSystemData

final class TargetedMeasurementTests: XCTestCase {
    private func item(_ id: String, bytes: UInt64, kind: SystemDataKind = .toolCache, path: String? = nil) -> SystemDataItem {
        SystemDataItem(id: id, title: id, kind: kind, paths: [path ?? "/test/\(id)"], bytes: bytes, readable: true,
                       owners: [], inUse: false, cleanup: SystemDataCleanup(kind: .review, description: "", command: nil), notes: [])
    }
    private func snapshot(_ items: [SystemDataItem]) -> SystemDataSnapshot {
        var result = SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: .distantPast, items: items,
                                                               measuredBytes: items.compactMap(\.bytes).reduce(0, +), unreadable: []),
                                        purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: .distantPast)
        result.settings = SettingsStorage(capacity: 2000, used: 1000, macOS: 0, categories: [])
        return result
    }
    func testPartialTargetMeasurementPreservesOtherItemsAndAdjustsCachedTotal() throws {
        let original = snapshot([item("target", bytes: 100), item("unrelated", bytes: 300)])
        let updated = TargetedSystemDataMeasurements.applying(["/test/target": FileTreeSize(logicalBytes: 40, allocatedBytesEstimate: 40)], itemIDs: ["target"], to: original)
        XCTAssertEqual(updated.report.items[0].bytes, 40, "partial cleanup keeps the bytes that remain")
        XCTAssertEqual(updated.report.items[1], original.report.items[1])
        XCTAssertEqual(updated.report.measuredBytes, 340)
        XCTAssertEqual(updated.settings?.used, 940)
        XCTAssertEqual(updated.takenAt, original.takenAt, "targeted updates must not extend the full scan's cache lifetime")
        let unknown = TargetedSystemDataMeasurements.applying([:], itemIDs: ["target"], to: original)
        XCTAssertEqual(unknown.report.items, original.report.items, "an unreadable target must not be treated as empty")
    }
    func testCloudReceiptUpdatesOnlyItsProviderAndKeepsRemainingFilesActionable() throws {
        let path = "/h/Library/CloudStorage/OneDrive"
        let original = snapshot([item("cloud:OneDrive", bytes: 900, kind: .cloudStorage, path: path), item("unrelated", bytes: 300)])
        let source = PurgeableDocuments.Source(name: "OneDrive", path: path, bytes: 50, files: 2, folders: [])
        let receipt = CloudDownloadRemovals.Completion(revision: 1, path: path, source: source, localSize: FileTreeSize(logicalBytes: 500, allocatedBytesEstimate: 500))
        var updated = SystemDataStore.reconcilingCloud(original, changes: (1, [receipt]), removing: [:])
        XCTAssertEqual(updated.report.items[0].bytes, 500, "the local total includes pinned files, separately from the 50 eligible bytes")
        XCTAssertEqual(updated.report.items[1], original.report.items[1])
        XCTAssertEqual(updated.cloudSources, [source])
        let row = SystemDataScreenBuilder.itemRow(updated.report.items[0], bytes: 500, snapshot: updated)
        XCTAssertEqual(row.actions.first, CloudFileRows.action(source))
        XCTAssertEqual(row.id, "cloud:OneDrive")
        updated.removing = [path: .init(done: 1, total: 2, bytes: 25)]
        let running = SystemDataScreenBuilder.itemRow(updated.report.items[0], bytes: 500, snapshot: updated)
        XCTAssertEqual(running.activity?.fraction, 0.5)
        XCTAssertEqual(SystemDataScreenBuilder.tile(updated).refreshAfter, 2)
    }
    func testCleaningExcludedAppCopiesDoesNotChangeTheSystemDataBaseline() {
        let original = snapshot([item("clone:app", bytes: 100, kind: .codeSignClone), item("unrelated", bytes: 300)])
        let updated = TargetedSystemDataMeasurements.applying(["/test/clone:app": FileTreeSize(logicalBytes: 0, allocatedBytesEstimate: 0)], itemIDs: ["clone:app"], to: original)
        XCTAssertEqual(updated.report.items[0].bytes, 0)
        XCTAssertEqual(updated.settings, original.settings, "clones are excluded from System Data, so their cleanup cannot shrink that total")
    }

    func testActionScopesDoNotIncludeUnrelatedFolders() {
        let original = snapshot([item("versions:documents", bytes: 100, kind: .documentVersions), item("unrelated", bytes: 300)])
        XCTAssertEqual(TargetedSystemDataMeasurements.itemIDs(ActionRequest(actionID: "deleteVersions"), snapshot: original), ["versions:documents"])
        XCTAssertTrue(TargetedSystemDataMeasurements.itemIDs(ActionRequest(actionID: "removeDownloads"), snapshot: original).isEmpty)
    }
}
