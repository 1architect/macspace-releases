import Foundation
import Darwin
import XCTest
@testable import MacSpaceDiskMap

final class DiskDatabaseTests: XCTestCase {
    private func fixture(_ body: (URL, DiskDatabase) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-db-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DiskDatabase(url: root.appendingPathComponent("cache/index.sqlite"), root: root.path)
        try body(root, db)
    }
    private func file(_ path: String, bytes: Int = 8192) throws {
        try FileManager.default.createDirectory(atPath: DiskDatabase.parent(path), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    func testDatabaseScanMatchesReferenceAndOnlyRereadsChangedParents() throws {
        try fixture { root, db in
            try file(root.path + "/A/nested/file"); try file(root.path + "/AB/stable")
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(), cursor: 7, progress: nil)
            var reference = DiskScanner(index: DiskIndex(root: root.path), excluded: [root.path + "/cache"])
            let expected = try reference.scan(changed: [])
            for (path, node) in expected.directories {
                let actual = try XCTUnwrap(db.directory(path, contents: true))
                XCTAssertEqual(actual.bytes, node.bytes); XCTAssertEqual(actual.directBytes, node.directBytes)
                XCTAssertEqual(actual.ownerUID, getuid()); XCTAssertEqual(Set(actual.folders), Set(node.folders))
            }
            try file(root.path + "/A/nested/file", bytes: 131072)
            scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(shallow: [root.path + "/A/nested"]), cursor: 8, progress: nil)
            XCTAssertEqual(scanner.visited, 1)
            XCTAssertGreaterThan(try db.directory(root.path)!.bytes, expected.directories[root.path]!.bytes)
            XCTAssertEqual(try db.directory(root.path + "/AB")?.bytes, expected.directories[root.path + "/AB"]?.bytes)
            try FileManager.default.removeItem(atPath: root.path + "/A")
            try scanner.scan(.init(shallow: [root.path]), cursor: 9, progress: nil)
            XCTAssertNil(try db.directory(root.path + "/A/nested"))
            XCTAssertEqual(try db.directory(root.path)?.bytes, try db.directory(root.path + "/AB")?.bytes)
        }
    }
    func testHardlinksTransferAndSymlinkAndCloudDataAreNotTraversed() throws {
        try fixture { root, db in
            try file(root.path + "/A/file")
            try FileManager.default.createDirectory(atPath: root.path + "/B", withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: root.path + "/A/file", toPath: root.path + "/B/file")
            try FileManager.default.createSymbolicLink(atPath: root.path + "/loop", withDestinationPath: root.path)
            try file(root.path + "/cloud/hidden")
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            scanner.metadata = { path in
                var info = stat(); guard lstat(path, &info) == 0 else { return nil }
                if path.hasSuffix("/cloud") { info.st_flags |= UInt32(SF_DATALESS) }
                return info
            }
            try scanner.scan(.init(), cursor: 1, progress: nil)
            let before = try XCTUnwrap(db.directory(root.path)?.bytes)
            XCTAssertNil(try db.directory(root.path + "/loop")); XCTAssertEqual(try db.directory(root.path + "/cloud")?.bytes, 0)
            try FileManager.default.removeItem(atPath: root.path + "/A/file")
            try scanner.scan(.init(shallow: [root.path + "/A"]), cursor: 2, progress: nil)
            XCTAssertEqual(try db.directory(root.path)?.bytes, before)
            XCTAssertEqual(try db.directory(root.path + "/B")?.bytes, before)
        }
    }
    func testMigrationStreamsRecordsAndRejectsTruncationAtomically() throws {
        try fixture { root, db in
            let child = root.path + "/folder%_\n雪"
            var index = DiskIndex(root: root.path)
            index.directories[root.path] = DiskDirectory(path: root.path, folders: [child], bytes: 4096)
            index.directories[child] = DiskDirectory(path: child, directBytes: 4096, bytes: 4096)
            index.revision = 11; index.eventID = 17
            let cache = root.appendingPathComponent("old.scan")
            try DiskCache.write(index, to: cache)
            try db.importLegacy(cache)
            XCTAssertEqual(try db.state()?.revision, 11)
            XCTAssertEqual(try db.snapshot(folder: child, inventory: false).index.directories[child]?.bytes, 4096)
            try db.transaction { try db.remove(child) }
            XCTAssertNil(try db.directory(child))
            let file = try FileHandle(forWritingTo: cache); try file.truncate(atOffset: 40); try file.close()
            XCTAssertThrowsError(try db.importLegacy(cache))
            XCTAssertNil(try db.directory(child), "Failed imports roll back partial records")
        }
    }
}
