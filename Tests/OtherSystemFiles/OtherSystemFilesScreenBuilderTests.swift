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
        XCTAssertEqual(kept.rows.map(\.id), ["group:kept"], "what macOS keeps is one group")
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
        XCTAssertNil(removed, "and is believed from then on")
    }

    func testTheTileMarksWhatCanBeFreed() {
        let tile = OtherSystemFilesScreenBuilder.tile(snapshot(measured))
        XCTAssertEqual(tile.status, "up to \(ByteFormat.string(4_888_453_120)) can be freed")
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
    /// onto its folders, never a page inside the group's page; what no cloud folder accounts for keeps a row of its own.
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
        XCTAssertEqual(row.badge?.text, "Removing · 25%, 9 GB")
        XCTAssertTrue(row.actions.isEmpty, "no second removal while one runs")
        let tile = OtherSystemFilesScreenBuilder.tile(snap)
        XCTAssertEqual(tile.refreshAfter, 3)
        XCTAssertEqual(tile.status, "removing downloads · 25%")
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
        XCTAssertEqual(OtherSystemFilesScreenBuilder.tile(snap).title, "other system files 11,7 GB")
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
}
