import XCTest
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged
@testable import MacSpaceSystemData

final class CleanupPublicationTests: XCTestCase {
    private func snapshot() -> SystemDataSnapshot {
        let root = "/nonexistent-macspace-test-" + UUID().uuidString
        let items = ["target", "unrelated"].map {
            SystemDataItem(id: $0, title: $0, kind: .toolCache, paths: [root + "/" + $0], bytes: 100,
                           readable: true, owners: [], inUse: false, cleanup: .init(kind: .review, description: "", command: nil), notes: [])
        }
        return SystemDataSnapshot(report: .init(schemaVersion: 1, generatedAt: Date(), items: items, measuredBytes: 200, unreadable: []),
                                  purgeableAssetsBytes: nil, reports: .init(olderThanDays: 7, cutoff: .distantPast, candidates: [],
                                                                         totalBytes: 0, unreadableDirectories: []), takenAt: Date())
    }

    func testOlderScanCannotOverwritePublishedCleanupOrStartAnotherScan() async {
        final class Scans: @unchecked Sendable {
            let lock = NSLock(), resume = DispatchSemaphore(value: 0)
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let scans = Scans(), started = expectation(description: "old scan started")
        let original = snapshot()
        let store = SystemDataStore(builder: {
            if scans.next() == 2 { started.fulfill(); scans.resume.wait() }
            return original
        })
        _ = await store.snapshot()
        let obsolete = Task { await store.snapshot(maxAge: 0) }
        await fulfillment(of: [started], timeout: 2)
        await store.beginMutation()
        let published = await store.reconcile(ActionRequest(actionID: "clean", parameters: ["id": "target"]),
                                              privileged: nil, choices: CacheChoices(), cleaner: .macSpace)
        scans.resume.signal()
        let waited = await obsolete.value
        XCTAssertEqual(published?.report.items[0].bytes, 0)
        XCTAssertEqual(waited.report.items[0].bytes, 0)
        XCTAssertEqual(waited.report.items[1].bytes, 100)
        XCTAssertEqual(scans.count, 2, "a stale waiter must use the mutation publication, not start a full scan")
    }

    func testTargetedCleanupNeverProbesHomebrewOrUnrelatedTargets() async {
        final class Paths: @unchecked Sendable {
            let lock = NSLock()
            var seen: [String] = []
            func record(_ paths: [String]) { lock.withLock { seen += paths } }
        }
        let paths = Paths()
        var original = snapshot()
        original.homebrew = .init(brew: "/never-run-brew", standard: .init(bytes: 20, error: nil), allDownloads: .init(bytes: 80, error: nil))
        let updated = await TargetedSystemDataMeasurements.reconcile(original, request: .init(actionID: "clean", parameters: ["id": "target"]), privileged: nil,
            measure: { requested in
                paths.record(requested)
                return [requested[0]: FileTreeSize(logicalBytes: 40, allocatedBytesEstimate: 40)]
            }, homebrewEstimate: { _, _ in
                XCTFail("Unrelated Homebrew probe")
                return .init(bytes: nil, error: nil)
            })
        XCTAssertEqual(paths.seen, original.report.items[0].paths)
        XCTAssertEqual(updated.report.items.map(\.bytes), [40, 100])
        XCTAssertEqual(updated.homebrew, original.homebrew)
    }

    func testPartialMergedCacheKeepsItsRowAndSuccessfulTargetsFinishIndependently() async {
        final class Updates: @unchecked Sendable {
            let lock = NSLock()
            var finished: [String] = []
            func record(_ progress: ActionProgress) { lock.withLock { finished = progress.finished } }
        }
        let updates = Updates()
        let partial = CacheEntry(id: "partial", title: "Partial", bytes: 100, paths: ["/test/a", "/test/b"], source: .app)
        let complete = CacheEntry(id: "complete", title: "Complete", bytes: 100, paths: ["/test/c"], source: .app)
        let result = await SystemDataModule.freeCaches([partial, complete], in: snapshot(), quitApps: false, progress: updates.record,
            cleanup: { entry, _ in
                if entry.id == "partial" {
                    return [.init(itemID: "a", deleted: true, detail: "Success without English deletion text"),
                            .init(itemID: "b", deleted: false, detail: "Deleted is merely a word in an error")]
                }
                return [.init(itemID: entry.id, deleted: true, detail: "Completed")]
            })
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(updates.finished, ["complete"])
        XCTAssertEqual(result.details.count, 3)
        let partialPath = SystemDataCleanupResult(itemID: "multi", deleted: false, detail: "second path failed", removedPaths: ["/test/first"])
        XCTAssertTrue(partialPath.changed)
        XCTAssertEqual(SystemDataCleanupReport(results: [partialPath], freeBytesBefore: nil, freeBytesAfter: nil).actionResult.outcome, .succeeded)
    }

    func testMeasuredDeveloperRemainderUpdatesParentAndRemovesOnlyEmptyEntries() {
        var original = snapshot()
        original.developerCaches = [.init(id: "dev:cache", title: "Cache", paths: ["/test/cache"], bytes: 8_000_000,
                                          owners: [], method: .delete)]
        original.report.items[0].bytes = 10_000_000
        let entry = CacheEntry(id: "dev:cache", title: "Cache", bytes: 8_000_000, paths: ["/test/cache"], source: .developer, within: "target")
        let partial = TargetedSystemDataMeasurements.applying(["/test/cache": .init(logicalBytes: 3_000_000, allocatedBytesEstimate: 3_000_000)], itemIDs: [], entries: [entry], to: original)
        XCTAssertEqual(partial.report.items[0].bytes, 5_000_000)
        XCTAssertEqual(CachesPage.entries(partial).first?.bytes, 3_000_000)
        let empty = TargetedSystemDataMeasurements.applying(["/test/cache": .init(logicalBytes: 0, allocatedBytesEstimate: 0)], itemIDs: [], entries: [entry], to: original)
        XCTAssertTrue(CachesPage.entries(empty).isEmpty)
        XCTAssertEqual(empty.report.items[0].bytes, 2_000_000)
    }

    func testMissingAfterMeasurementIsUnknownRatherThanAllBeforeBytesFreed() throws {
        let result = try JSONDecoder().decode(StagedUpdateResult.self, from: Data(#"{"executed":true,"bytesBefore":1000,"bytesAfter":null,"removedEntries":0}"#.utf8))
        XCTAssertNil(result.reported)
    }

    func testAutomaticCleanupDoesNotMeasureLogOrHeldAssets() {
        var original = snapshot()
        original.assetsHeld = true
        original.purgeableAssetsBytes = 100
        XCTAssertTrue(TargetedSystemDataMeasurements.itemIDs(.init(actionID: "autoClean"), snapshot: original).isEmpty)
        XCTAssertEqual(SystemDataModule.freedMessage(nil), "All done", "unknown free space must not claim there was nothing to free")
    }
}
