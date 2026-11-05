import AppKit
import MacSpaceSdk
import XCTest
@testable import MacSpaceApp

final class ModuleOverviewTests: XCTestCase {
    func testReflowPreservesControlledListHeadingAndCascadeMetadataAtEveryWidth() {
        let group = Row(id: "category", title: "Other app data", children: [Row(id: "data", title: "Data")])
        let list = ListWidget(id: "app-data", title: "AutoCAD app data", rows: [group], visibleWhenSelected: "app",
                              headingChoice: "app", headingIconPath: "/Applications/AutoCAD.app", cascadesOnAppear: true)
        for width in [350.0, 520, 820] {
            let source = [ScreenWidget.list(list)]
            let reflowed = ModulePagePresentation.items(source, width: width, expandsGroups: true).flatMap(\.widgets)
            XCTAssertEqual(reflowed, source)
            XCTAssertEqual(ModulePagePresentation.visibleWidgets(source, checked: []), source,
                           "The app heading must stay mounted when its body is untoggled")
        }
    }

    func testDetailNeverLosesUnsectionedOrPreservedRowsOrDuplicatesSectionRows() {
        let eligible = Row(id: "cache", title: "Cache", paths: ["/cache"])
        let preserved = Row(id: "external", title: "Other app data", paths: ["/Library/Support"], unavailableReason: "Preserved")
        let selection = Selection(action: Action(id: "uninstall", title: "Uninstall"), choices: ["cache": 100],
            sections: [.init(id: "unrelated", title: "Other app", rows: ["different"]),
                       .init(id: "caches", title: "Caches", rows: ["cache", "cache"])])
        func detailRows(_ group: Row) -> [Row] {
            ModulePagePresentation.groupWidgets(group).flatMap { widget in
                if case let .list(list) = widget { return list.rows }; return []
            }
        }
        XCTAssertEqual(detailRows(Row(id: "g", title: "Data", children: [eligible, preserved], selection: selection)), [eligible, preserved])
        XCTAssertEqual(detailRows(Row(id: "read-only", title: "Other app data", children: [preserved], selection: selection)), [preserved],
                       "A category with only preserved data must still show its inventory")
    }
    func testOverviewExpandsSmallGroupsWithoutLosingActionsOrPaths() {
        let leaf = Row(id: "a", title: "A", trailing: "1 GB", badges: [Badge("Open now", .info)],
                       actions: [Action(id: "free", title: "Free")], paths: ["/tmp/a"])
        let group = Row.group(id: "g", title: "Apps", totalBytes: 1_000, rows: [leaf])
        let items = ModulePagePresentation.items([.list(ListWidget(id: "list", rows: [group]))], width: 520, expandsGroups: true)
        XCTAssertEqual(items.count, 1)
        guard case let .section(section) = items[0].widgets[0], case let .list(list) = section.widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows, [leaf])
    }

    func testCacheSelectionsStayOnTheirOwnPageAtEveryWidth() {
        var group = Row.group(id: "caches", title: "Caches", totalBytes: 10, rows: [Row(id: "a", title: "A"), Row(id: "b", title: "B")])
        group.selection = Selection(action: Action(id: "free", title: "Free selected"), choices: ["a": 4, "b": 6],
                                    checked: ["a"], sections: [SelectionSection(id: "recommended", title: "Recommended", rows: ["a"]),
                                                              SelectionSection(id: "developer", title: "Developer", rows: ["b"])],
                                    save: Action(id: "save", title: "Save"))
        for width in [350.0, 520, 820] {
            let items = ModulePagePresentation.items([.list(ListWidget(id: "list", rows: [group]))], width: width, expandsGroups: true)
            XCTAssertEqual(items.count, 1)
            XCTAssertNil(items[0].selectionGroup)
            guard case let .list(list) = items[0].widgets[0] else { return XCTFail() }
            XCTAssertEqual(list.rows, [group], "Cache entry still opens its selection page")
            XCTAssertEqual(ModulePagePresentation.groupWidgets(group).map(\.id), ["group-section:recommended", "group-section:developer"])
        }
    }

    func testActionablePriorityWinsRegardlessOfSourceOrderAndPreservesTheWholeGroup() throws {
        let normal = ScreenWidget.list(ListWidget(id: "normal", rows: [Row(id: "n", title: "N")]))
        let free = ScreenWidget.section(SectionWidget(id: "free", title: "Localized free title", widgets: [normal], priority: .actionable))
        let next = ScreenWidget.list(ListWidget(id: "next", rows: []))
        for expands in [false, true] {
            let items = ModulePagePresentation.items([normal, next, free], width: 520, expandsGroups: expands)
            XCTAssertEqual(items.first?.id, "free")
            XCTAssertEqual(items.first?.widgets, [free])
            XCTAssertTrue(items[1].id.contains("normal"))
            XCTAssertTrue(items[2].id.contains("next"))
        }
        XCTAssertEqual(try JSONDecoder().decode(ScreenWidget.self, from: JSONEncoder().encode(free)), free)
        let legacy = try JSONDecoder().decode(SectionWidget.self, from: Data(#"{"id":"old","title":"Old","widgets":[],"isCollapsible":false,"startsCollapsed":false}"#.utf8))
        XCTAssertNil(legacy.priority)
    }

    func testNarrowOverviewKeepsLargeGroupsNavigableAndDrillDownDoesNotExpandAgain() {
        let group = Row.group(id: "g", title: "Apps", totalBytes: 10, rows: (0..<12).map { Row(id: "\($0)", title: "Item \($0)") })
        let source: [ScreenWidget] = [.list(ListWidget(id: "list", rows: [group]))]
        let compact = ModulePagePresentation.items(source, width: 350, expandsGroups: true)
        guard case let .list(list) = compact[0].widgets[0] else { return XCTFail() }
        XCTAssertEqual(list.rows, [group])
        XCTAssertEqual(ModulePagePresentation.items(source, width: 820, expandsGroups: false)[0].widgets, source)
    }

    func testNativeTilingMatchesEverySideAndQuarterOnOffsetDisplays() {
        let screen = CGRect(x: -1800, y: 90, width: 1800, height: 1100)
        for margin: CGFloat in [0, 8, 16] {
            let area = screen.insetBy(dx: margin, dy: margin)
            let w = (area.width - margin) / 2, h = (area.height - margin) / 2
            XCTAssertTrue(WindowCornerStyle.isAttached(frame: area, visible: screen))
            for x in [area.minX, area.maxX - w] {
                XCTAssertTrue(WindowCornerStyle.isAttached(frame: CGRect(x: x, y: area.minY, width: w, height: area.height), visible: screen))
                for y in [area.minY, area.maxY - h] {
                    XCTAssertTrue(WindowCornerStyle.isAttached(frame: CGRect(x: x, y: y, width: w, height: h), visible: screen))
                }
            }
            for y in [area.minY, area.maxY - h] {
                XCTAssertTrue(WindowCornerStyle.isAttached(frame: CGRect(x: area.minX, y: y, width: area.width, height: h), visible: screen))
            }
        }
        XCTAssertFalse(WindowCornerStyle.isAttached(frame: CGRect(x: -1800, y: 90, width: 700, height: 490), visible: screen))
        XCTAssertTrue(WindowCornerStyle.isAttached(frame: screen, visible: screen, fullScreen: true))
        XCTAssertEqual(WindowCornerStyle(attached: true).tileRadius, 10)
        XCTAssertEqual(WindowCornerStyle(attached: true, fullScreen: true).windowRadius, 0)
    }

    func testLayoutContractDecodesOlderScreensAndRoundTripsSingleColumn() throws {
        let old = try JSONDecoder().decode(Screen.self, from: Data(#"{"title":"Old","widgets":[]}"#.utf8))
        XCTAssertNil(old.layout)
        let screen = Screen(title: "Switches", layout: .singleColumn, widgets: [])
        XCTAssertEqual(try JSONDecoder().decode(Screen.self, from: JSONEncoder().encode(screen)), screen)
    }
}

extension ModuleOverviewTests {
    func testExpandedAndDrilldownHeadingsNeverPromoteRowQuantities() throws {
        let child = Row(id: "managed", title: "Managed by macOS", subtitle: "19 items", trailing: "12 GB")
        var group = Row.group(id: "everything", title: "Everything else", totalBytes: 19_350_000_000, rows: [child])
        group.subtitle = "31 items"
        for width in [350.0, 520, 820] {
            let items = ModulePagePresentation.items([.list(.init(id: "overview", rows: [group]))], width: width, expandsGroups: true)
            guard case let .section(section) = try XCTUnwrap(items.first?.widgets.first),
                  case let .list(list) = try XCTUnwrap(section.widgets.first) else { return XCTFail() }
            XCTAssertEqual(section.title, "Everything else")
            XCTAssertEqual(list.rows, [child], "Measurements remain on individual rows")
        }
        guard case let .section(section) = try XCTUnwrap(ModulePagePresentation.groupWidgets(group).first) else { return XCTFail() }
        XCTAssertEqual(section.title, "Everything else")
    }
}
