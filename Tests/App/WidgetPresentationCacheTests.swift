import MacSpaceSdk
import XCTest
@testable import MacSpaceApp

@MainActor
final class WidgetPresentationCacheTests: XCTestCase {
    func testProgressReusesProjectionAndContentSelectionWidthAndFittingInvalidateIt() {
        let cache = WidgetPresentationCache()
        var widgets: [ScreenWidget] = [
            .list(ListWidget(id: "base", rows: [Row(id: "one", title: "One")])),
            .list(ListWidget(id: "conditional", rows: [Row(id: "two", title: "Two")], visibleWhenSelected: "one"))
        ]
        var fitting = WidgetPresentationCache.Fitting(height: 730, rowTops: [:], scrollTop: 0, bottomRoom: 20)
        func read(checked: Set<String> = [], width: Double = 520) -> WidgetPresentationCache.Value {
            cache.value(widgets: widgets, checked: checked, width: width, expandsGroups: true, fitting: fitting, fit: { $0 })
        }
        XCTAssertFalse(read().ids.contains("two"))
        for _ in 0..<100 { _ = read() }
        XCTAssertEqual(cache.computations, 1)
        XCTAssertTrue(read(checked: ["one"]).ids.contains("two"))
        XCTAssertEqual(cache.computations, 2)
        _ = read(checked: ["one"], width: 350)
        XCTAssertEqual(cache.computations, 3)
        widgets[0] = .list(ListWidget(id: "base", rows: [Row(id: "replacement", title: "New")]))
        XCTAssertTrue(read(checked: ["one"], width: 350).ids.contains("replacement"))
        fitting.height = 500
        _ = read(checked: ["one"], width: 350)
        XCTAssertEqual(cache.computations, 5)
    }
}
