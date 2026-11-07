import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskFileSelectionTests: DiskSecurityFixtureCase {
    func testSelectionUsesAllocatedSizesAndScopeWithoutIndividualInfoOrActions() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var index = DiskIndex(root: home)
        let path = home + "/Downloads/macspace-selection-" + UUID().uuidString + "\npart.mov"
        try FileManager.default.createDirectory(atPath: DiskDatabase.parent(path), withIntermediateDirectories: true)
        try Data([65]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owned = DiskFile(path: path, bytes: 4096, logicalBytes: 200_000_000, ownerUID: getuid(), identity: FileReviewIdentity(path))
        let protected = DiskFile(path: home + "/other.mov", bytes: 8192, logicalBytes: 300_000_000, ownerUID: getuid() + 1)
        index.directories[home] = DiskDirectory(path: home, files: [owned, protected], bytes: 12288)
        let root = DiskMapScreenBuilder.screen(index, apps: DiskApplications())
        let request = DiskBrowseRequest(folder: home, kind: .category, category: .largeFiles)
        let all = DiskMapScreenBuilder.browsePage(.init(request: request, files: [owned, protected], next: nil, ownership: [:]))
        XCTAssertEqual(root.selection?.scope, "disk-files")
        let selection = try XCTUnwrap(all.selection)
        XCTAssertEqual(selection.scope, "disk-files")
        XCTAssertTrue(selection.session)
        XCTAssertEqual(selection.bulkResolver, "selection:")
        XCTAssertEqual(selection.choices, [DiskMapScreenBuilder.fileID(owned.path): 4096])
        XCTAssertTrue(selection.checked.isEmpty)
        XCTAssertEqual(selection.action.id, "reviewFiles")
        XCTAssertEqual(selection.action.pageID, DiskFileReview.destination)
        XCTAssertNil(selection.action.confirmation)
        XCTAssertTrue(selection.action.requires.isEmpty)
        XCTAssertEqual(Selection.ids(Selection.parameter(Array(selection.choices.keys))), Array(selection.choices.keys))
        for file in [owned, protected] {
            let row = DiskMapScreenBuilder.fileRow(file)
            XCTAssertNil(row.detail); XCTAssertTrue(row.actions.isEmpty)
            XCTAssertEqual(row.paths, [file.path])
        }
        XCTAssertEqual(try JSONDecoder().decode(Screen.self, from: JSONEncoder().encode(root)), root)
    }

    func testBatchValidatesAllIDsBeforeMutationAndReportsPartialFailure() throws {
        var index = DiskIndex(root: "/fixture")
        let files = ["one", "two", "three"].map { DiskFile(path: "/fixture/A/" + $0, bytes: 4096, logicalBytes: 200_000_000) }
        index.directories[index.root] = DiskDirectory(path: index.root, folders: ["/fixture/A", "/fixture/AB"])
        index.directories["/fixture/A"] = DiskDirectory(path: "/fixture/A", files: files)
        index.directories["/fixture/AB"] = DiskDirectory(path: "/fixture/AB", files: [DiskFile(path: "/fixture/AB/other", bytes: 4096, logicalBytes: 200_000_000)])
        var removed: [String] = []
        XCTAssertNil(DiskFileRemoval.execute(ids: [DiskMapScreenBuilder.fileID(files[0].path), "forged"], folder: "/fixture/A", index: index, eligible: { _ in true }, remove: { removed.append($0) }))
        XCTAssertNil(DiskFileRemoval.execute(ids: [DiskMapScreenBuilder.fileID("/fixture/AB/other")], folder: "/fixture/A", index: index, eligible: { _ in true }, remove: { removed.append($0) }))
        XCTAssertTrue(removed.isEmpty)
        let result = try XCTUnwrap(DiskFileRemoval.execute(ids: Set(files.prefix(2).map { DiskMapScreenBuilder.fileID($0.path) }), folder: "/fixture/A", index: index, eligible: { $0 != files[1].path }, remove: { removed.append($0) }))
        XCTAssertEqual(removed, [files[0].path])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.removedBytes, files[0].bytes, "Only successfully removed targets contribute to the completion total")
        XCTAssertEqual(Set(result.targets), Set(files.prefix(2).map(\.path)))
        XCTAssertFalse(removed.contains(files[2].path))
    }

    func testNavigationDoesNotConsumeDirtyEventsOrWaitForReconciliation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("file")
        try Data(repeating: 1, count: 4096).write(to: target)
        let store = DiskStore(root: root.path, cache: root.appendingPathComponent("cache/index.scan"))
        let initial = await store.snapshot()
        try Data(repeating: 1, count: 131072).write(to: target)
        await store.mark([target.path])
        let start = Date()
        for _ in 0..<100 { let view = await store.navigation(); XCTAssertEqual(view.index.revision, initial.revision) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.2)
        let updated = await store.snapshot()
        XCTAssertGreaterThan(updated.directories[root.path]!.bytes, initial.directories[root.path]!.bytes)
        print("DISK_NAVIGATION_BENCHMARK cachedOpens=100 seconds=\(elapsed)")
        await store.flushPersistence()
    }
    func testMeasuredOwnershipReferencesSurvivePersistenceAndTargetedReread() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Applications/Test.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try (["CFBundleIdentifier": "org.fixture.test", "CFBundleName": "Test"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        let owner = try XCTUnwrap(AppOwner(path: app.path))
        let claims = OwnershipResolver(catalog: AppCatalog(owners: [owner])).claims(for: owner, home: root.path, systemLibrary: root.path + "/Library")
        var catalog = DiskApplications()
        catalog.apps = [DiskApplication(owner: owner, bytes: 0, dataPaths: [], removable: true, metadataStamp: nil, classification: .installedUser, ownership: claims)]
        let cache = root.appendingPathComponent("cache/index.scan"), store = DiskStore(root: root.path, cache: cache)
        _ = await store.snapshot()
        await store.recordOwnership(catalog)
        await store.flushPersistence()
        let restoredDatabase = try DiskDatabase(url: cache.appendingPathExtension("sqlite"), root: root.path)
        let restored = try restoredDatabase.snapshot(folder: contents.path, inventory: false).index
        let id = try XCTUnwrap(restored.directories[contents.path]?.ownershipID)
        XCTAssertEqual(restored.directories[contents.path]?.ownerUID, getuid())
        XCTAssertEqual(restored.ownershipClaims?[id]?.ownerPaths, [app.path])
        try Data(repeating: 1, count: 8192).write(to: contents.appendingPathComponent("new"))
        await store.mark([contents.appendingPathComponent("new").path])
        _ = await store.snapshot()
        let updated = await store.navigation(folder: contents.path).index
        XCTAssertEqual(updated.directories[contents.path]?.ownershipID, id)
        XCTAssertEqual(updated.ownershipClaims?[id]?.confidence, .verifiedExclusive)
        await store.flushPersistence()
    }

    func testAppInventoryBrowseCompletesMetadataBeforePublishingReady() async throws {
        let inventory = DiskInventory(loader: { index, _ in
            Thread.sleep(forTimeInterval: 0.15)
            var apps = DiskApplications(); apps.catalogReadAt = Date(); apps.catalogRevision = index.catalogRevision
            return apps
        })
        let index = DiskIndex(root: "/fixture")
        let started = Date()
        let first = await inventory.browsing(index, ready: { _ in })
        XCTAssertNotEqual(first.catalogReadAt, .distantPast)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
        let loaded = await inventory.read(index)
        XCTAssertNotEqual(loaded.catalogReadAt, .distantPast)
        let current = await inventory.browsing(index, ready: { _ in })
        XCTAssertEqual(current.catalogReadAt, loaded.catalogReadAt)
    }

}

extension DiskFileSelectionTests {
    func testRemovedTotalUsesOnlyCompletedFileTargetsAcrossOneGigabyteBatch() throws {
        var index = DiskIndex(root: "/fixture")
        index.directories[index.root] = .init(path: index.root)
        let files = [DiskFile(path: "/fixture/first", bytes: 600_000_000, logicalBytes: 600_000_000),
                     DiskFile(path: "/fixture/second", bytes: 400_000_000, logicalBytes: 400_000_000)]
        let ids = Set(files.map { DiskFileRemoval.id($0.path) })
        var removed: [String] = []
        let result = try XCTUnwrap(DiskFileRemoval.execute(ids: ids, folder: index.root, index: index, files: files,
            eligible: { _ in true }, remove: { removed.append($0) }))
        XCTAssertEqual(result.removedBytes, 1_000_000_000); XCTAssertEqual(removed.count, 2)
        let partial = try XCTUnwrap(DiskFileRemoval.execute(ids: ids, folder: index.root, index: index, files: files,
            eligible: { _ in true }, remove: { if $0 == files[0].path { throw CocoaError(.fileWriteNoPermission) } }))
        XCTAssertEqual(partial.removedBytes, 400_000_000); XCTAssertEqual(partial.failures.count, 1)
    }
}
