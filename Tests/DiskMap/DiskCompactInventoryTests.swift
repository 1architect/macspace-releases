import Darwin
import Foundation
import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceDiskMap

final class DiskCompactInventoryTests: XCTestCase {
    private func fixture() throws -> (home: URL, root: URL, db: DiskDatabase) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("compact-" + UUID().uuidString).resolvingSymlinksInPath()
        let root = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (home, root, try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: root.path, home: home.path))
    }
    func testIncompleteCommittedFirstWalkIsDiscardedBeforeInProcessRetry() throws {
        let (home, root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        try Data([65]).write(to: root.appendingPathComponent("actual.txt"))
        try db.put(DiskDirectory(path: root.path, directBytes: 999999, bytes: 999999))
        try db.put(DiskDirectory(path: root.path + "/interrupted-ghost", bytes: 888888))
        XCTAssertNil(try db.state())
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(shallow: [root.path]), cursor: 71, progress: nil)
        XCTAssertNil(try db.directory(root.path + "/interrupted-ghost"))
        XCTAssertEqual(try db.state()?.eventID, 71)
        var info = stat(); XCTAssertEqual(lstat(root.path + "/actual.txt", &info), 0)
        XCTAssertEqual(try db.directory(root.path)?.bytes, UInt64(info.st_blocks) * 512)
    }
    func testUnreadableRefreshKeepsPriorTruthAndDoesNotAdvanceToAnEmptyMap() throws {
        let (home, root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        try Data(repeating: 65, count: 8192).write(to: root.appendingPathComponent("file.txt"))
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        let before = try XCTUnwrap(db.directory(root.path)?.bytes)
        scanner = DiskDatabaseScanner(db: db, excluded: [])
        scanner.metadata = { _ in errno = EACCES; return nil }
        try scanner.scan(.init(recursive: [root.path]), cursor: 2, progress: nil)
        XCTAssertEqual(try db.directory(root.path)?.bytes, before)
        XCTAssertEqual(try db.directory(root.path)?.readable, false)
    }
    func testFullAllSizeCategoryBeyondTenThousandUsesFrozenDiskSnapshotAndLinearRemovalJournal() async throws {
        let (home, root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let count = 10_050
        for n in 0..<count { try Data([65]).write(to: root.appendingPathComponent(String(format: "%05d.zip", n))) }
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil); try db.seal()
        var scope = DiskBrowseRequest(folder: root.path, kind: .category, category: .archives); scope.includeSmaller = true
        let storage = DiskSelectionStorage(url: home.appendingPathComponent("selection.sqlite"), root: root.path, home: home.path)
        let before = Date()
        let original = try await storage.apply(.init(operation: "toggleAll", scopePageID: "select:" + scope.pageID), sourceURL: home.appendingPathComponent("cache/index.sqlite"))
        XCTAssertEqual(original.count, UInt64(count))
        try await storage.pin(token: original.token)
        let first = try await storage.files(token: original.token, after: "", limit: 100_000)
        XCTAssertEqual(first.count, 200, "Only a bounded page may cross the actor boundary")
        let savedIdentity = try XCTUnwrap(first.first?.identity)
        let firstFile = try XCTUnwrap(first.first)
        let id = DiskFileRemoval.id(firstFile.path)
        // A discarded late reply must not strand the accepted token or silently replace original metadata.
        let toggled = try await storage.apply(.init(token: original.token, operation: "read"), sourceURL: home.appendingPathComponent("cache/index.sqlite"))
        XCTAssertEqual(toggled.token, original.token)
        var after = "", batches = 0
        while true {
            let page = try await storage.files(token: original.token, after: after, limit: 200)
            guard let last = page.last else { break }
            try await storage.recordRemoved(token: original.token, paths: page.map(\.path))
            batches += 1; after = last.path
        }
        let originalBeforeFinal = try await storage.summary(token: original.token)
        XCTAssertEqual(originalBeforeFinal.count, UInt64(count), "Recording completed batches must not copy or mutate the reviewed snapshot")
        let remaining = try await storage.removing(token: original.token, paths: [])
        XCTAssertEqual(remaining.count, 0)
        let retained = try await storage.files(token: original.token, after: "", limit: 200)
        XCTAssertEqual(retained.first?.identity, savedIdentity)
        await storage.unpin(token: original.token)
        let branch = try await storage.apply(.init(token: original.token, operation: "toggle", toggledID: id), sourceURL: home.appendingPathComponent("cache/index.sqlite"))
        XCTAssertEqual(branch.count, UInt64(count - 1), "A delta from an accepted older token branches from that immutable selection")
        print("DISK_SELECTION_STREAM selected=\(count) batches=\(batches) finalizations=1 seconds=\(Date().timeIntervalSince(before))")
    }
    func testDirectoryParentIsAnIntegerAndLateParentCreationReconcilesBeforeTotals() throws {
        let (home, root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let parent = root.path + "/folder", child = parent + "/child"
        try db.put(DiskDirectory(path: child, directBytes: 4096))
        try db.put(DiskDirectory(path: root.path))
        try db.put(DiskDirectory(path: parent))
        try db.reconcileTotals(all: true)
        XCTAssertEqual(try db.children(root.path), [parent])
        XCTAssertEqual(try db.children(parent), [child])
        XCTAssertEqual(try db.directory(root.path)?.bytes, 4096)
        var types: [String] = []
        try db.query("SELECT typeof(parent) FROM dirs") { types.append(DiskDatabase.text($0, 0)) }
        XCTAssertEqual(Set(types), ["integer"])
    }
}
