import Darwin
import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpaceDiskMap

final class DiskOverviewTests: DiskSecurityFixtureCase {
    func testLegacyTablesMigrateWithoutRescanningOrLosingMapIdentityAndEvidence() throws {
        let home = "/fixture", root = home + "/Downloads"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("index.sqlite")
        do {
            let legacy = try DiskDatabase(url: url, root: root, home: home)
            try legacy.execute("DROP TRIGGER files_delete; DROP VIEW files; DROP VIEW file_details; DROP TABLE entries; DROP TABLE dirs")
            try legacy.execute("CREATE TABLE dirs(path TEXT PRIMARY KEY,parent TEXT,direct INTEGER,total INTEGER,readable INTEGER,uid INTEGER,bundle TEXT) WITHOUT ROWID; CREATE TABLE files(path TEXT PRIMARY KEY,parent TEXT,bytes INTEGER,logical INTEGER,uid INTEGER,link TEXT) WITHOUT ROWID; CREATE TABLE file_details(path TEXT PRIMARY KEY,parent TEXT,bytes INTEGER,logical INTEGER,uid INTEGER,link TEXT,category TEXT,modified INTEGER,kind TEXT) WITHOUT ROWID")
            try legacy.query("INSERT INTO dirs VALUES(?,?,4096,8192,0,?,'org.fixture.bundle')", [.text(root), .text(""), .optional(getuid())])
            try legacy.query("INSERT INTO dirs VALUES(?,?,4096,4096,1,?,'')", [.text(root + "/nested"), .text(root), .optional(getuid())])
            for (name, size) in [("large.zip", UInt64(100_000_000)), ("small.txt", UInt64(4096))] {
                try legacy.query("INSERT INTO file_details VALUES(?,?,4096,?,?,'','downloads',1700000000,'')", [.text(root + "/" + name), .text(root), .number(size), .optional(getuid())])
            }
            var state = DiskIndex(root: root); state.eventID = 73; state.browseVersion = 1; state.storageRevision = 1
            try legacy.saveState(state); try legacy.seal()
        }
        let db = try DiskDatabase(url: url, root: root, home: home)
        try trustFixtureCache(url)
        XCTAssertFalse(db.compact)
        try db.compactReviewIndex()
        XCTAssertTrue(db.compact); XCTAssertTrue(db.directoryParentIDs)
        XCTAssertEqual(try db.directory(root)?.bytes, 8192)
        XCTAssertEqual(try db.directory(root)?.readable, false)
        XCTAssertEqual(try db.children(root), [root + "/nested"])
        XCTAssertEqual(try db.snapshot().index.knownBundleIdentifiers, ["org.fixture.bundle"])
        XCTAssertEqual(try db.state()?.eventID, 73)
        XCTAssertEqual(try db.state()?.storageRevision, 4)
        XCTAssertEqual(try db.categorySummaries().first { $0.category == .archives }?.count, 1)
        var stored: UInt64 = 0; try db.query("SELECT COUNT(*) FROM entries") { stored = DiskDatabase.number($0, 0) }
        XCTAssertEqual(stored, 1)
    }
    func testCachedPublicationPreservesCompletedTruthBeforeBackgroundReconciliation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = base.appendingPathComponent("index"), root = "/missing-fixture/Downloads"
        do {
            let db = try DiskDatabase(url: cache.appendingPathExtension("sqlite"), root: root, home: "/missing-fixture")
        try trustFixtureCache(cache.appendingPathExtension("sqlite"))
            try db.put(DiskDirectory(path: root, directBytes: 123456, bytes: 123456, readable: false))
            var metadata = DiskIndex(root: root); metadata.storageRevision = 4; metadata.browseVersion = DiskIndex.browseSchemaVersion; metadata.summaryVersion = DiskIndex.summarySchemaVersion
            try db.saveState(metadata); try db.seal()
        }
        let store = DiskStore(root: root, cache: cache, home: "/missing-fixture")
        let cached = await store.view()
        XCTAssertEqual(cached.index.directories[root]?.bytes, 123456)
        XCTAssertEqual(cached.index.directories[root]?.readable, false)
        await store.flushPersistence()
    }
    func testLazyIdentifiersRejectTraversalAndDecodePreviousSizeScopeSafely() throws {
        let request = DiskBrowseRequest(folder: "/fixture/Downloads", kind: .category, category: .archives)
        XCTAssertEqual(DiskBrowseRequest(id: request.pageID)?.folder, request.folder)
        let legacy = Data(#"{"folder":"/fixture/Downloads","kind":"category","category":"archives"}"#.utf8).base64EncodedString()
        XCTAssertEqual(DiskBrowseRequest(id: "browse:" + legacy)?.includeSmaller, false)
        XCTAssertNil(DiskBrowseRequest(id: DiskBrowseRequest(folder: "/fixture/Downloads/../Library", kind: .direct).pageID))
    }
}
