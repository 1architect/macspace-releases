import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceOtherSystemFiles

final class OtherSystemFilesScreenBuilderTests: XCTestCase {
    /// The services as measured on the development Mac at urgency 3, 2026-10-02.
    private let measured: [String: UInt64] = [
        CacheDeleteService.fsPurgeableData: 4_888_453_120,
        CacheDeleteService.appContainerCaches: 1_154_867_200,
        CacheDeleteService.fsPurgeableDocument: 632_975_360,
        CacheDeleteService.quickLookThumbnails: 330_203_803,
        "com.apple.metadata.mds.cachedelete": 12_935_168,
    ]

    private func snapshot(_ services: [String: UInt64]?) -> PurgeableSnapshot { PurgeableSnapshot(services: services, takenAt: Date()) }

    func testRemovalStatusRetainsMeasurementsThroughCompletion() async throws {
        let reads = SnapshotReads()
        let store = PurgeableStore(builder: { _ in
            let number = reads.next()
            return PurgeableSnapshot(services: ["measurement": UInt64(number)], takenAt: number == 1 ? .distantPast : Date())
        })
        _ = await store.snapshot()
        await store.beginRemoval()
        let progress = CloudDownloadRemovals.Progress(done: 4, total: 100, bytes: 10_000)
        let first = await store.status(removing: ["OneDrive": progress, "iCloud": progress])
        XCTAssertEqual(first?.removing.count, 2)
        XCTAssertEqual(first?.services?["measurement"], 1)
        let next = await store.status(removing: ["OneDrive": progress])
        XCTAssertEqual(next?.removing.count, 1)
        XCTAssertEqual(reads.total, 1, "an expired snapshot still serves status without file/provider queries")
        let completed = await store.status(removing: [:])
        XCTAssertNotNil(completed, "completion uses the reconciled cached presentation without another full scan")
        XCTAssertEqual(reads.total, 1)
        let fresh = await store.snapshot()
        XCTAssertEqual(fresh.services?["measurement"], 2)
        _ = await store.status(removing: [:])
        _ = await store.snapshot()
        XCTAssertEqual(reads.total, 2, "the completion transition invalidates only once")
        await store.beginRemoval()
        await store.invalidate()
        let afterManualInvalidation = await store.status(removing: ["OneDrive": progress])
        XCTAssertNil(afterManualInvalidation, "explicit refresh can force a new scan during a removal")
    }

    func testCloudCompletionUpdatesItsProviderWithoutDiscardingOtherMeasurements() {
        let first = PurgeableDocuments.Source(name: "OneDrive", path: "/cloud/one", bytes: 900, files: 10, folders: [])
        let other = PurgeableDocuments.Source(name: "iCloud", path: "/cloud/two", bytes: 500, files: 8, folders: [])
        var original = snapshot(measured)
        original.documents = [first, other]
        let remaining = PurgeableDocuments.Source(name: "OneDrive", path: first.path, bytes: 300, files: 3, folders: [])
        let receipt = CloudDownloadRemovals.Completion(revision: 1, path: first.path, source: remaining, localSize: nil)
        let updated = PurgeableStore.reconciling(original, changes: (1, [receipt]))
        XCTAssertEqual(updated.documents, [other, remaining])
        XCTAssertEqual(updated.services, original.services, "cloud eviction must not fabricate a new CacheDelete pressure estimate")
        XCTAssertEqual(updated.timeMachine, original.timeMachine)
        XCTAssertEqual(updated.takenAt, original.takenAt)
        let empty = PurgeableDocuments.Source(name: first.name, path: first.path, bytes: 0, files: 0, folders: [])
        let final = PurgeableStore.reconciling(updated, changes: (2, [.init(revision: 2, path: first.path, source: empty, localSize: nil)]))
        XCTAssertEqual(final.documents, [other])
    }

    func testStoreSharesProgressWithPageJoiningTileAndKeepsCachedReadsQuiet() async throws {
        let fixture = snapshot([:])
        let reads = SnapshotReads()
        let started = expectation(description: "scan started")
        let joined = expectation(description: "page joined current scan")
        let release = DispatchSemaphore(value: 0)
        let heard = LoadProgressRelay()
        let store = PurgeableStore(builder: { progress in
            let read = reads.next()
            progress.report(0.25)
            if read == 1 {
                started.fulfill()
                reads.waitForRelease(release)
            }
            progress.report(0.75)
            return fixture
        })
        // The tile starts the scan without a sink. The page joins it later and must receive its current progress immediately.
        let tile = Task { await store.snapshot() }
        await fulfillment(of: [started], timeout: 2)
        let page = Task { await store.snapshot(progress: { value in
            heard.report(value)
            if value == 0.25 { joined.fulfill() }
        }) }
        await fulfillment(of: [joined], timeout: 2)
        release.signal()
        _ = await (tile.value, page.value)
        XCTAssertEqual(reads.total, 1)
        XCTAssertEqual(heard.fraction, 1)
        let cachedProgress = LoadProgressRelay()
        _ = await store.snapshot(progress: cachedProgress.report)
        XCTAssertNil(cachedProgress.fraction, "cached reads must not restore widget loading")
        XCTAssertEqual(reads.total, 1)
        await store.invalidate()
        let refreshed = LoadProgressRelay()
        _ = await store.snapshot(progress: refreshed.report)
        XCTAssertEqual(reads.total, 2)
        XCTAssertEqual(refreshed.fraction, 1)
    }

    func testCloudCleanupSurvivesSmallMissingOrUnavailablePressureEstimate() throws {
        for services: [String: UInt64]? in [nil, [:], [CacheDeleteService.fsPurgeableDocument: 17_342_464]] {
            var snap = snapshot(services)
            let path = "/h/Library/CloudStorage/OneDrive-Pessoal"
            snap.documents = [.init(name: "OneDrive (Pessoal)", path: path, bytes: 8_300_000_000, files: 4_000, folders: [])]
            let row = try XCTUnwrap(OtherSystemFilesScreenBuilder.cloudRows(snap).first)
            XCTAssertEqual(row.trailing, ByteFormat.string(8_300_000_000))
            XCTAssertEqual(row.actions.first?.parameters["path"], path)
            XCTAssertEqual(OtherSystemFilesScreenBuilder.cloudShares(snap), [8_300_000_000])
            XCTAssertNotNil(OtherSystemFilesScreenBuilder.freeNow(snap))
            XCTAssertFalse(OtherSystemFilesScreenBuilder.screen(snap).widgets.isEmpty)
            XCTAssertNotEqual(OtherSystemFilesScreenBuilder.tile(snap).status, "unavailable")
        }
    }

    func testOnlyThePurgeableAppFilesAreFreed() throws {
        let snap = snapshot(measured)
        XCTAssertEqual(snap.freeableBytes, 4_888_453_120)
        let screen = OtherSystemFilesScreenBuilder.screen(snap)
        XCTAssertEqual(screen.primary?.id, "purgeFiles")
        XCTAssertNotNil(screen.primary?.confirmation, "freeing asks first")
        guard case let .section(free)? = screen.widgets.first, case let .list(list) = free.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.map(\.id), [CacheDeleteService.fsPurgeableData], "what can be freed has its own section, row by row")
        XCTAssertEqual(list.rows[0].actions.map(\.id), ["purgeFiles"])
        guard case let .list(kept)? = screen.widgets.last else { return XCTFail() }
        XCTAssertEqual(kept.rows.map(\.id), [CacheDeleteService.appContainerCaches, CacheDeleteService.fsPurgeableDocument,
                                             CacheDeleteService.quickLookThumbnails], "what macOS keeps is listed row by row, not in a group")
        XCTAssertEqual(OtherSystemFilesScreenBuilder.tile(snap).purgeableByService, [CacheDeleteService.fsPurgeableData: 4_888_453_120],
                       "the disk tile counts what this page frees")
    }

    func testTheRestIsListedAsLeftAloneLargestFirst() throws {
        guard case let .section(kept)? = OtherSystemFilesScreenBuilder.keptSection(snapshot(measured)), case let .list(list) = kept.widgets[0] else {
            return XCTFail()
        }
        XCTAssertEqual(list.rows.map(\.id), [CacheDeleteService.appContainerCaches, CacheDeleteService.fsPurgeableDocument,
                                             CacheDeleteService.quickLookThumbnails], "13 MB of Spotlight is not worth a row")
        XCTAssertTrue(list.rows.allSatisfy(\.actions.isEmpty), "nothing left alone has a button")
        XCTAssertFalse(kept.isCollapsible, "listed open, like System Data's sections")
        XCTAssertTrue(list.rows.allSatisfy { $0.symbol != nil }, "each row has its symbol, like the rows above it")
    }

    /// macOS kept the files: they stay freeable, and while MacSpace asks again in the background the row says so instead of a button.
    func testFilesMacOSKeptStayFreeableWhileMacSpaceAsksAgain() throws {
        var snap = snapshot(measured)
        snap.retrying = true
        XCTAssertEqual(snap.freeableBytes, 4_888_453_120)
        XCTAssertNil(OtherSystemFilesScreenBuilder.freeAction(snap, prominent: true), "no button while MacSpace is already asking")
        XCTAssertTrue(OtherSystemFilesScreenBuilder.tile(snap).status.hasPrefix("freeing"))
        XCTAssertTrue(OtherSystemFilesScreenBuilder.segments(snap).contains { $0.tone == .caution })
        guard case let .section(free)? = OtherSystemFilesScreenBuilder.freeNow(snap), case let .list(list) = free.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows[0].badge?.text, "Freeing in the background")
        XCTAssertTrue(list.rows[0].actions.isEmpty)
    }

    func testWhatWasFreedIsTakenOffAnEstimateThatHasNotMovedYet() {
        let service = CacheDeleteService.fsPurgeableData
        var removed: (estimate: UInt64, bytes: UInt64)? = (877_900_000, 800_000_000)
        XCTAssertEqual(PurgeableStore.accounting(for: &removed, in: [service: 877_900_000])?[service], 77_900_000, "macOS still gives the old figure")
        XCTAssertNotNil(removed)
        XCTAssertEqual(PurgeableStore.accounting(for: &removed, in: [service: 60_000_000])?[service], 60_000_000, "macOS has measured again")
        // Time Machine's snapshots, whose figure stayed put for minutes after 635 MB of them were deleted.
        var snapshots: (estimate: UInt64, bytes: UInt64)? = (971_400_000, 635_400_000)
        let figure = PurgeableStore.accounting(for: &snapshots, in: [CacheDeleteService.timeMachineSnapshots: 971_400_000, service: 5],
                                               service: CacheDeleteService.timeMachineSnapshots)
        XCTAssertEqual(figure?[CacheDeleteService.timeMachineSnapshots], 336_000_000)
        XCTAssertEqual(figure?[service], 5, "only that service's figure changes")
        XCTAssertNil(removed, "and is believed from then on")
    }

    func testTheTileMarksWhatCanBeFreed() {
        let tile = OtherSystemFilesScreenBuilder.tile(snapshot(measured))
        XCTAssertEqual(tile.status, "free up to \(ByteFormat.string(4_888_453_120))")
        guard case let .blocks(segments)? = tile.graphic else { return XCTFail() }
        XCTAssertEqual(segments.first?.id, CacheDeleteService.fsPurgeableData)
        XCTAssertEqual(segments.first?.tone, .caution)
        XCTAssertEqual(segments.filter { $0.tone == .caution }.count, 1)
    }

    func testSmallAmountsOfferNothing() {
        let snap = snapshot([CacheDeleteService.fsPurgeableData: 1_000_000, CacheDeleteService.appContainerCaches: 1_154_867_200])
        XCTAssertNil(OtherSystemFilesScreenBuilder.screen(snap).primary, "1 MB is not worth a button")
        XCTAssertNil(OtherSystemFilesScreenBuilder.freeNow(snap))
        XCTAssertEqual(OtherSystemFilesScreenBuilder.tile(snap).status, "nothing to free")
    }

    func testUnavailableCacheDeleteSaysSo() {
        let snap = snapshot(nil)
        XCTAssertEqual(OtherSystemFilesScreenBuilder.tile(snap).status, "unavailable")
        let screen = OtherSystemFilesScreenBuilder.screen(snap)
        XCTAssertNil(screen.primary)
        guard case .banner? = screen.widgets.first else { return XCTFail("a banner explains why") }
    }

    /// Purgeable documents are named after the cloud service that holds them, whichever it is; each is a plain row that opens in place
    /// onto its folders, never a page of its own; what no cloud folder accounts for keeps a row of its own.
    func testCloudFilesAreRowsOfTheirOwnWhateverTheProvider() throws {
        var snap = snapshot([CacheDeleteService.fsPurgeableDocument: 30_000_000_000, CacheDeleteService.quickLookThumbnails: 100_000_000])
        snap.documents = [
            PurgeableDocuments.Source(name: "Dropbox", path: "/h/Library/CloudStorage/Dropbox", bytes: 18_000_000_000, files: 900,
                                      folders: [PurgeableDocuments.Folder(name: "Photos", bytes: 18_000_000_000, files: 900)]),
            PurgeableDocuments.Source(name: "GoogleDrive (me@example.com)", path: "/h/Library/CloudStorage/GoogleDrive-me@example.com", bytes: 7_000_000_000,
                                      files: 30, folders: []),
        ]
        let screen = OtherSystemFilesScreenBuilder.screen(snap)
        var rows: [Row] = []
        for widget in screen.widgets {
            let lists: [ListWidget]
            switch widget {
            case let .list(list): lists = [list]
            case let .section(section): lists = section.widgets.compactMap { if case let .list(list) = $0 { return list } else { return nil } }
            default: lists = []
            }
            for list in lists { rows += list.rows.flatMap { $0.children.isEmpty ? [$0] : $0.children } }
        }
        let cloud = rows.filter { $0.id.hasPrefix("documents:") }
        guard case let .section(free)? = OtherSystemFilesScreenBuilder.freeNow(snap), case let .list(freeList) = free.widgets[0] else { return XCTFail() }
        XCTAssertEqual(freeList.rows.filter { $0.id.hasPrefix("documents:") }.count, 2, "each cloud service's downloads can be removed now")
        XCTAssertEqual(cloud.map { $0.actions.first?.parameters["path"] }, snap.documents.map(\.path), "each row removes its own service's downloads")
        XCTAssertNotNil(cloud.first?.actions.first?.confirmation)
        XCTAssertEqual(cloud.map(\.title), ["Dropbox files on this Mac", "GoogleDrive (me@example.com) files on this Mac"])
        XCTAssertTrue(cloud.allSatisfy { $0.children.isEmpty }, "no page inside a page")
        XCTAssertTrue(cloud.first?.detail?.contains("GB") == true, "its folders are named in its description")
        XCTAssertTrue(cloud.first?.steps.isEmpty == true, "folders are not steps to follow")
        XCTAssertTrue(rows.contains { $0.title == "Other purgeable documents" }, "5 GB no cloud folder holds")
        XCTAssertEqual(OtherSystemFilesScreenBuilder.title(CacheDeleteService.fsPurgeableDocument, snap), "Cloud files on this Mac")
        XCTAssertEqual(PurgeableService.describe("com.apple.geod.cachedelete").title, "geod cache", "an unknown service still reads as words")
        XCTAssertEqual(PurgeableDocuments.displayName("OneDrive-Pessoal"), "OneDrive (Pessoal)")
        XCTAssertEqual(PurgeableDocuments.displayName("Dropbox"), "Dropbox")
    }

    /// While a cloud service's downloads are being removed, in the background, its row says how far it is and has no button, and the
    /// tile asks to be read again soon so both follow it; the rest of the page stays as it is.
    func testARemovalInTheBackgroundShowsOnItsRowAndTile() throws {
        var snap = snapshot([CacheDeleteService.fsPurgeableDocument: 20_000_000_000, CacheDeleteService.fsPurgeableData: 1_000_000_000])
        let path = "/h/Library/CloudStorage/OneDrive-Personal"
        snap.documents = [PurgeableDocuments.Source(name: "OneDrive (Personal)", path: path, bytes: 20_000_000_000, files: 8_000, folders: [])]
        snap.removing = [path: CloudDownloadRemovals.Progress(done: 2_000, total: 8_000, bytes: 9_000_000_000)]
        let row = try XCTUnwrap(OtherSystemFilesScreenBuilder.cloudRows(snap).first)
        XCTAssertEqual(row.activity?.message, "Removing 25%, 9 GB")
        XCTAssertEqual(row.activity?.fraction, 0.25)
        XCTAssertEqual(row.actions.first?.id, "removeDownloads", "the same flag morphs into disabled progress")
        let tile = OtherSystemFilesScreenBuilder.tile(snap)
        XCTAssertEqual(tile.refreshAfter, 2)
        XCTAssertEqual(tile.status, "removing downloads 25%")
        XCTAssertNotNil(OtherSystemFilesScreenBuilder.screen(snap).primary, "the app files can still be freed meanwhile")
        snap.removing = [:]
        XCTAssertNil(OtherSystemFilesScreenBuilder.tile(snap).refreshAfter)
        XCTAssertEqual(OtherSystemFilesScreenBuilder.cloudRows(snap).first?.actions.first?.id, "removeDownloads")
    }

    /// A macOS update waiting to install is outside System Data (System Settings counts it under macOS): it has its own section with
    /// Software Update's button, its own block, and it is in the tile's total.
    func testAPreparedUpdateIsAnOtherSystemFile() throws {
        var snap = snapshot([CacheDeleteService.fsPurgeableData: 1_000_000_000])
        snap.updates = [PreparedUpdate(name: "macOS 27.2 (26B5101f)", bytes: 10_700_000_000, path: "/System/Volumes/Preboot/X/cryptex1/proposed")]
        let screen = OtherSystemFilesScreenBuilder.screen(snap)
        let section = try XCTUnwrap(screen.widgets.compactMap { widget -> SectionWidget? in
            if case let .section(section) = widget, section.id == "updates" { return section } else { return nil }
        }.first)
        guard case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows.first?.title, "macOS 27.2 (26B5101f), ready to install")
        XCTAssertEqual(list.rows.first?.actions.first?.id, "openSoftwareUpdate")
        XCTAssertEqual(screen.hero?.segments.first?.bytes, 10_700_000_000, "the largest block")
        XCTAssertEqual(OtherSystemFilesScreenBuilder.tile(snap).title, "other system files")
        XCTAssertEqual(OtherSystemFilesScreenBuilder.tile(snap).figure, ByteFormat.string(11_700_000_000))
        XCTAssertNil(OtherSystemFilesScreenBuilder.updatesSection(snapshot([:])), "no section without an update")
    }

    /// Downloads are removed only from a cloud service's own folder or iCloud Drive, never from a folder inside one or elsewhere.
    func testDownloadsAreRemovedOnlyFromACloudFolder() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertTrue(PurgeableDocuments.isCloudFolder("/Users/someone/Library/CloudStorage/OneDrive-Personal", home: home))
        XCTAssertTrue(PurgeableDocuments.isCloudFolder("/Users/someone/Library/Mobile Documents", home: home))
        XCTAssertFalse(PurgeableDocuments.isCloudFolder("/Users/someone/Library/CloudStorage", home: home))
        XCTAssertFalse(PurgeableDocuments.isCloudFolder("/Users/someone/Library/CloudStorage/Dropbox/Photos", home: home))
        XCTAssertFalse(PurgeableDocuments.isCloudFolder("/Users/someone/Library/CloudStorage/../Caches", home: home))
        XCTAssertFalse(PurgeableDocuments.isCloudFolder("/Users/someone/Documents", home: home))
    }

    /// Each block of the page lists what it is made of: the purgeable app files their row with its Free button, the cloud files one
    /// row per cloud folder with where it is (and what no folder accounts for), the update its row. A service that has nothing to add
    /// to its name and size opens nothing, and the tile's blocks, which are saved, carry no items.
    func testEachBlockListsTheItemsItIsMadeOf() {
        var snap = snapshot(measured.merging([CacheDeleteService.fsPurgeableDocument: 30_000_000_000]) { $1 })
        let onedrive = "/h/Library/CloudStorage/OneDrive-Pessoal"
        snap.documents = [PurgeableDocuments.Source(name: "OneDrive (Pessoal)", path: onedrive, bytes: 20_000_000_000, files: 8_000, folders: [])]
        let update = "/System/Volumes/Preboot/X/cryptex1/proposed"
        snap.updates = [PreparedUpdate(name: "macOS 27.2 (26B5101f)", bytes: 10_700_000_000, path: update)]
        let blocks = OtherSystemFilesScreenBuilder.blocksWithItems(snap)
        let files = blocks.first { $0.id == CacheDeleteService.fsPurgeableData }
        XCTAssertEqual(files?.items.map(\.id), [CacheDeleteService.fsPurgeableData])
        XCTAssertEqual(files?.items.first?.actions.map(\.id), ["purgeFiles"])
        let cloud = blocks.first { $0.id == CacheDeleteService.fsPurgeableDocument }
        XCTAssertEqual(cloud?.items.map(\.id), ["documents:\(onedrive)", CacheDeleteService.fsPurgeableDocument])
        XCTAssertEqual(cloud?.items.map(\.paths), [[onedrive], []])
        XCTAssertEqual(cloud?.items.first?.actions.map(\.id), ["removeDownloads"])
        XCTAssertEqual(cloud?.group?.id, "segment:\(CacheDeleteService.fsPurgeableDocument)")
        let waiting = blocks.first { $0.id == "update:\(update)" }
        XCTAssertEqual(waiting?.items.map(\.paths), [[update]])
        XCTAssertEqual(waiting?.items.first?.actions.map(\.id), ["openSoftwareUpdate"])
        XCTAssertNil(blocks.first { $0.id == CacheDeleteService.appContainerCaches }?.group, "nothing to add to the block")
        XCTAssertNil(blocks.first { $0.id == CacheDeleteService.quickLookThumbnails }?.group)
        XCTAssertEqual(blocks.map(\.id), OtherSystemFilesScreenBuilder.segments(snap).map(\.id))
        XCTAssertTrue(OtherSystemFilesScreenBuilder.segments(snap).allSatisfy(\.items.isEmpty))
        guard case let .blocks(tile)? = OtherSystemFilesScreenBuilder.tile(snap).graphic else { return XCTFail() }
        XCTAssertTrue(tile.allSatisfy(\.items.isEmpty))
        XCTAssertEqual(OtherSystemFilesScreenBuilder.screen(snap).hero?.segments, blocks)
    }

    /// macOS's purge of app container caches is one figure here. The caches of third-party apps' containers are listed, and freed, on
    /// System Data's caches page only (one item, one place): the row names no folder and has no button, and its block opens nothing.
    func testContainerCachesAreNotListedAgain() throws {
        let snap = snapshot(measured)
        guard case let .list(kept)? = OtherSystemFilesScreenBuilder.screen(snap).widgets.last else { return XCTFail() }
        let row = try XCTUnwrap(kept.rows.first { $0.id == CacheDeleteService.appContainerCaches })
        XCTAssertTrue(row.paths.isEmpty)
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertTrue(row.children.isEmpty)
        let block = try XCTUnwrap(OtherSystemFilesScreenBuilder.blocksWithItems(snap).first { $0.id == CacheDeleteService.appContainerCaches })
        XCTAssertTrue(block.items.isEmpty)
        XCTAssertNil(block.group)
    }

    /// Purgeable app files too few to free have no row, so their block opens nothing.
    func testABlockWithNothingToListOpensNothing() {
        let blocks = OtherSystemFilesScreenBuilder.blocksWithItems(snapshot([CacheDeleteService.fsPurgeableData: 1_000_000]))
        XCTAssertEqual(blocks.map(\.id), [CacheDeleteService.fsPurgeableData])
        XCTAssertNil(blocks.first?.group)
    }
}

private final class SnapshotReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var total: Int { lock.withLock { count } }
    func waitForRelease(_ release: DispatchSemaphore) { _ = release.wait(timeout: .now() + 5) }
}
