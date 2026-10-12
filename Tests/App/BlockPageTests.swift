import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class BlockPageTests: XCTestCase {
    private let item = Row(id: "appcache:Safari", title: "Safari", trailing: "300 MB")

    /// A block that lists its items opens as a group page does: found by the same lookup the page stack and the title use.
    func testABlocksPageIsFoundLikeAGroupRow() {
        let hero = UsageBar(id: "usage", title: "", segments: [UsageSegment(id: "caches", label: "Caches", bytes: 300_000_000, tone: .series(0), items: [item]),
                                                               UsageSegment(id: "unidentified", label: "Not identified", bytes: 1, tone: .neutral)])
        let screen = Screen(title: "System Data", hero: hero, widgets: [])
        let page = ScreenView.row("segment:caches", in: screen)
        XCTAssertEqual(page?.title, "Caches")
        XCTAssertEqual(page?.children, [item])
        XCTAssertNil(ScreenView.row("segment:unidentified", in: screen), "a block without items opens nothing")
    }

    /// Tiles saved before blocks listed their items still load.
    func testASegmentSavedWithoutItemsDecodes() throws {
        let json = #"{"id":"caches","label":"Caches","bytes":5,"tone":{"neutral":{}}}"#
        let segment = try JSONDecoder().decode(UsageSegment.self, from: Data(json.utf8))
        XCTAssertEqual(segment.items, [])
        XCTAssertNil(segment.group)
    }
}
