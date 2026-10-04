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
}
