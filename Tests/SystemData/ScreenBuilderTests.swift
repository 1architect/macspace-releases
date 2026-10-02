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
        XCTAssertTrue(usage.footnote?.contains("1 place macOS keeps private was skipped") == true)
    }

    func testEverythingElseListsWhatMacSpaceLeavesAloneOnce() throws {
        let items = [item("reports:diagnostic", kind: .diagnosticReports, bytes: 500_000_000, cleanup: .command),
                     item("system:swap", kind: .virtualMemory, bytes: 2_000_000_000, cleanup: .managedByMacOS),
                     item("logs", kind: .logs, bytes: 900_000_000, cleanup: .managedByMacOS),
                     item("app", kind: .appSupport, bytes: 700_000_000),
                     item("tiny", kind: .logs, bytes: 1_000, cleanup: .managedByMacOS)]
        guard case let .section(section)? = SystemDataScreenBuilder.otherSection(snapshot(items: items)), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), ["logs", "app"], "reports are under Free now, swap is counted by Settings elsewhere, tiny items are noise")
        XCTAssertFalse(section.isCollapsible, "a plain list, like In other apps")
    }

    func testCloudCopiesAndThirdPartyAppDataAreLeftOutOfTheBar() {
        let report = snapshot(items: [
            item("cloud", kind: .cloudStorage, bytes: 2_000),
            item("whatsapp", kind: .appContainer, bytes: 9_000, cleanup: .review),
            item("apple-container", kind: .appContainer, bytes: 500, cleanup: .managedByMacOS),
            item("versions", kind: .documentVersions, bytes: 100, cleanup: .managedByMacOS),
            item("ipsw", kind: .restoreImage, bytes: 25_000),
            item("part", kind: .partialDownload, bytes: 4_000),
            item("vm", kind: .virtualMachine, bytes: 7_000),
            item("orphan", kind: .orphanedHome, bytes: 300),
        ])
        let usage = SystemDataScreenBuilder.usage(report)
        XCTAssertEqual(usage.segments.map(\.id), ["versions", "appdata", "leftovers"], "downloads and virtual machines are Documents in Settings")
        XCTAssertEqual(usage.segments.last?.bytes, 300)
        XCTAssertTrue(usage.footnote?.contains("not counted") == true)
    }

    func testFreeNowOffersOnlySafeItemsAndCleanIsThePagesMainAction() throws {
        let snap = snapshot(items: [
            item("small", kind: .appCache, bytes: 100_000_000, cleanup: .deleteWhenNotRunning, reclaim: 100_000_000),
            item("big", kind: .appCache, bytes: 900_000_000, cleanup: .deleteWhenNotRunning, reclaim: 900_000_000),
            item("open", kind: .appCache, bytes: 500_000_000, cleanup: .deleteWhenNotRunning, reclaim: 500_000_000, inUse: true, owners: ["Chrome"]),
            item("crumbs", kind: .appCache, bytes: 5_000, cleanup: .deleteWhenNotRunning, reclaim: 5_000),
        ], purgeable: 12_000_000_000, reports: 4_000_000)
        guard case let .section(section)? = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), ["big", "open", "small", "reports", "assets"], "largest first, crumbs hidden")
        XCTAssertEqual(list.rows[0].actions.map(\.id), ["clean"])
        XCTAssertTrue(list.rows[1].actions.isEmpty, "an item whose app is open cannot be cleaned")
        XCTAssertEqual(list.rows[1].badge?.text, "App is open")
        XCTAssertNil(list.rows[0].badge, "an ordinary row needs no badge")
        XCTAssertNotNil(list.rows[3].actions[0].confirmation, "deleting reports asks first")
        XCTAssertNotNil(list.rows[4].actions[0].confirmation)
        XCTAssertEqual(SystemDataScreenBuilder.screen(snap).primary?.id, "cleanAll")
        XCTAssertEqual(SystemDataScreenBuilder.freeableBytes(snap), 1_000_005_000 + 12_000_000_000 + 4_000_000, "the open app's cache is not counted")
    }

    func testNothingToFreeShowsNoSectionAndNoMainAction() throws {
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(items: [])))
        XCTAssertNil(SystemDataScreenBuilder.screen(snapshot(items: [])).primary)
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(items: [], reports: 837)), "a few bytes of reports are not worth a row")
    }

    func testPurgeRowNeedsAMeaningfulAmount() throws {
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(items: [], purgeable: 1_000_000)), "1 MB is not worth a button")
    }

    func testManualSectionCarriesTheGuideStepsAndOnlyMeasuredLargeEntries() throws {
        let guide = ManualCleanupGuide(app: "WhatsApp", frees: "media", steps: ["Open Storage", "Delete"], verified: false)
        let snap = snapshot(items: [], manual: [ManualCleanupSummary(app: "WhatsApp", bytes: 4_700_000_000, itemIDs: ["container:wa"], guide: guide),
                                                ManualCleanupSummary(app: "Unmeasured", bytes: nil, itemIDs: [], guide: guide),
                                                ManualCleanupSummary(app: "Empty", bytes: 0, itemIDs: [], guide: guide)])
        guard case let .section(section)? = SystemDataScreenBuilder.manualSection(snap.report), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.title), ["WhatsApp"])
        XCTAssertEqual(list.rows[0].steps, ["Open Storage", "Delete"])
        XCTAssertNil(SystemDataScreenBuilder.manualSection(snapshot(items: []).report))
    }

    func testScreenShowsAPartialBannerAndCollapsesTheRest() {
        let items = [item("cache", kind: .appCache, bytes: 900_000_000, cleanup: .deleteWhenNotRunning, reclaim: 900_000_000),
                     item("review", kind: .appSupport, bytes: 700_000_000), item("logs", kind: .logs, bytes: 300_000_000, cleanup: .managedByMacOS)]
        var withoutAccess = snapshot(items: items, unreadable: ["/p"])
        withoutAccess.report.fullDiskAccess = false
        let screen = SystemDataScreenBuilder.screen(withoutAccess)
        XCTAssertEqual(screen.widgets.map(\.id), ["partial", "free", "other"])
        XCTAssertEqual(screen.hero?.segments.isEmpty, false, "the bar is the page's hero")
        XCTAssertNil(screen.hero?.footnote)
        XCTAssertEqual(SystemDataScreenBuilder.screen(snapshot(items: items)).widgets.first?.id, "free", "no banner when everything was measured")
    }

    func testPlacesNoCustomerCanFixAreNotAWarning() {
        // Full Disk Access is on; one Apple container stays closed to every app. That is not a banner, only a quiet note.
        let snap = snapshot(items: [item("c", kind: .appCache, bytes: 900)], unreadable: ["/Users/x/Library/Group Containers/group.com.apple.Safari.SandboxBroker"])
        XCTAssertNil(SystemDataScreenBuilder.partialBanner(snap))
        XCTAssertNotEqual(SystemDataScreenBuilder.screen(snap).widgets.first?.id, "partial")
        XCTAssertTrue(SystemDataScreenBuilder.usage(snap).footnote?.contains("1 place macOS keeps private was skipped") == true)
        XCTAssertFalse(SystemDataScreenBuilder.usage(snap).footnote?.contains("could not") == true)

        // Without Full Disk Access the same place is something the user can fix.
        var needsAccess = snap
        needsAccess.report.fullDiskAccess = false
        guard case let .banner(banner) = SystemDataScreenBuilder.partialBanner(needsAccess) else { return XCTFail("expected a banner") }
        XCTAssertEqual(banner.action?.id, "openFullDiskAccess")
        XCTAssertTrue(banner.title.contains("Full Disk Access"))
    }

    func testTileStatesWhatCanBeFreedAndSplitsItOutOfTheCaches() {
        let snap = snapshot(items: [item("c", kind: .appCache, bytes: 900_000_000, cleanup: .deleteWhenNotRunning, reclaim: 600_000_000),
                                    item("l", kind: .logs, bytes: 2_000_000_000, cleanup: .managedByMacOS)])
        let tile = SystemDataScreenBuilder.tile(snap)
        XCTAssertTrue(tile.status.hasSuffix("can be freed"))
        guard case let .blocks(blocks)? = tile.graphic else { return XCTFail() }
        XCTAssertEqual(blocks.map(\.id), ["macos", "freeable", "caches"], "largest first")
        XCTAssertEqual(blocks.first { $0.id == "freeable" }?.tone, .caution)
        XCTAssertEqual(blocks.first { $0.id == "caches" }?.bytes, 300_000_000, "the freeable part is taken out of the caches")
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.bytes }, 2_900_000_000, "the total stays the same")
        XCTAssertEqual(SystemDataScreenBuilder.tile(snapshot(items: [])).status, "nothing to clean")
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
