import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskEncryptionTests: DiskSecurityFixtureCase {
    func testInventoryAndWALDoNotContainSeededPlaintextAndReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache/index.sqlite")
        let seed = "private-filename-seed-8EBD4A"
        do {
            let db = try DiskDatabase(url: url, root: folder.path)
            try db.execute("CREATE TABLE encryption_fixture(value TEXT)")
            try db.query("INSERT INTO encryption_fixture VALUES(?)", [.text(seed)])
            for path in [url.path, url.path + "-wal"] where FileManager.default.fileExists(atPath: path) {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                XCTAssertNil(bytes.range(of: Data(seed.utf8)))
                XCTAssertFalse(bytes.starts(with: Data("SQLite format 3".utf8)))
            }
            XCTAssertEqual(try db.query("PRAGMA temp_store") { XCTAssertEqual(DiskDatabase.number($0, 0), 2) }, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        }
        let db = try DiskDatabase(url: url, root: folder.path)
        XCTAssertEqual(try db.query("SELECT value FROM encryption_fixture") { XCTAssertEqual(DiskDatabase.text($0, 0), seed) }, 1)
    }
    func testPinnedDatabaseRefusesReplacedAncestor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache"), url = cache.appendingPathComponent("index.sqlite")
        let db = try DiskDatabase(url: url, root: folder.path)
        try FileManager.default.moveItem(at: cache, to: folder.appendingPathComponent("retired"))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        XCTAssertThrowsError(try db.execute("CREATE TABLE replacement(value TEXT)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

extension DiskEncryptionTests {
    func testWrongRootContextCannotReadOrRekeyExistingInventory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache/index.sqlite")
        do {
            let db = try DiskDatabase(url: url, root: "/fixture/Downloads")
            try db.execute("CREATE TABLE seed(value TEXT)"); try db.query("INSERT INTO seed VALUES(?)", [.text("private")]); try db.seal()
        }
        XCTAssertThrowsError(try DiskDatabase(url: url, root: "/different/Downloads"))
        let reopened = try DiskDatabase(url: url, root: "/fixture/Downloads")
        XCTAssertEqual(try reopened.query("SELECT value FROM seed") { XCTAssertEqual(DiskDatabase.text($0, 0), "private") }, 1)
    }
}

extension DiskEncryptionTests {
    func testReplacedWALIsPreservedOnWriteAndClose() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache/index.sqlite"), wal = URL(fileURLWithPath: url.path + "-wal")
        let sentinel = Data("replacement-must-survive".utf8)
        do {
            let db = try DiskDatabase(url: url, root: "/fixture")
            try db.execute("CREATE TABLE first(value TEXT)")
            try FileManager.default.moveItem(at: wal, to: folder.appendingPathComponent("original-wal"))
            try sentinel.write(to: wal); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wal.path)
            XCTAssertThrowsError(try db.execute("CREATE TABLE second(value TEXT)"))
        }
        XCTAssertEqual(try Data(contentsOf: wal), sentinel)
    }
    func testRootOwnedCacheParentCannotCreateAnArtifact() throws {
        let path = URL(fileURLWithPath: "/private/tmp/macspace-wrong-owner-" + UUID().uuidString + ".sqlite")
        XCTAssertThrowsError(try DiskDatabase(url: path, root: "/fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testHardLinkedJournalIsRejectedWithoutChangingItsContents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache/index.sqlite")
        do { _ = try DiskDatabase(url: url, root: "/fixture") }
        let original = folder.appendingPathComponent("original"), journal = URL(fileURLWithPath: url.path + "-journal")
        try Data("preserved".utf8).write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        try FileManager.default.linkItem(at: original, to: journal)
        XCTAssertThrowsError(try DiskDatabase(url: url, root: "/fixture"))
        XCTAssertEqual(try Data(contentsOf: original), Data("preserved".utf8))
        XCTAssertEqual(try Data(contentsOf: journal), Data("preserved".utf8))
    }
}
