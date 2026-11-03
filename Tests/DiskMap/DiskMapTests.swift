import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskMapTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("disk-map-tests-" + UUID().uuidString).appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ path: String, size: Int = 8192) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: size).write(to: URL(fileURLWithPath: path))
    }
    func testSparseLargeFileIsIndexedWithoutReadingItsContents() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/large"
        try write(path, size: 1)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.truncate(atOffset: 100_000_000)
        let db = try DiskDatabase(url: root.appendingPathComponent("cache/index.sqlite"), root: root.path)
        db.inventoryIncludes = { path in MacSpacePlatform.FileReviewPolicy.includes(path, home: root.deletingLastPathComponent().path) }
        var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        let index = try db.snapshot().index
        XCTAssertEqual(index.largeFiles.count, 1)
        XCTAssertEqual(index.largeFiles.first?.ownerUID, getuid())
        XCTAssertEqual(index.largeFiles.first?.logicalBytes, 100_000_000)
        XCTAssertLessThan(index.largeFiles.first!.bytes, 1_000_000)
    }
    func testNewRowAndGraphNavigationSurviveCodingAndOldRowsRemainReadable() throws {
        let row = Row(id: "apps", title: "Apps", iconPath: "/Applications/Test.app", pageID: "apps")
        XCTAssertEqual(try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row)), row)
        let legacy = try JSONDecoder().decode(Row.self, from: Data(#"{"id":"old","title":"Old"}"#.utf8))
        XCTAssertNil(legacy.pageID); XCTAssertNil(legacy.iconPath)
        let segment = UsageSegment(id: "A", label: "A", bytes: 100, tone: .series(0), pageID: "folder:/A")
        XCTAssertEqual(try JSONDecoder().decode(UsageSegment.self, from: JSONEncoder().encode(segment)).group?.pageID, "folder:/A")
    }
    func testUninstallOwnershipPreservesOtherAppsAndSharedGroupsAndRejectsSymlinks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, id: String) throws -> AppOwner {
            let path = root.path + "/Applications/" + name + ".app"
            try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
            return try XCTUnwrap(AppOwner(path: path))
        }
        var a = try app("TestA", id: "com.macspace-test.a"), b = try app("TestB", id: "com.macspace-test.b")
        a.groups = ["group.macspace-test.shared"]; b.groups = a.groups
        let own = root.path + "/Library/Caches/" + a.identifier
        let other = root.path + "/Library/Caches/" + b.identifier
        let shared = root.path + "/Library/Group Containers/" + a.groups[0]
        for path in [own, other, shared] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let paths = AppOwnership.dataPaths(owner: a, installed: [a, b], home: root.path)
        XCTAssertFalse(paths.contains(own)); XCTAssertFalse(paths.contains(other)); XCTAssertFalse(paths.contains(shared))
        XCTAssertFalse(AppOwnership.dataPaths(owner: a, installed: [a], home: root.path).contains(shared), "An incomplete catalog cannot prove exclusive group ownership")
        try FileManager.default.removeItem(atPath: own)
        try FileManager.default.createSymbolicLink(atPath: own, withDestinationPath: other)
        XCTAssertFalse(AppOwnership.dataPaths(owner: a, installed: [a, b], home: root.path).contains(own))
        a.identifier = "com.apple.protected"
        XCTAssertTrue(AppOwnership.removable(a, home: root.path), "An identifier prefix alone cannot make a user-installed app protected")
        XCTAssertFalse(DiskMapScreenBuilder.canDelete("/System/Library/file"))
    }
    func testEventQueueTargetsParentsAndHandlesDroppedEvents() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let watch = DiskEvents(root: root.path, since: 0, excluded: [root.path + "/cache"])
        watch.mark([root.path + "/A/file", root.path + "/cache/index"])
        let changes = watch.drain()
        XCTAssertEqual(changes.shallow, [root.path + "/A"])
        watch.mark([root.path + "/A"], recursive: true)
        XCTAssertEqual(watch.drain().recursive, [root.path + "/A"])
    }
    func testAppAndOwnedDataAreRemovedTogetherAndFailuresKeepTheAppForRetry() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/Applications/Test.app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.macspacetest", "CFBundleName": "MacSpace Uninstall Fixture", "CrProductDirName": "Vendor/Product"], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        let owner = try XCTUnwrap(AppOwner(path: path))
        let cache = root.path + "/Library/Caches/" + owner.identifier
        try write(cache + "/data")
        let profile = root.path + "/Library/Application Support/Vendor/Product"
        try write(profile + "/Default/profile")
        let catalog = AppCatalog(owners: [owner])
        let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: root.path, systemLibrary: root.path + "/system-library")
        XCTAssertEqual(plan.targets.map(\.path), [path])
        let failed = AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: root.path, systemLibrary: root.path + "/system-library", remove: { _ in throw POSIXError(.EACCES) })
        XCTAssertFalse(failed.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let removed = AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: root.path, systemLibrary: root.path + "/system-library")
        XCTAssertTrue(removed.failures.isEmpty)
        XCTAssertEqual(removed.removed, [path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile), "Vendor metadata and identifier conventions are not proof of exclusive ownership")
    }

    func testStorePersistsAndReplaysOnlyChangedBranches() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.path + "/A", b = root.path + "/B"
        try write(a + "/one"); try write(b + "/two")
        let cache = root.appendingPathComponent("cache/index.json")
        let store = DiskStore(root: root.path, cache: cache)
        let before = await store.snapshot()
        await store.flushPersistence()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathExtension("sqlite").path))
        try write(a + "/one", size: 65536)
        await store.mark([a + "/one"])
        let after = await store.snapshot()
        XCTAssertGreaterThan(after.directories[root.path]!.bytes, before.directories[root.path]!.bytes)
        XCTAssertEqual(after.directories[b], before.directories[b])
        await store.flushPersistence()
        // A new store must catch changes made since its persisted watermark, not trust a stale file.
        try write(a + "/one", size: 131072)
        try await Task.sleep(for: .seconds(1.2))
        let reopened = DiskStore(root: root.path, cache: cache)
        let replayed = await reopened.snapshot()
        XCTAssertGreaterThan(replayed.directories[a]!.bytes, after.directories[a]!.bytes)
        XCTAssertEqual(replayed.directories[b], after.directories[b])
    }

    func testCloudOnlyDirectoriesAreNeverEnumeratedOrReadForMetadata() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.path + "/cloud"
        try write(cloud + "/Contents/Info.plist")
        let db = try DiskDatabase(url: root.appendingPathComponent("cache/index.sqlite"), root: root.path)
        var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
        scanner.metadata = { path in
            var info = stat(); guard lstat(path, &info) == 0 else { return nil }
            if path == cloud { info.st_flags |= UInt32(SF_DATALESS) }
            return info
        }
        try scanner.scan(.init(), cursor: 1, progress: nil)
        XCTAssertEqual(scanner.visited, 1)
        XCTAssertEqual(try db.directory(cloud)?.bytes, 0)
        XCTAssertNil(try db.directory(cloud + "/Contents"))
    }

}
