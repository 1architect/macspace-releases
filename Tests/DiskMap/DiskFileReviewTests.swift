import Darwin
import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskFileReviewTests: DiskSecurityFixtureCase {
    private struct Options: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct Permissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    private var context: ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "test", symbol: "internaldrive"),
            options: Options(), permissions: Permissions())
    }
    private func rows(_ screen: Screen) -> [Row] {
        screen.widgets.flatMap { if case let .list(list) = $0 { return list.rows }; return [] }
    }

    func testReviewKeepsAllSelectedFilesAcrossPagesAndCheckboxEditsWithoutDeleting() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Keep Spotlight from opening fixture files while the selection checks live readers.
        let base = home.appendingPathComponent("Downloads/macspace-review-" + UUID().uuidString + ".noindex")
        let root = base.appendingPathComponent("files"), cache = base.appendingPathComponent("cache/index")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for n in 0..<205 {
            try Data(repeating: UInt8(n % 251), count: 4096).write(to: root.appendingPathComponent(String(format: "%03d.txt", n)))
        }
        let store = DiskStore(root: root.path, cache: cache)
        let module = DiskMapModule(store: store, inventory: DiskInventory(loader: { _, _ in
            XCTFail("File review must not discover apps")
            return DiskApplications()
        }))
        _ = await store.view()
        var scope = DiskBrowseRequest(folder: root.path, kind: .category, category: .documents)
        scope.includeSmaller = true
        let bulk = try await store.selection(.init(operation: "toggleAll", scopePageID: "select:" + scope.pageID))
        XCTAssertEqual(bulk.count, 205)
        let request = ActionPageRequest(destination: DiskFileReview.destination, parameters: ["selectionToken": bulk.token])
        let loaded = await module.page(id: request.pageID, context: context)
        let page = try XCTUnwrap(loaded), selection = try XCTUnwrap(page.selection)
        let files = rows(page).filter { $0.pageID == nil }
        XCTAssertEqual(files.count, 200)
        XCTAssertEqual(selection.bulk?.count, 205)
        XCTAssertEqual(selection.bulk?.bytes, bulk.bytes)
        XCTAssertEqual(selection.scope, "disk-files")
        XCTAssertEqual(selection.bulkResolver, "selection:")
        XCTAssertEqual(selection.action.id, "freeFiles")
        XCTAssertNil(selection.action.pageID)
        XCTAssertNotNil(selection.action.confirmation)
        XCTAssertEqual(selection.action.requires, [.fullDiskAccess])
        XCTAssertEqual(files.first?.subtitle, root.appendingPathComponent("000.txt").path)
        XCTAssertTrue(files.allSatisfy { $0.contextActions?.delete == nil })

        // More than two edits would normally expire the initial immutable token.
        var edited = bulk
        for row in files.prefix(4) {
            edited = try await store.selection(.init(token: edited.token, operation: "toggle", toggledID: row.id,
                reviewed: selection.reviewed, visible: files.map(\.id)))
        }
        XCTAssertEqual(edited.count, 201)
        let nextID = try XCTUnwrap(rows(page).first(where: { $0.pageID != nil })?.pageID)
        let next = await module.page(id: nextID, context: context)
        let nextPage = try XCTUnwrap(next)
        XCTAssertEqual(rows(nextPage).count, 5)
        XCTAssertNil(rows(nextPage).last?.pageID)
        let membership = try await store.selection(.init(token: edited.token, operation: "membership", visible: rows(nextPage).map(\.id)))
        XCTAssertEqual(membership.count, 201)
        XCTAssertEqual(membership.checked.count, 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 205,
            "Opening review, paging and editing checkboxes must not remove any file")

        let invalid = await module.page(id: ActionPageRequest(destination: DiskFileReview.destination,
            parameters: ["selectionToken": "expired"]).pageID, context: context)
        XCTAssertNil(invalid?.selection)
        XCTAssertNil(invalid?.primary)
        await store.setActive(false)
    }

    func testSingleFileReviewPreservesIdentityAndRejectsChangedFile() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Downloads/macspace-single-review-" + UUID().uuidString + ".noindex")
        let root = base.appendingPathComponent("files"), target = root.appendingPathComponent("100% file.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data([1]).write(to: target)
        let store = DiskStore(root: root.path, cache: base.appendingPathComponent("cache/index"))
        let module = DiskMapModule(store: store)
        _ = await store.view()
        let file = DiskFile(path: target.path, bytes: 4096, logicalBytes: 1, ownerUID: getuid(), identity: FileReviewIdentity(target.path))
        let original = try XCTUnwrap(DiskMapScreenBuilder.fileContextActions(file, selection: DiskMapScreenBuilder.fileSelection([file], open: [:])).delete)
        let pageID = ActionPageRequest(destination: try XCTUnwrap(original.pageID), parameters: original.parameters).pageID
        let loaded = await module.page(id: pageID, context: context)
        let page = try XCTUnwrap(loaded), selection = try XCTUnwrap(page.selection)
        XCTAssertEqual(selection.checked, [DiskFileRemoval.id(target.path)])
        XCTAssertEqual(selection.action.id, "deleteGraphFile")
        XCTAssertEqual(selection.action.parameters["reviewed"], original.parameters["reviewed"])
        XCTAssertEqual(selection.action.parameters["id"], original.parameters["id"])
        XCTAssertFalse(selection.action.confirmation?.message.contains(target.path) == true)
        XCTAssertNil(selection.action.pageID)
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))

        try Data([2, 3]).write(to: target)
        let stale = await module.page(id: pageID, context: context)
        XCTAssertNil(stale?.selection)
        XCTAssertNil(stale?.primary)
        await store.setActive(false)
    }

    func testFinalActionMatchesTheConfiguredRemovalMode() {
        let trash = FileRemovalSettings.movesToTrash()
        let action = DiskFileReview.removalAction()
        XCTAssertEqual(action.title, trash ? "Move to Trash" : "Delete")
        XCTAssertEqual(action.parameters["trash"], trash ? "1" : "0")
        XCTAssertEqual(action.confirmation?.confirmTitle, action.title)
        XCTAssertEqual(action.role, .destructive)
        XCTAssertEqual(action.requires, [.fullDiskAccess])
    }
}
