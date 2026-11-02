import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskMapTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-map-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    private func write(_ path: String, size: Int = 8192) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: size).write(to: URL(fileURLWithPath: path))
    }
    func testChangedBranchReusesUntouchedSubtreesAndRecalculatesAncestors() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.path + "/A", b = root.path + "/B"
        try write(a + "/nested/one"); try write(b + "/nested/two")
        var scanner = DiskScanner(index: DiskIndex(root: root.path))
        let before = try scanner.scan(changed: [])
        let stable = before.directories[b]
        try write(a + "/nested/one", size: 65536)
        scanner = DiskScanner(index: before)
        let after = try scanner.scan(changed: [a + "/nested"])
        XCTAssertEqual(scanner.enumerated, [a + "/nested"])
        XCTAssertEqual(after.directories[b], stable)
        XCTAssertGreaterThan(after.directories[root.path]!.bytes, before.directories[root.path]!.bytes)
        try FileManager.default.removeItem(atPath: a)
        scanner = DiskScanner(index: after)
        let removed = try scanner.scan(changed: [root.path])
        XCTAssertEqual(scanner.enumerated, [root.path])
        XCTAssertNil(removed.directories[a + "/nested"])
        XCTAssertEqual(removed.directories[root.path]?.bytes, removed.directories[b]?.bytes)
    }
    func testLinksAreNotTraversedAndHardLinksTransferAccountingWithoutReadingOtherBranches() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.path + "/A/file")
        try FileManager.default.createDirectory(atPath: root.path + "/B", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: root.path + "/A/file", toPath: root.path + "/B/file")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/loop", withDestinationPath: root.path)
        var scanner = DiskScanner(index: DiskIndex(root: root.path))
        let before = try scanner.scan(changed: [])
        XCTAssertNil(before.directories[root.path + "/loop"])
        XCTAssertEqual(before.hardlinks.values.first?.count, 2)
        let size = before.directories[root.path]!.bytes
        try FileManager.default.removeItem(atPath: root.path + "/A/file")
        scanner = DiskScanner(index: before)
        let after = try scanner.scan(changed: [root.path + "/A"])
        XCTAssertEqual(scanner.enumerated, [root.path + "/A"])
        XCTAssertEqual(after.directories[root.path]?.bytes, size)
        XCTAssertEqual(after.directories[root.path + "/B"]?.bytes, size)
    }
    func testSparseLargeFileIsIndexedWithoutReadingItsContents() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/large"
        try write(path, size: 1)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.truncate(atOffset: 100_000_000)
        var scanner = DiskScanner(index: DiskIndex(root: root.path))
        let index = try scanner.scan(changed: [])
        XCTAssertEqual(index.largeFiles.count, 1)
        XCTAssertEqual(index.largeFiles.first?.logicalBytes, 100_000_000)
        XCTAssertLessThan(index.largeFiles.first!.bytes, 1_000_000)
    }
    func testRootSectionOrderTopFiveAndFolderScope() throws {
        var index = DiskIndex(root: "/disk")
        index.directories["/disk"] = DiskDirectory(path: "/disk", folders: ["/disk/A", "/disk/AB"])
        let files = (0..<8).map { DiskFile(path: "/disk/A/file\($0)", bytes: UInt64(200_000_000 + $0), logicalBytes: UInt64(200_000_000 + $0)) }
        index.directories["/disk/A"] = DiskDirectory(path: "/disk/A", files: files, directBytes: 2_000_000_000, bytes: 2_000_000_000)
        index.directories["/disk/AB"] = DiskDirectory(path: "/disk/AB", files: [DiskFile(path: "/disk/AB/unrelated", bytes: 5_000_000_000, logicalBytes: 5_000_000_000)])
        let page = DiskMapScreenBuilder.screen(index, apps: DiskApplications())
        XCTAssertEqual(page.widgets.map(\.id), ["apps-class", "large-class"])
        guard case let .list(list) = page.widgets[1] else { return XCTFail() }
        XCTAssertEqual(list.rows.count, 6)
        XCTAssertEqual(list.rows.first?.title, "unrelated")
        XCTAssertEqual(list.rows.last?.pageID, "large:/disk")
        let folder = DiskMapScreenBuilder.screen(index, apps: DiskApplications(), folder: "/disk/A")
        XCTAssertEqual(folder.widgets.map(\.id), ["large-class"])
        XCTAssertEqual(DiskMapScreenBuilder.largeFiles(index, folder: "/disk/A").count, 8)
        let all = DiskMapScreenBuilder.allLargePage(index, folder: "/disk/A")
        guard case let .list(allFiles) = all.widgets.first else { return XCTFail() }
        XCTAssertEqual(allFiles.rows.count, 8)
        XCTAssertTrue(folder.hero?.segments.allSatisfy { $0.id.hasPrefix("/disk/A/") || $0.id == "/disk/A:files" } == true)
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
        XCTAssertTrue(paths.contains(own)); XCTAssertFalse(paths.contains(other)); XCTAssertFalse(paths.contains(shared))
        XCTAssertTrue(AppOwnership.dataPaths(owner: a, installed: [a], home: root.path).contains(shared))
        try FileManager.default.removeItem(atPath: own)
        try FileManager.default.createSymbolicLink(atPath: own, withDestinationPath: other)
        XCTAssertFalse(AppOwnership.dataPaths(owner: a, installed: [a, b], home: root.path).contains(own))
        a.identifier = "com.apple.protected"
        XCTAssertFalse(AppOwnership.removable(a, home: root.path))
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
        let failed = AppRemovalExecutor.execute(owner: owner, installed: [owner], home: root.path, systemLibrary: root.path + "/system-library", remove: { _ in throw POSIXError(.EACCES) })
        XCTAssertFalse(failed.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let removed = AppRemovalExecutor.execute(owner: owner, installed: [owner], home: root.path, systemLibrary: root.path + "/system-library")
        XCTAssertTrue(removed.failures.isEmpty)
        XCTAssertTrue(removed.removed.contains(profile))
        XCTAssertTrue(removed.removed.contains(path)); XCTAssertTrue(removed.removed.contains(cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path)); XCTAssertFalse(FileManager.default.fileExists(atPath: cache))
    }

    func testStorePersistsAndReplaysOnlyChangedBranches() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.path + "/A", b = root.path + "/B"
        try write(a + "/one"); try write(b + "/two")
        let cache = root.appendingPathComponent("cache/index.json")
        let store = DiskStore(root: root.path, cache: cache)
        let before = await store.snapshot()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        try write(a + "/one", size: 65536)
        await store.mark([a + "/one"])
        let after = await store.snapshot()
        XCTAssertGreaterThan(after.directories[root.path]!.bytes, before.directories[root.path]!.bytes)
        XCTAssertEqual(after.directories[b], before.directories[b])
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
        var scanner = DiskScanner(index: DiskIndex(root: root.path), metadata: { path in
            var info = stat(); guard lstat(path, &info) == 0 else { return nil }
            if path == cloud { info.st_flags |= UInt32(SF_DATALESS) }
            return info
        })
        let result = try scanner.scan(changed: [])
        XCTAssertEqual(scanner.enumerated, [root.path])
        XCTAssertEqual(result.directories[cloud]?.bytes, 0)
        XCTAssertNil(result.directories[cloud + "/Contents"])
    }

}
