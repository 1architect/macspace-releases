import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceApp

private struct AppReviewModule: MacSpaceModule {
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Apps", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        let selection = Selection(action: Action(id: "uninstallSelected", title: "Uninstall", parameters: ["plans": "frozen"],
            confirmation: Confirmation(title: "Uninstall?", message: "Uninstalls Alpha and Beta", confirmTitle: "Uninstall")),
            choices: ["cacheA": 5_000_000, "cacheB": 2_000_000, "supportA": 10_000_000],
            checked: ["cacheA", "cacheB"],
            sections: [.init(id: "cacheSectionA", title: "Caches", rows: ["cacheA"]),
                       .init(id: "supportSectionA", title: "Support", rows: ["supportA"]),
                       .init(id: "allA", title: "Alpha app data", rows: ["cacheA", "supportA"]),
                       .init(id: "allB", title: "Beta app data", rows: ["cacheB"])],
            scope: "review", includedBytes: 180_000_000)
        let category = Row(id: "categoryA", title: "Data", children: [Row(id: "cacheA", title: "Cache"), Row(id: "supportA", title: "Support")],
                           selection: selection, selectionSectionID: "allA")
        return Screen(title: "Review", widgets: [
            .list(.init(id: "dataA", title: "Alpha app data", rows: [category], headingChoice: "allA", headingIconPath: "/A.app", cascadesOnAppear: true)),
            .list(.init(id: "dataB", title: "Beta app data", rows: [Row(id: "cacheB", title: "Cache")], headingChoice: "allB", headingIconPath: "/B.app", cascadesOnAppear: true))
        ], selection: selection)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .succeeded("") }
}

@MainActor
final class UninstallReviewSelectionTests: XCTestCase {
    func testPreservedSectionsHaveReasonsWhileMixedSectionsAllowSelectingEligibleItems() {
        let selection = Selection(action: Action(id: "uninstall", title: "Uninstall"), choices: ["cache": 100], sections: [
            .init(id: "shared", title: "Shared", rows: ["shared-data"], unavailableReason: "Used by other apps"),
            .init(id: "master", title: "App data", rows: ["cache", "shared-data"]),
            .init(id: "unavailable", title: "Unavailable", rows: ["missing"])
        ])
        let choice = SectionChoice(selection: selection, checked: [], all: []) { _ in }
        XCTAssertFalse(choice.hasRows("shared"))
        XCTAssertEqual(choice.unavailableReason("shared"), "Used by other apps")
        XCTAssertTrue(choice.hasRows("master"))
        XCTAssertFalse(choice.hasRows("unavailable"), "An inventory row alone must not produce a nonfunctional checkbox")
    }
    private func handle() async throws -> (ModuleHandle, URL) {
        let directory = try Fixtures.temporaryDirectory()
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Review", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in AppReviewModule() })
        await handle.activate()
        return (handle, directory)
    }

    private func action(_ handle: ModuleHandle) throws -> Action {
        guard case let .idle(action)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else {
            throw NSError(domain: "Missing uninstall action", code: 1)
        }
        return action
    }

    private func heading(_ handle: ModuleHandle) throws -> SectionChoice {
        let group = try XCTUnwrap(handle.activeSelection)
        return SectionChoice(selection: try XCTUnwrap(group.selection), checked: handle.checked(group), all: handle.allChecked(group)) { id in
            handle.toggleAll(id, in: group)
        }
    }

    func testHeadingSelectsAndClearsOnlyItsDataWhileAllAppsRemainIncluded() async throws {
        let (handle, directory) = try await handle()
        defer { handle.deactivate(); try? FileManager.default.removeItem(at: directory) }
        let root = try XCTUnwrap(handle.activeSelection)
        XCTAssertEqual(try action(handle).title, "Uninstall " + ByteFormat.string(187_000_000))
        XCTAssertTrue(try heading(handle).isMixed("allA"))
        handle.toggleAll("allA", in: root)
        XCTAssertEqual(handle.checked(root), ["cacheA", "supportA", "cacheB"])
        XCTAssertTrue(try heading(handle).isOn("allA"))
        XCTAssertEqual(try action(handle).title, "Uninstall " + ByteFormat.string(197_000_000))
        handle.toggleAll("allA", in: root)
        XCTAssertEqual(handle.checked(root), ["cacheB"])
        XCTAssertFalse(try heading(handle).isOn("allA"))
        XCTAssertEqual(try action(handle).title, "Uninstall " + ByteFormat.string(182_000_000))
        handle.toggleAll("allB", in: root)
        XCTAssertTrue(handle.checked(root).isEmpty)
        XCTAssertEqual(try action(handle).title, "Uninstall " + ByteFormat.string(180_000_000))
        XCTAssertEqual(try action(handle).parameters["plans"], "frozen")
        XCTAssertTrue(Selection.ids(try action(handle).parameters["ids"]).isEmpty)
        XCTAssertEqual(try action(handle).confirmation?.message, "Uninstalls Alpha and Beta")
        let source = try XCTUnwrap(handle.screen).widgets
        XCTAssertEqual(ModulePagePresentation.visibleWidgets(source, checked: []), source)
        XCTAssertEqual(ModulePagePresentation.items(source, width: 520, expandsGroups: true).flatMap(\.widgets), source)
    }

    func testCategoryAndDetailEditsKeepMasterStateCorrectAndNeverChangeAppInclusion() async throws {
        let (handle, directory) = try await handle()
        defer { handle.deactivate(); try? FileManager.default.removeItem(at: directory) }
        let root = try XCTUnwrap(handle.activeSelection)
        handle.toggleAll("allA", in: root)
        handle.pushGroup("categoryA")
        handle.toggle("supportA", in: try XCTUnwrap(handle.activeSelection))
        handle.popGroup()
        XCTAssertTrue(try heading(handle).isMixed("allA"))
        handle.toggleAll("allA", in: root)
        XCTAssertEqual(try action(handle).title, "Uninstall " + ByteFormat.string(197_000_000))
        handle.toggleAll("cacheSectionA", in: root)
        XCTAssertEqual(handle.checked(root), ["supportA", "cacheB"])
        XCTAssertTrue(try heading(handle).isMixed("allA"))
        XCTAssertFalse(handle.allChecked(root).contains("allA"), "A nested category must clear the master all-on flag")
        handle.toggleAll("allA", in: root)
        XCTAssertEqual(handle.checked(root), ["cacheA", "supportA", "cacheB"], "Clicking a mixed master must select all again")
        XCTAssertEqual(try action(handle).parameters["plans"], "frozen")
    }

    func testInUseMatchingIncludesEmbeddedAppsAndDistinguishesCopies() {
        XCTAssertTrue(RunningApplications.contains("/Applications/Example.app", paths: ["/Applications/Example.app/Contents/Helpers/Helper.app"]))
        XCTAssertFalse(RunningApplications.contains("/Applications/Example.app", paths: ["/Other/Example.app", "/Applications/Example.app Copy"]))
    }
}
