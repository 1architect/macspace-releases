import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceSystemData
import MacSpaceSystemDataPrivileged

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
        XCTAssertEqual(list.rows.map(\.id), ["logs"], "reports are under Free now, swap is counted by Settings elsewhere, app data has its own list, tiny items are noise")
        XCTAssertFalse(section.isCollapsible, "a plain list, like In other apps")
        guard case let .section(apps)? = SystemDataScreenBuilder.appDataSection(snapshot(items: items)), case let .list(appList) = apps.widgets[0] else { return XCTFail() }
        XCTAssertEqual(appList.rows.map(\.id), ["app"])
    }

    /// Everything else is sorted into the bar's categories: several items make a group with its own page, one item is its own row,
    /// and the group row counts the items, not the categories.
    func testEverythingElseIsSortedIntoTheBarsCategories() throws {
        let items = [item("logs", kind: .logs, bytes: 900_000_000, cleanup: .managedByMacOS),
                     item("spotlight", kind: .spotlightIndex, bytes: 800_000_000, cleanup: .managedByMacOS),
                     item("brew", kind: .packageManager, bytes: 2_000_000_000, cleanup: .command),
                     item("tool", kind: .toolCache, bytes: 300_000_000, cleanup: .review),
                     item("pip", kind: .toolCache, bytes: 200_000_000, cleanup: .review)]
        let snap = snapshot(items: items)
        guard case let .section(section)? = SystemDataScreenBuilder.otherSection(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), ["brew", "other:macos", "other:caches"], "largest first; a category of one is its item")
        let macos = try XCTUnwrap(list.rows.first { $0.id == "other:macos" })
        XCTAssertEqual(macos.children.map(\.id), ["logs", "spotlight"])
        XCTAssertEqual(macos.title, "Managed by macOS")
        XCTAssertNil(macos.detail, "the title says why")
        XCTAssertEqual(list.rows.first { $0.id == "other:caches" }?.title, "Other caches",
                       "the caches that can be freed are on the caches page, so these are the others")
        let group = try XCTUnwrap(SystemDataScreenBuilder.group(.section(section), symbol: "x", total: 0))
        XCTAssertEqual(group.subtitle, "5 items")
        XCTAssertEqual(SystemDataScreenBuilder.OtherCategory.of(.virtualMachine).id, "other", "a kind in no category goes to Other")
    }

    /// Downloads, virtual machines and third-party apps' data are Documents and Applications in Settings; cloud copies are System Data
    /// (`~/Library` is left out of Documents: removing 21 GB of OneDrive downloads took Settings' System Data from 44.46 to 32.3 GB).
    func testThirdPartyAppDataAndDownloadsAreLeftOutOfTheBarButCloudCopiesAreIn() {
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
        XCTAssertEqual(usage.segments.map(\.id), ["versions", "appdata", "cloud", "leftovers"], "downloads and virtual machines are Documents in Settings")
        XCTAssertEqual(usage.segments.first { $0.id == "cloud" }?.bytes, 2_000)
        XCTAssertEqual(usage.segments.last?.bytes, 300)
        XCTAssertTrue(usage.footnote?.contains("not counted") == true)
    }

    func testFreeNowOffersOnlySafeItemsAndCleanIsThePagesMainAction() throws {
        let snap = snapshot(items: [
            item("usercache:small", kind: .userSystemCache, bytes: 100_000_000, cleanup: .deleteWhenNotRunning, reclaim: 100_000_000),
            item("supportcache:big", kind: .appCache, bytes: 900_000_000, cleanup: .deleteWhenNotRunning, reclaim: 900_000_000),
            item("supportcache:open", kind: .appCache, bytes: 500_000_000, cleanup: .deleteWhenNotRunning, reclaim: 500_000_000, inUse: true, owners: ["Chrome"]),
            item("usercache:crumbs", kind: .userSystemCache, bytes: 5_000, cleanup: .deleteWhenNotRunning, reclaim: 5_000),
        ], purgeable: 12_000_000_000, reports: 4_000_000)
        guard case let .section(section)? = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), ["assets", "caches", "reports"], "largest first; the caches are one page")
        let caches = list.rows[1]
        XCTAssertEqual(caches.children.map(\.id), ["supportcache:big", "usercache:small", "supportcache:open"],
                       "recommended first, the open app's cache last, crumbs hidden")
        XCTAssertNotNil(caches.selection?.choices["supportcache:open"], "chosen, its app is quit first if the user says so")
        XCTAssertEqual(caches.selection?.noteNames.keys.sorted(), ["supportcache:open"])
        XCTAssertEqual(caches.children.first { $0.id == "supportcache:open" }?.badges.map(\.text), ["Open now"])
        XCTAssertNotNil(list.rows[0].actions[0].confirmation)
        XCTAssertNotNil(list.rows[2].actions[0].confirmation, "freeing reports asks first")
        XCTAssertEqual(list.rows[2].actions[0].title, "Free", "one verb")
        XCTAssertEqual(SystemDataScreenBuilder.screen(snap).primary?.id, "cleanAll")
        XCTAssertEqual(SystemDataScreenBuilder.freeableBytes(snap), 1_000_000_000 + 12_000_000_000 + 4_000_000, "the open app's cache is not counted")
    }

    func testNothingToFreeShowsNoSectionAndNoMainAction() throws {
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(items: [])))
        XCTAssertNil(SystemDataScreenBuilder.screen(snapshot(items: [])).primary)
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(items: [], reports: 837)), "a few bytes of reports are not worth a row")
    }

    func testPurgeRowNeedsAMeaningfulAmount() throws {
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(items: [], purgeable: 1_000_000)), "1 MB is not worth a button")
    }

    func testScreenShowsAPartialBannerAndCollapsesTheRest() {
        let items = [item("supportcache:app", kind: .appCache, bytes: 900_000_000, cleanup: .deleteWhenNotRunning, reclaim: 900_000_000),
                     item("review", kind: .appSupport, bytes: 700_000_000), item("logs", kind: .logs, bytes: 300_000_000, cleanup: .managedByMacOS)]
        var withoutAccess = snapshot(items: items, unreadable: ["/p"])
        withoutAccess.report.fullDiskAccess = false
        let screen = SystemDataScreenBuilder.screen(withoutAccess)
        XCTAssertEqual(screen.widgets.map(\.id), ["partial", "free", "groups"], "what can be cleaned has its own section, item by item")
        guard case let .list(groups)? = screen.widgets.last else { return XCTFail("the groups are one list") }
        XCTAssertEqual(groups.rows.map(\.id), ["review", "logs"], "a group of one is that item's own row")
        XCTAssertEqual(SystemDataScreenBuilder.tile(withoutAccess).purgeableByService[CacheDeleteService.mobileAsset], 0,
                       "the disk tile counts the assets this page purges")
        XCTAssertEqual(screen.hero?.segments.isEmpty, false, "the bar is the page's hero")
        XCTAssertNil(screen.hero?.footnote)
        XCTAssertEqual(SystemDataScreenBuilder.screen(snapshot(items: items)).widgets.first?.id, "free", "no banner when everything was measured")
    }

    func testGroupsShowTheirCountAndTotalAndOpenEveryItem() throws {
        let items = (1...12).map { item("support\($0)", kind: .appSupport, bytes: UInt64($0) * 100_000_000) }
        let screen = SystemDataScreenBuilder.screen(snapshot(items: items))
        guard case let .list(groups)? = screen.widgets.last else { return XCTFail() }
        let appData = try XCTUnwrap(groups.rows.first { $0.id == "group:appdata" })
        XCTAssertEqual(appData.subtitle, "12 items")
        XCTAssertEqual(appData.children.count, 12, "the group's page lists every item, not the ten largest")
        XCTAssertEqual(appData.trailing, ByteFormat.string(78 * 100_000_000))
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
        let snap = snapshot(items: [item("supportcache:c", kind: .appCache, bytes: 900_000_000, cleanup: .deleteWhenNotRunning, reclaim: 600_000_000),
                                    item("l", kind: .logs, bytes: 2_000_000_000, cleanup: .managedByMacOS)])
        let tile = SystemDataScreenBuilder.tile(snap)
        XCTAssertTrue(tile.status.hasPrefix("free "))
        guard case let .blocks(blocks)? = tile.graphic else { return XCTFail() }
        XCTAssertEqual(blocks.map(\.id), ["macos", "freeable", "caches"], "largest first")
        XCTAssertEqual(blocks.first { $0.id == "freeable" }?.tone, .caution)
        XCTAssertEqual(blocks.first { $0.id == "caches" }?.bytes, 300_000_000, "the freeable part is taken out of the caches")
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.bytes }, 2_900_000_000, "the total stays the same")
        XCTAssertEqual(SystemDataScreenBuilder.tile(snapshot(items: [])).status, "nothing to free")
    }
    /// What macOS deletes by itself when space runs low (files flagged purgeable, the purgeable system assets) is free space for
    /// System Settings, so it is not counted in System Data, and the bar says so.
    func testPurgeableSpaceIsNotCountedInSystemData() {
        var support = item("support", kind: .appSupport, bytes: 1_000_000_000)
        support.purgeableBytes = 400_000_000
        let snap = snapshot(items: [support, item("assets:system", kind: .systemAssets, bytes: 2_000_000_000, cleanup: .command)], purgeable: 500_000_000)
        XCTAssertEqual(SystemDataScreenBuilder.total(snap), 600_000_000 + 1_500_000_000)
        XCTAssertEqual(SystemDataScreenBuilder.tile(snap).figure, ByteFormat.string(2_100_000_000), "the total is back on the tile")
        XCTAssertTrue(SystemDataScreenBuilder.usage(snap).footnote?.contains("not counted") == true, "the reading says what it leaves out")
    }

    /// While Apple Intelligence is on, the unused system assets are listed but not offered: no button, not in Clean or the tile's figure.
    func testSystemAssetsAreKeptWhileAppleIntelligenceIsOn() throws {
        var snap = snapshot(items: [], purgeable: 2_000_000_000)
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 2_000_000_000)
        snap.assetsHeld = true
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 0)
        XCTAssertNil(SystemDataScreenBuilder.cleanAll(snap))
        guard case let .section(section)? = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        let row = try XCTUnwrap(list.rows.first { $0.id == "assets" })
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertEqual(row.badge?.text, "Kept while Apple Intelligence is on")
    }

    /// Each block of the page lists what it is made of, sized as it counts in that block: what Clean frees is under "can be freed"
    /// (with its buttons), the rest of the caches under Caches. What no folder accounts for lists nothing, and the tile's blocks,
    /// which are saved, carry no items.
    func testEachBlockListsTheItemsItIsMadeOf() {
        let items = [item("usercache:clang", kind: .userSystemCache, bytes: 600_000_000, cleanup: .deleteWhenNotRunning, reclaim: 500_000_000),
                     item("appcache:Safari", kind: .appCache, bytes: 300_000_000, cleanup: .review),
                     item("logs", kind: .logs, bytes: 900_000_000, cleanup: .managedByMacOS)]
        var snap = snapshot(items: items)
        snap.settings = SettingsStorage(capacity: 245_000_000_000, used: 190_000_000_000, macOS: 45_000_000_000,
                                        categories: [SettingsStorage.Category(id: "applications", bytes: 100_000_000_000),
                                                     SettingsStorage.Category(id: "documents", bytes: 43_000_000_000)])
        let blocks = SystemDataScreenBuilder.blocksWithItems(snap)
        let caches = blocks.first { $0.id == "caches" }
        XCTAssertEqual(caches?.items.map(\.id), ["appcache:Safari", "usercache:clang"])
        XCTAssertEqual(caches?.items.map(\.trailing), ["300 MB", "100 MB"], "clang keeps only what Clean leaves")
        XCTAssertEqual(caches?.group?.id, "segment:caches")
        XCTAssertEqual(caches?.group?.trailing, "400 MB")
        let freeable = blocks.first { $0.id == "freeable" }
        XCTAssertEqual(freeable?.items.map(\.id), ["caches"], "the caches page, one click away")
        XCTAssertEqual(freeable?.items.first?.children.map(\.id), ["usercache:clang"])
        XCTAssertEqual(blocks.first { $0.id == "macos" }?.items.map(\.paths), [["/x/logs"]])
        XCTAssertNil(blocks.first { $0.id == "unidentified" }?.group, "nothing to list")
        XCTAssertTrue(SystemDataScreenBuilder.blocks(snap).allSatisfy(\.items.isEmpty))
        XCTAssertEqual(SystemDataScreenBuilder.screen(snap).hero?.segments, blocks)
    }

    /// With System Settings' reading, the total is its System Data, and what no listed folder accounts for is a block of its own, so
    /// the blocks still add up to the total.
    func testTheTotalIsSettingsRemainderAndTheBlocksAddUpToIt() {
        var snap = snapshot(items: [item("logs", kind: .logs, bytes: 3_000_000_000, cleanup: .managedByMacOS)])
        snap.settings = SettingsStorage(capacity: 245_000_000_000, used: 190_000_000_000, macOS: 45_000_000_000,
                                        categories: [SettingsStorage.Category(id: "applications", bytes: 100_000_000_000),
                                                     SettingsStorage.Category(id: "documents", bytes: 40_000_000_000)])
        XCTAssertEqual(SystemDataScreenBuilder.total(snap), 5_000_000_000)
        let blocks = SystemDataScreenBuilder.blocks(snap)
        XCTAssertEqual(blocks.first { $0.id == "unidentified" }?.bytes, 2_000_000_000)
        XCTAssertEqual(blocks.map(\.bytes).reduce(0, +), 5_000_000_000)
        XCTAssertEqual(SystemDataScreenBuilder.tile(snap).title, "system data")
        XCTAssertEqual(SystemDataScreenBuilder.tile(snap).figure, "5 GB")
    }

    /// Once everything MacSpace can measure is measured, the remainder is what macOS keeps closed to every app: it is named so, and
    /// its page lists those folders by kind, with no size and no Finder button (they cannot be opened), and the file system's own
    /// metadata. While places are still unmeasured it stays "Not identified" and opens nothing.
    func testTheRemainderIsProtectedByMacOSOnceEverythingIsMeasured() throws {
        var snap = snapshot(items: [item("logs", kind: .logs, bytes: 3_000_000_000, cleanup: .managedByMacOS)])
        snap.settings = SettingsStorage(capacity: 245_000_000_000, used: 190_000_000_000, macOS: 45_000_000_000,
                                        categories: [SettingsStorage.Category(id: "applications", bytes: 100_000_000_000),
                                                     SettingsStorage.Category(id: "documents", bytes: 40_000_000_000)])
        XCTAssertEqual(SystemDataScreenBuilder.blocks(snap).first { $0.id == "unidentified" }?.label, "Not identified")
        snap.report.protectedFolders = ["/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels", "/private/var/db/oah",
                                        "/private/var/db/CoreDuet/Knowledge", "/var/folders/x/y/0/com.apple.ScreenTimeAgent"]
        let block = try XCTUnwrap(SystemDataScreenBuilder.blocksWithItems(snap).first { $0.id == "unidentified" })
        XCTAssertEqual(block.label, "Protected by macOS")
        XCTAssertEqual(block.bytes, 2_000_000_000, "the measured remainder, unchanged")
        XCTAssertEqual(block.items.map(\.id), ["protected:assets", "protected:databases", "protected:other", "protected:filesystem"])
        // No folder names macOS uses inside: the user sees what they are, not what they are called (interface rules).
        XCTAssertFalse(block.items[0].detail?.contains("UAF_FM_GenerativeModels") == true)
        XCTAssertFalse(block.items[1].detail?.contains("CoreDuet") == true)
        XCTAssertEqual(block.items[1].subtitle, "2 items")
        XCTAssertTrue(block.items.allSatisfy { $0.paths.isEmpty && $0.trailing == nil })
        XCTAssertEqual(block.group?.id, "segment:unidentified")
        XCTAssertNil(block.items[0].badge)
        // The system assets item says where the closed families are; with Apple Intelligence on, they are marked as kept.
        snap.report.items.append(item("assets:system", kind: .systemAssets, bytes: 500_000_000, cleanup: .command))
        snap.assetsHeld = true
        let blocks = SystemDataScreenBuilder.blocksWithItems(snap)
        let assets = try XCTUnwrap(blocks.first { $0.id == "macos" }?.items.first { $0.id == "assets:system" })
        XCTAssertTrue(assets.detail?.contains("1 more, including Apple Intelligence models") == true)
        XCTAssertEqual(blocks.first { $0.id == "unidentified" }?.items.first?.badge?.text, "Kept while Apple Intelligence is on")
        snap.report.fullDiskAccess = false
        let unmeasured = try XCTUnwrap(SystemDataScreenBuilder.blocksWithItems(snap).first { $0.id == "unidentified" })
        XCTAssertEqual(unmeasured.label, "Not identified")
        XCTAssertTrue(unmeasured.items.isEmpty)
    }

    /// macOS's purge counts part of the apps' container caches as purgeable, which Settings counts as free space: each Apple container
    /// leaves out the service's share of its own caches folder.
    func testPurgeableContainerCachesAreNotCounted() {
        var wallpaper = item("container:com.apple.wallpaper.agent", kind: .appContainer, bytes: 1_200_000_000, cleanup: .managedByMacOS)
        wallpaper.cachesBytes = 1_000_000_000
        var snap = snapshot(items: [wallpaper])
        snap.report.containerCachesBytes = 2_000_000_000
        snap.purgeableServices = [CacheDeleteService.appContainerCaches: 1_000_000_000]
        XCTAssertEqual(SystemDataScreenBuilder.counted(wallpaper, snap), 700_000_000, "half of its caches, as the service has half of all")
        snap.purgeableServices = [:]
        XCTAssertEqual(SystemDataScreenBuilder.counted(wallpaper, snap), 1_200_000_000, "without the service's figure, all of it")
    }

    /// The apps inside an item are not System Data (System Settings lists them under Applications), and are said apart from what
    /// macOS deletes by itself.
    func testAppsInsideAnItemAreNotCounted() {
        var support = item("appsupport:Tool", kind: .appSupport, bytes: 1_000_000_000)
        support.elsewhereBytes = 400_000_000
        support.purgeableBytes = 100_000_000
        let snap = snapshot(items: [support])
        XCTAssertEqual(SystemDataScreenBuilder.total(snap), 500_000_000)
        XCTAssertEqual(SystemDataScreenBuilder.purgeableExcluded(snap), 100_000_000)
        XCTAssertEqual(SystemDataScreenBuilder.appsExcluded(snap), 400_000_000)
        XCTAssertTrue(SystemDataScreenBuilder.usage(snap).footnote?.contains("400 MB of apps inside these folders") == true)
    }

    /// The helper measures what only root can read anywhere under the system's folders, on any Mac, and never a home folder.
    func testTheHelperMeasuresSystemFoldersOnly() {
        XCTAssertTrue(RootMeasuredLocations.isAllowed("/private/var/db/CoreDuet"))
        XCTAssertTrue(RootMeasuredLocations.isAllowed("/Library/Application Support/Vendor"))
        XCTAssertTrue(RootMeasuredLocations.isAllowed("/System/Volumes/Data/.fseventsd"))
        XCTAssertFalse(RootMeasuredLocations.isAllowed("/System/Volumes/Data/Users/someone"))
        XCTAssertFalse(RootMeasuredLocations.isAllowed("/Users/someone/Library"))
        XCTAssertFalse(RootMeasuredLocations.isAllowed("/private/var/../etc"))
        XCTAssertFalse(RootMeasuredLocations.isAllowed("/private/var/"))
        XCTAssertFalse(RootMeasuredLocations.isAllowed("/System/Volumes/Data//Users/someone"))
    }

    /// A link to a home folder, made where anyone may write (`/private/tmp`), passes the text check; the disk check refuses it.
    func testTheHelperRefusesAPathThroughALink() throws {
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil).map { defer { free($0) }; return String(cString: $0) })
        let folder = temporary + "/allowed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/real", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: NSHomeDirectory())
        XCTAssertTrue(RootMeasuredLocations.isAllowedOnDisk(folder + "/real"))
        XCTAssertTrue(RootMeasuredLocations.isAllowed(folder + "/link/Documents"))
        XCTAssertFalse(RootMeasuredLocations.isAllowedOnDisk(folder + "/link/Documents"))
        XCTAssertNil(FileTreeSizer(refusesLinks: true).size(at: URL(fileURLWithPath: folder + "/link/Library")).flatMap(\.allocatedBytesEstimate))
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

    /// The scan's progress reaches the caller that started it and one that joined it, and ends full.
    func testScanProgressReachesEveryCaller() async {
        final class Heard: @unchecked Sendable { var values: [Double] = []; let lock = NSLock(); func add(_ v: Double) { lock.withLock { values.append(v) } } }
        let first = Heard(), joined = Heard()
        let store = SystemDataStore(builder: { (progress: LoadProgressRelay) in
            progress.report(0.3)
            Thread.sleep(forTimeInterval: 0.2)
            progress.report(0.6)
            return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [], measuredBytes: 0, cleanableBytes: 0,
                                                             manualCleanup: [], unreadable: [], warnings: []),
                                    purgeableAssetsBytes: nil,
                                    reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date())
        })
        async let a = store.snapshot(progress: first.add)
        try? await Task.sleep(for: .milliseconds(50))
        async let b = store.snapshot(progress: joined.add)
        _ = await (a, b)
        XCTAssertEqual(first.values.last, 1)
        XCTAssertEqual(joined.values.last, 1)
        XCTAssertTrue(first.values.contains(0.6) && joined.values.contains(0.6))
        XCTAssertEqual(first.values, first.values.sorted(), "never backwards")
    }

    /// A caller waiting on a scan when an action invalidates the store must not get that scan's figures (from before the action).
    func testACallerWaitingOnAnObsoleteScanGetsAFreshOne() async throws {
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock(); func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }
        let counter = Counter()
        let store = SystemDataStore(builder: {
            let scan = counter.next()
            Thread.sleep(forTimeInterval: 0.3)
            return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [], measuredBytes: UInt64(scan), cleanableBytes: 0,
                                                             manualCleanup: [], unreadable: [], warnings: []),
                                    purgeableAssetsBytes: nil,
                                    reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date())
        })
        let first = Task { await store.snapshot() }
        try await Task.sleep(for: .milliseconds(50))
        let waiting = Task { await store.snapshot() }
        try await Task.sleep(for: .milliseconds(50))
        await store.invalidate()
        _ = await first.value
        let snapshot = await waiting.value
        XCTAssertEqual(snapshot.report.measuredBytes, 2, "the waiting caller got the scan started after the invalidate")
    }

    /// When the helper did not answer, a later reading asks it again for the same scan instead of keeping the failure for the
    /// scan's whole life, and does not scan the disk again.
    func testAHelperThatFailedIsAskedAgainWithoutANewScan() async {
        final class Counter: @unchecked Sendable { var scans = 0 }
        final class Helper: PrivilegedChannel, @unchecked Sendable {
            var answers = false
            func perform(operation: String, arguments: [String: String]) async throws -> Data {
                guard answers else { throw PrivilegedHelperError.noAnswer(seconds: 8) }
                return try JSONEncoder().encode(RootMeasurementResponse(sizes: [:], purgeable: [:]))
            }
        }
        let counter = Counter()
        let helper = Helper()
        let store = SystemDataStore(builder: {
            counter.scans += 1
            return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [], measuredBytes: 0, cleanableBytes: 0,
                                                             manualCleanup: [], unreadable: ["/private/var/db/diagnostics"], warnings: []),
                                    purgeableAssetsBytes: nil,
                                    reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date())
        })
        let first = await store.snapshot(privileged: helper)
        XCTAssertNotNil(first.helperError)
        helper.answers = true
        let soon = await store.snapshot(now: Date().addingTimeInterval(10), privileged: helper)
        XCTAssertNotNil(soon.helperError, "not asked again within the minute")
        let later = await store.snapshot(now: Date().addingTimeInterval(SystemDataStore.helperRetry + 1), privileged: helper)
        XCTAssertNil(later.helperError)
        XCTAssertTrue(later.helperTried)
        XCTAssertEqual(counter.scans, 1, "the disk is not scanned again")
    }

}

final class PrivilegedReadingsTests: XCTestCase {
    /// Measuring is open to every account; deleting the version history, a staged update or wallpaper downloads needs an
    /// administrator (`PrivilegedHelperService`).
    func testOnlyMeasuringIsOpenToEveryAccount() {
        XCTAssertEqual(SystemDataPrivilegedOperations().readOnlyOperations, [SystemDataPrivilegedOperations.measure])
    }
}
