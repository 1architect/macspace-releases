import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class ZoomMathTests: XCTestCase {
    func testRampIsFlatOutsideItsRangeAndMonotonicInside() {
        XCTAssertEqual(ZoomMath.ramp(0, 0.2, 0.7), 0)
        XCTAssertEqual(ZoomMath.ramp(1, 0.2, 0.7), 1)
        XCTAssertEqual(ZoomMath.ramp(0.45, 0.2, 0.7), 0.5, accuracy: 0.0001)
        XCTAssertLessThan(ZoomMath.ramp(0.3, 0.2, 0.7), ZoomMath.ramp(0.5, 0.2, 0.7))
    }

    func testRectInterpolatesFromTileToWindow() {
        let tile = CGRect(x: 100, y: 200, width: 400, height: 300)
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 0), tile)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 1), window)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 0.5), CGRect(x: 50, y: 100, width: 700, height: 500))
    }
}

final class BentoTests: XCTestCase {
    func testLoadingStatusAddsScanProgressWithoutEllipsis() {
        XCTAssertFalse(TileInfo.loadingStatus.contains("…"))
        XCTAssertEqual(TileInfo.loadingStatus(nil), TileInfo.loadingStatus)
        XCTAssertEqual(TileInfo.loadingStatus(0), TileInfo.loadingStatus + " 0%")
        XCTAssertEqual(TileInfo.loadingStatus(0.4), TileInfo.loadingStatus + " 40%")
        XCTAssertEqual(TileInfo.loadingStatus(1), TileInfo.loadingStatus + " 100%")
        XCTAssertEqual(TileInfo.loadingStatus(-1), TileInfo.loadingStatus + " 0%")
        XCTAssertEqual(TileInfo.loadingStatus(2), TileInfo.loadingStatus + " 100%")
        XCTAssertEqual(TileInfo.loadingStatus(.nan), TileInfo.loadingStatus)
    }

    func testCleaningStatusAddsProgressWithoutEllipsis() {
        let progress = ActionProgress(fraction: 0.4, message: "Freeing space")
        XCTAssertEqual(TileInfo.cleaningStatus(progress), "freeing space 40%")
    }

    func testTheSketchedDashboardPacksIntoTwoFullRowsOfThree() {
        // Storage, System Data (wide), Debloat, Siri, Settings.
        let placements = Bento.pack(spans: [1, 2, 1, 1, 1], columns: 3)
        XCTAssertEqual(placements, [
            .init(row: 0, column: 0, span: 1), .init(row: 0, column: 1, span: 2),
            .init(row: 1, column: 0, span: 1), .init(row: 1, column: 1, span: 1), .init(row: 1, column: 2, span: 1),
        ])
        XCTAssertEqual(Bento.rows(placements), 2)
    }

    func testAWideTileThatDoesNotFitMovesDownAndSmallTilesFillTheGap() {
        let placements = Bento.pack(spans: [1, 2, 1, 1, 1], columns: 2)
        XCTAssertEqual(placements, [
            .init(row: 0, column: 0, span: 1), .init(row: 1, column: 0, span: 2),
            .init(row: 0, column: 1, span: 1), .init(row: 2, column: 0, span: 1), .init(row: 2, column: 1, span: 1),
        ])
    }

    func testTheFeaturedModuleTakesTwoByTwoAndSixTilesFillThreeRows() {
        // Storage, the featured module, then the other three modules and Settings.
        let one = Bento.Size(width: 1, height: 1), large = Bento.Size(width: 2, height: 2)
        let placements = Bento.pack(sizes: [one, large, one, one, one, one], columns: 3)
        XCTAssertEqual(placements, [
            .init(row: 0, column: 0, span: 1), .init(row: 0, column: 1, span: 2, height: 2),
            .init(row: 1, column: 0, span: 1), .init(row: 2, column: 0, span: 1),
            .init(row: 2, column: 1, span: 1), .init(row: 2, column: 2, span: 1),
        ])
        XCTAssertEqual(Bento.rows(placements), 3)
        let size = CGSize(width: 314, height: 314)
        XCTAssertEqual(Bento.frame(placements[1], columns: 3, rows: 3, in: size, spacing: 7), CGRect(x: 107, y: 0, width: 207, height: 207))
    }

    func testTheModuleThatCanFreeTheMostIsFeatured() {
        XCTAssertEqual(HomeView.featured([(id: "data", reclaimable: 135_000_000, wide: true), (id: "other", reclaimable: 4_000_000_000, wide: false),
                                          (id: "debloat", reclaimable: nil, wide: false)]), "other")
        XCTAssertEqual(HomeView.featured([(id: "debloat", reclaimable: nil, wide: false), (id: "data", reclaimable: 0, wide: true)]), "data",
                       "with nothing to free, the wide module")
        XCTAssertEqual(HomeView.featured([(id: "debloat", reclaimable: nil, wide: false)]), "debloat")
        XCTAssertNil(HomeView.featured([]))
    }

    func testTheLastTileOfAShortRowStretchesToTheEdge() {
        let placements = Bento.pack(spans: [1, 2, 1, 1], columns: 3)
        XCTAssertEqual(placements[3], .init(row: 1, column: 1, span: 2))
    }

    func testCompactSettingsGivesTheFeaturedTileTheEmptySpace() {
        let one = Bento.Size(width: 1, height: 1), large = Bento.Size(width: 2, height: 2)
        for columns in [2, 3] {
            let placements = Bento.pack(sizes: [one, large, one, one], columns: columns, maximumSizes: [nil, nil, nil, one])
            XCTAssertEqual(placements.last?.span, 1)
            XCTAssertEqual(placements.last?.height, 1)
            if columns == 3 { XCTAssertEqual(placements[1].height, 3) }
        }
    }

    @MainActor
    func testDashboardReflowsTheThreeModuleLayoutAroundCompactSettings() {
        let one = Bento.Size(width: 1, height: 1), large = Bento.Size(width: 2, height: 2)
        let arrangement = HomeView.arrangement(for: CGSize(width: 700, height: 490),
            sizes: [large, one, one, one], maximumSizes: [nil, nil, nil, one], fallbackTile: 3)

        XCTAssertFalse(arrangement.scrolls)
        XCTAssertEqual(arrangement.placements, [
            .init(row: 0, column: 0, span: 2, height: 2),
            .init(row: 0, column: 2, span: 1, height: 2),
            .init(row: 2, column: 0, span: 2),
            .init(row: 2, column: 2, span: 1),
        ])
        assertFullGrid(arrangement.placements, columns: 3)
    }

    func testSettingsCanGrowWhenTheFeaturedTileAndSettingsCannotFillTheGridOtherwise() {
        let one = Bento.Size(width: 1, height: 1), large = Bento.Size(width: 2, height: 2)
        for columns in [2, 3] {
            let placements = Bento.pack(sizes: [large, one], columns: columns, maximumSizes: [nil, one], fallbackTile: 1)
            XCTAssertEqual(placements[0], .init(row: 0, column: 0, span: 2, height: 2))
            XCTAssertEqual(placements[1], columns == 2 ? .init(row: 2, column: 0, span: 2) : .init(row: 0, column: 2, span: 1, height: 2))
            assertFullGrid(placements, columns: columns)
        }
    }

    @MainActor
    func testNarrowDashboardReordersConstrainedTilesBeforeGrowingSettings() {
        let one = Bento.Size(width: 1, height: 1), large = Bento.Size(width: 2, height: 2)
        let arrangement = HomeView.arrangement(for: CGSize(width: 490, height: 350),
            sizes: [one, large, one, one], maximumSizes: [one, nil, nil, one], fallbackTile: 3)
        XCTAssertEqual(arrangement.columns, 2)
        XCTAssertTrue(arrangement.scrolls)
        XCTAssertEqual(arrangement.placements[0].span, 1)
        XCTAssertEqual(arrangement.placements[0].height, 1)
        XCTAssertEqual(arrangement.placements[1].span, 2)
        XCTAssertEqual(arrangement.placements[1].height, 2)
        XCTAssertEqual(arrangement.placements[3].span, 1)
        XCTAssertEqual(arrangement.placements[3].height, 1)
        assertFullGrid(arrangement.placements, columns: 2)
    }

    func testEnabledModulesAndTheirPreferencesAlwaysFillTheHomeGrid() {
        let one = Bento.Size(width: 1, height: 1), large = Bento.Size(width: 2, height: 2)
        let limits: [Bento.Size?] = [nil, one, .init(width: 1, height: 2), .init(width: 2, height: 1)]
        for columns in [2, 3] {
            // Every count of built-in modules, with and without a leading disk tile and all combinations of these size limits.
            for count in 0...5 {
                let features: [Int?] = [nil] + (0..<min(count, 2)).map(Optional.some)
                for feature in features {
                    for combination in 0..<(1 << (2 * count)) {
                        var sizes = Array(repeating: one, count: count + 1)
                        var maximums = (0..<count).map { limits[(combination >> (2 * $0)) & 3] } + [one]
                        if let feature { sizes[feature] = large; maximums[feature] = nil }
                        let strict = Bento.pack(sizes: sizes, columns: columns, maximumSizes: maximums)
                        let placements = Bento.pack(sizes: sizes, columns: columns, maximumSizes: maximums, fallbackTile: count)

                        XCTAssertEqual(placements.count, sizes.count)
                        assertFullGrid(placements, columns: columns)
                        XCTAssertLessThanOrEqual(Bento.rows(placements), Bento.rows(strict))
                        for (placement, maximum) in zip(placements.dropLast(), maximums.dropLast()) {
                            if let maximum {
                                XCTAssertLessThanOrEqual(placement.span, maximum.width)
                                XCTAssertLessThanOrEqual(placement.height, maximum.height)
                            }
                        }
                        if strict.reduce(0, { $0 + $1.span * $1.height }) == Bento.rows(strict) * columns {
                            XCTAssertEqual(placements, strict)
                            XCTAssertEqual(placements.last?.span, 1)
                            XCTAssertEqual(placements.last?.height, 1)
                        }
                    }
                }
            }
        }
    }

    private func assertFullGrid(_ placements: [Bento.Placement], columns: Int, file: StaticString = #filePath, line: UInt = #line) {
        var occupied = Set<Int>()
        for placement in placements {
            XCTAssertGreaterThanOrEqual(placement.column, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(placement.column + placement.span, columns, file: file, line: line)
            for row in placement.row..<(placement.row + placement.height) {
                for column in placement.column..<(placement.column + placement.span) {
                    XCTAssertTrue(occupied.insert(row * columns + column).inserted, "Tiles overlap", file: file, line: line)
                }
            }
        }
        XCTAssertEqual(occupied, Set(0..<(Bento.rows(placements) * columns)), "Grid has uncovered cells", file: file, line: line)
    }

    func testFramesShareTheSpaceWithTheSpacingBetween() {
        let size = CGSize(width: 314, height: 214)
        XCTAssertEqual(Bento.frame(.init(row: 0, column: 0, span: 1), columns: 3, rows: 2, in: size, spacing: 7), CGRect(x: 0, y: 0, width: 100, height: 103.5))
        XCTAssertEqual(Bento.frame(.init(row: 1, column: 1, span: 2), columns: 3, rows: 2, in: size, spacing: 7), CGRect(x: 107, y: 110.5, width: 207, height: 103.5))
    }
}
