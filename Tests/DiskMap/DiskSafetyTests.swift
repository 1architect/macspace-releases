import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskSafetyTests: DiskSecurityFixtureCase {
    func testBrowseUsesMetadataWhileRemovalStillChecksLiveReaders() throws {
        let root = URL(fileURLWithPath: "/private/tmp/navigation-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("open.bin")
        try Data([1, 2, 3]).write(to: url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let identity = try XCTUnwrap(FileReviewIdentity(url.path))
        let file = DiskFile(path: url.path, bytes: 4096, logicalBytes: 3, ownerUID: getuid(), identity: identity)
        let request = DiskBrowseRequest(folder: root.path, kind: .category, category: .largeFiles)
        let page = DiskMapScreenBuilder.browsePage(.init(request: request, files: [file], ownership: [:]))
        let rows = page.widgets.flatMap { widget -> [Row] in if case let .list(list) = widget { return list.rows }; return [] }
        XCTAssertEqual(rows.first, DiskMapScreenBuilder.fileRow(file), "Opening inventory must not wait for live process enumeration")
        var index = DiskIndex(root: root.path); index.directories[root.path] = DiskDirectory(path: root.path)
        var removed = false
        let result = try XCTUnwrap(DiskFileRemoval.execute(ids: [DiskFileRemoval.id(file.path)], folder: root.path, index: index,
            files: [file], eligible: { _ in true }, remove: { _ in removed = true }, confirmedMoveToTrash: false))
        XCTAssertFalse(removed)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCurrentOpenReaderIsAttributedAndPreventsRemoval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        XCTAssertTrue(OpenFileUse.inspect([url.path])[url.path]?.contains { $0.canRead } == true)
        var index = DiskIndex(root: url.deletingLastPathComponent().path)
        index.directories[index.root] = DiskDirectory(path: index.root)
        let file = DiskFile(path: url.path, bytes: 4096, logicalBytes: 3)
        var removed = false
        let result = DiskFileRemoval.execute(ids: [DiskFileRemoval.id(url.path)], folder: index.root, index: index, files: [file], eligible: { _ in true }, remove: { _ in removed = true })
        XCTAssertFalse(removed)
        XCTAssertEqual(result?.failures.count, 1)
    }
    func testOwnedFileIsRejectedByBackendAndFiltersHaveSeparateSelections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DiskDatabase(url: root.appendingPathComponent("index"), root: "/fixture")
        let file = DiskFile(path: "/fixture/owned", bytes: 4096, logicalBytes: 100000000)
        try db.putDetail(file, link: "")
        let claim = DiskOwnershipClaim(paths: [file.path], ownerPaths: ["/Applications/Test.app"], confidence: .unknown, source: "test", reason: "owned")
        try db.query("INSERT INTO claims(id,data) VALUES(1,?)", [.data(try JSONEncoder().encode(claim))])
        try db.query("INSERT INTO ownership VALUES(?,1)", [.text(file.path)])
        XCTAssertNil(try db.selectedFiles([DiskFileRemoval.id(file.path)], folder: "/fixture"))
        var request = DiskBrowseRequest(folder: "/fixture", kind: .category, category: .largeFiles)
        let all = request.selectionScope; request.largeType = "archives"
        XCTAssertNotEqual(all, request.selectionScope)
    }

    func testPermanentRemovalIsDefaultAndSettingPersists() throws {
        let suite = "file-removal-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FileRemovalSettings.movesToTrash(defaults))
        defaults.set(true, forKey: FileRemovalSettings.moveToTrashKey)
        XCTAssertTrue(FileRemovalSettings.movesToTrash(try XCTUnwrap(UserDefaults(suiteName: suite))))
        defaults.set(false, forKey: FileRemovalSettings.moveToTrashKey)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        try FileRemovalSettings.remove(file.path, defaults: defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testManagedDataCannotBeSelectedEvenWhenUserOwned() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for suffix in ["Library/Application Support/App/database", "Pictures/Photos.photoslibrary/data", "Work/node_modules/file", "Work/.build/output", "Work/target/debug/file", ".ssh/key", "Applications/App.app/Contents/file"] {
            XCTAssertFalse(DiskFileRemoval.userFile(home + "/" + suffix), suffix)
        }
        XCTAssertTrue(DiskFileRemoval.userFile(home + "/Downloads/archive.zip"))
    }
    func testRetentionRemovesOnlyRetiredGenerationsAndPreservesActiveSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("index.sqlite")
        try DiskCacheRetention.prune(base: base, keeping: [base]) // First run has no directory yet.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let active = base.appendingPathExtension(UUID().uuidString), retired = base.appendingPathExtension(UUID().uuidString)
        for name in [active.lastPathComponent, active.lastPathComponent + "-wal", active.lastPathComponent + "-shm", retired.lastPathComponent, retired.lastPathComponent + "-wal", "index.sqlite.current", "index.sqlite.notes"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        try DiskCacheRetention.prune(base: base, keeping: [active])
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.sqlite.notes").path))
    }
}
