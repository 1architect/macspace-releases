import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceSystemData

final class SystemDataScreenBuilderTests: XCTestCase {
    private func item(_ id: String, kind: SystemDataKind, bytes: UInt64, cleanup: SystemDataCleanup.Kind = .review, reclaim: UInt64? = nil,
                      inUse: Bool = false, owners: [String] = []) -> SystemDataItem {
        var item = SystemDataItem(id: id, title: id, kind: kind, paths: ["/x/\(id)"], bytes: bytes, readable: true, owners: owners, inUse: inUse,
                                  cleanup: SystemDataCleanup(kind: cleanup, description: "d", command: nil), notes: [])
        item.expectedReclaimBytes = reclaim
        return item
    }

    private func snapshot(items: [SystemDataItem], manual: [ManualCleanupSummary] = [], unreadable: [String] = [], purgeable: UInt64? = nil,
                          reports: UInt64 = 0) -> SystemDataSnapshot {
        let cleanable = items.filter { $0.cleanup.kind == .deleteWhenNotRunning }.compactMap(\.expectedReclaimBytes).reduce(0, +)
        let candidates = reports > 0 ? [CleanupCandidate(path: "/r.ips", kind: "ips", bytes: reports, modifiedAt: .distantPast)] : []
        return SystemDataSnapshot(
            report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: items, measuredBytes: 0, cleanableBytes: cleanable,
                                     manualCleanup: manual, unreadable: unreadable, warnings: []),
            purgeableAssetsBytes: purgeable,
            reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: candidates, totalBytes: reports, unreadableDirectories: []),
            takenAt: Date())
    }

    func testUsageGroupsKindsAndLeavesOutClones() {
        let usage = SystemDataScreenBuilder.usage(snapshot(items: [
            item("v", kind: .documentVersions, bytes: 6_000),
            item("c1", kind: .appCache, bytes: 1_000), item("c2", kind: .userSystemCache, bytes: 500),
            item("clone", kind: .codeSignClone, bytes: 99_000, cleanup: .managedByMacOS, reclaim: 0),
        ], unreadable: ["/p"]))
        XCTAssertEqual(usage.segments.map(\.id), ["versions", "caches"])
        XCTAssertEqual(usage.segments.map(\.bytes), [6_000, 1_500])
        XCTAssertTrue(usage.footnote?.contains("code-signing copies") == true)
        XCTAssertTrue(usage.footnote?.contains("1 location(s)") == true)
    }

    func testExplanationListLeavesOutWhatFreeNowAlreadyHandles() throws {
        let items = [item("reports:diagnostic", kind: .diagnosticReports, bytes: 5_000, cleanup: .command),
                     item("assets:system", kind: .systemAssets, bytes: 9_000, cleanup: .command),
                     item("system:swap", kind: .virtualMemory, bytes: 2_000, cleanup: .managedByMacOS)]
        func ids(purgeable: UInt64?) throws -> [String] {
            let snap = snapshot(items: items, purgeable: purgeable)
            guard case let .section(section) = try XCTUnwrap(SystemDataScreenBuilder.managedSection(snap.report, assetsListed: SystemDataScreenBuilder.freeNowHasAssets(snap))),
                  case let .list(list) = section.widgets[0] else { return [] }
            return list.rows.map(\.id)
        }
        XCTAssertEqual(try ids(purgeable: 200_000_000), ["system:swap"])
        XCTAssertEqual(Set(try ids(purgeable: nil)), ["assets:system", "system:swap"], "without a purge button the assets row explains itself")
    }

    func testFreeNowOffersOnlySafeItemsAndAFreeAllButton() throws {
        let snap = snapshot(items: [
            item("small", kind: .appCache, bytes: 100, cleanup: .deleteWhenNotRunning, reclaim: 100),
            item("big", kind: .appCache, bytes: 900, cleanup: .deleteWhenNotRunning, reclaim: 900),
            item("open", kind: .appCache, bytes: 500, cleanup: .deleteWhenNotRunning, reclaim: 500, inUse: true, owners: ["Chrome"]),
            item("zero", kind: .appCache, bytes: 50, cleanup: .deleteWhenNotRunning, reclaim: 0),
        ], purgeable: 12_000_000_000, reports: 4_000)
        guard case let .section(section) = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), ["big", "open", "small", "reports", "assets"], "largest first, zero-reclaim items hidden")
        XCTAssertEqual(list.rows[0].actions.map(\.id), ["clean"])
        XCTAssertTrue(list.rows[1].actions.isEmpty, "an item whose app is open cannot be cleaned")
        XCTAssertEqual(list.rows[1].badge?.text, "App is open")
        XCTAssertNotNil(list.rows[3].actions[0].confirmation, "deleting reports asks first")
        XCTAssertNotNil(list.rows[4].actions[0].confirmation)
        guard case let .button(button) = section.widgets[1] else { return XCTFail("expected a free-all button") }
        XCTAssertEqual(button.action.id, "cleanAll")
        XCTAssertEqual(SystemDataScreenBuilder.freeableBytes(snap), 1_000 + 12_000_000_000 + 4_000, "the open app's 500 bytes are not counted")
    }

    func testNothingToFreeShowsAnEmptyMessageAndNoButton() throws {
        guard case let .section(section) = SystemDataScreenBuilder.freeNow(snapshot(items: [])), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertTrue(list.rows.isEmpty)
        XCTAssertNotNil(list.emptyMessage)
        XCTAssertEqual(section.widgets.count, 1)
    }

    func testPurgeRowNeedsAMeaningfulAmount() throws {
        guard case let .section(section) = SystemDataScreenBuilder.freeNow(snapshot(items: [], purgeable: 1_000_000)), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertTrue(list.rows.isEmpty, "1 MB is not worth a button")
    }

    func testManualSectionCarriesTheGuideSteps() throws {
        let guide = ManualCleanupGuide(app: "WhatsApp", frees: "media", steps: ["Open Storage", "Delete"], verified: false)
        let snap = snapshot(items: [], manual: [ManualCleanupSummary(app: "WhatsApp", bytes: 4_700, itemIDs: ["container:wa"], guide: guide),
                                                ManualCleanupSummary(app: "Unmeasured", bytes: nil, itemIDs: [], guide: guide)])
        guard case let .section(section)? = SystemDataScreenBuilder.manualSection(snap.report), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows[0].steps, ["Open Storage", "Delete"])
        XCTAssertEqual(list.rows[1].trailing, "not measured")
        XCTAssertNil(SystemDataScreenBuilder.manualSection(snapshot(items: []).report))
    }

    func testScreenShowsAPartialBannerAndCollapsesTheRest() {
        let items = [item("cache", kind: .appCache, bytes: 900, cleanup: .deleteWhenNotRunning, reclaim: 900),
                     item("review", kind: .appSupport, bytes: 700), item("logs", kind: .logs, bytes: 300, cleanup: .managedByMacOS)]
        let screen = SystemDataScreenBuilder.screen(snapshot(items: items, unreadable: ["/p"]))
        XCTAssertEqual(screen.widgets.map(\.id), ["partial", "usage", "free", "review", "managed"])
        for case let .section(section) in screen.widgets where ["review", "managed"].contains(section.id) {
            XCTAssertTrue(section.isCollapsible && section.startsCollapsed)
        }
        XCTAssertEqual(SystemDataScreenBuilder.screen(snapshot(items: items)).widgets.first?.id, "usage", "no banner when everything was measured")
    }

    func testSummaryStatesWhatCanBeFreed() {
        guard case let .usage(usage) = SystemDataScreenBuilder.summary(snapshot(items: [item("c", kind: .appCache, bytes: 900, cleanup: .deleteWhenNotRunning, reclaim: 900)])) else { return XCTFail() }
        XCTAssertEqual(usage.title, "System Data")
        XCTAssertTrue(usage.footnote?.contains("can be freed now") == true)
        guard case let .usage(none) = SystemDataScreenBuilder.summary(snapshot(items: [])) else { return XCTFail() }
        XCTAssertEqual(none.footnote, "Nothing safe to clean right now.")
    }
}

final class SystemDataStoreTests: XCTestCase {
    func testConcurrentCallersShareOneScanAndCacheExpires() async {
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock(); func bump() { lock.lock(); n += 1; lock.unlock() } }
        let counter = Counter()
        let store = SystemDataStore(builder: {
            counter.bump()
            Thread.sleep(forTimeInterval: 0.2)
            return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [], measuredBytes: 0, cleanableBytes: 0,
                                                             manualCleanup: [], unreadable: [], warnings: []),
                                    purgeableAssetsBytes: nil,
                                    reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date())
        })
        async let a = store.snapshot()
        async let b = store.snapshot()
        _ = await (a, b)
        XCTAssertEqual(counter.n, 1, "the dashboard tile and the page share one scan")
        _ = await store.snapshot()
        XCTAssertEqual(counter.n, 1, "a recent snapshot is reused")
        await store.invalidate()
        _ = await store.snapshot()
        XCTAssertEqual(counter.n, 2)
    }
}
