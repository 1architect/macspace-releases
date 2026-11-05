import Darwin
import Foundation
import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskBrowseTests: XCTestCase {
    private func fixture(_ body: (URL, DiskDatabase) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let root = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: root.path, home: home.path)
        try body(root, db)
    }
    private func collect(_ request: DiskBrowseRequest, db: DiskDatabase) throws -> [DiskFile] {
        var files: [DiskFile] = []; try db.streamScope(request) { files.append($0) }; return files
    }
    private func write(_ path: String, large: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: DiskDatabase.parent(path), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 4096).write(to: URL(fileURLWithPath: path))
        if large {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
            try handle.truncate(atOffset: DiskIndex.largeFileMinimum)
        }
    }
    func testLargeCategoryPaginationAndExplicitAllSizeSelectionStayInScope() throws {
        try fixture { root, db in
            for n in 0..<451 { try write(root.path + "/A/item-\(n).zip", large: true) }
            try write(root.path + "/A/small.zip"); try write(root.path + "/AB/outside.zip", large: true)
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            var request: DiskBrowseRequest? = .init(folder: root.path + "/A", kind: .category, category: .archives)
            var paths = Set<String>()
            while let cursor = request {
                let page = try XCTUnwrap(db.browse(cursor))
                XCTAssertLessThanOrEqual(page.files.count, 200)
                XCTAssertEqual(page.eligibleCount, 451)
                for file in page.files { XCTAssertTrue(paths.insert(file.path).inserted); XCTAssertNotNil(file.identity) }
                request = page.next
            }
            XCTAssertEqual(paths.count, 451)
            let category = DiskBrowseRequest(folder: root.path + "/A", kind: .category, category: .archives)
            let large = try collect(category, db: db)
            XCTAssertEqual(large.count, 451)
            var smaller = category; smaller.includeSmaller = true
            XCTAssertNotEqual(smaller.selectionScope, category.selectionScope)
            let all = try collect(smaller, db: db)
            XCTAssertEqual(all.count, 452)
            smaller.smallerOnly = true
            XCTAssertEqual(try collect(smaller, db: db).map(\.path), [root.path + "/A/small.zip"])
            let smallPage = try XCTUnwrap(db.browse(smaller))
            XCTAssertEqual(smallPage.files.map(\.path), [root.path + "/A/small.zip"])
            XCTAssertEqual(DiskBrowseRequest(id: smaller.pageID)?.smallerOnly, true)
            XCTAssertEqual(try collect(category, db: db).count, 451, "Showing smaller files never broadens the original category selection")
            XCTAssertFalse(all.contains { $0.path.contains("/AB/") })
            var stored: UInt64 = 0
            try db.query("SELECT COUNT(*) FROM entries") { stored = DiskDatabase.number($0, 0) }
            XCTAssertEqual(stored, 453, "The scan retains approved personal-file metadata so all-size pages do not re-enumerate folders")
        }
    }
    func testFolderHeaderSelectsExactParentAndOriginalReviewedIdentityRejectsReplacement() throws {
        try fixture { root, db in
            for name in ["one.zip", "nested/two.zip"] { try write(root.path + "/" + name, large: true) }
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            var request = DiskBrowseRequest(folder: root.path, kind: .category, category: .archives)
            request.selectionParent = root.path
            let selected = try collect(request, db: db)
            XCTAssertEqual(selected.count, 1)
            let file = try XCTUnwrap(selected.first), id = DiskFileRemoval.id(file.path)
            let identity = try XCTUnwrap(file.identity)
            let reviewed = [id: String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)]
            XCTAssertNotNil(try db.selectedFiles([id], folder: root.path, reviewed: reviewed))
            try FileManager.default.removeItem(atPath: file.path); try write(file.path, large: true)
            XCTAssertNil(try db.selectedFiles([id], folder: root.path, reviewed: reviewed))
            XCTAssertNil(try db.browse(.init(folder: root.path + "/../Downloads", kind: .direct)))
        }
    }
    func testManagedFilesDoNotPersistButFullMapAndBundleIdentityRemain() throws {
        try fixture { root, db in
            let package = root.path + "/Example.app/Contents", generated = root.path + "/node_modules"
            try write(package + "/large.zip", large: true); try write(generated + "/large.zip", large: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.inventory"], format: .xml, options: 0)
            try plist.write(to: URL(fileURLWithPath: package + "/Info.plist"))
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            XCTAssertGreaterThan(try XCTUnwrap(db.directory(root.path)?.bytes), 0)
            XCTAssertEqual(try db.snapshot().index.knownBundleIdentifiers, ["org.example.inventory"])
            XCTAssertEqual(try db.categorySummaries().reduce(0) { $0 + $1.count }, 0)
            var request = DiskBrowseRequest(folder: root.path, kind: .category, category: .largeFiles); request.includeSmaller = true
            XCTAssertTrue(try XCTUnwrap(db.browse(request)).files.isEmpty)
        }
    }
    func testBoundedSmallerCacheReusesPagesAndFullSelectionStreamsIndependently() throws {
        try fixture { root, db in
            for n in 0..<220 { try write(root.path + "/file-\(n).txt") }
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            var request = DiskBrowseRequest(folder: root.path, kind: .category, category: .documents); request.includeSmaller = true
            let first = try XCTUnwrap(db.browse(request)), cached = db.smallerAt
            XCTAssertEqual(first.files.count, 200)
            _ = try db.browse(try XCTUnwrap(first.next)); XCTAssertEqual(db.smallerAt, cached)
            db.smallerIncomplete = true
            XCTAssertEqual(try collect(request, db: db).count, 220, "Full selection streaming is independent of browse-cache status")
            var rows: UInt64 = 1; try db.query("SELECT COUNT(*) FROM entries") { rows = DiskDatabase.number($0, 0) }
            XCTAssertEqual(rows, 220)
        }
    }
    func testAllSizeBrowseUsesBoundedDatabasePagesWithoutRescanning() throws {
        try fixture { root, db in
            for n in 0..<451 { try write(root.path + String(format: "/%04d.zip", n)) }
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            db.smallerLimit = 256
            var current = DiskBrowseRequest(folder: root.path, kind: .category, category: .archives); current.includeSmaller = true
            var cursor: DiskBrowseRequest? = current, paths = Set<String>()
            while let request = cursor {
                let page = try XCTUnwrap(db.browse(request))
                XCTAssertNil(page.unavailableReason)
                for file in page.files { XCTAssertTrue(paths.insert(file.path).inserted) }
                var cached: UInt64 = 0
                try db.query("SELECT 1 FROM sqlite_temp_master WHERE name='smaller'") { cached = DiskDatabase.number($0, 0) }
                XCTAssertEqual(cached, 0, "Ordinary all-size browsing must not start a metadata cache/walk")
                cursor = page.next
            }
            XCTAssertEqual(paths.count, 451)
        }
    }

    func testContentCategoriesCombineAudioAndUseCategoryThenFolderOrder() throws {
        try fixture { root, db in
            try db.put(DiskDirectory(path: root.path))
            for name in ["Z/file.zip", "A/file.pkg", "Z/file.mp3", "A/file.bin"] {
                try db.put(DiskFile(path: root.path + "/" + name, bytes: 4096, logicalBytes: 100_000_000, ownerUID: getuid()))
            }
            let files = try XCTUnwrap(db.browse(.init(folder: root.path, kind: .category, category: .largeFiles))).files
            XCTAssertEqual(Set(files.map { DiskCategory.inventoryCategory($0.path) }), Set([.archives, .installers, .media, .other]))
            XCTAssertEqual(try db.categorySummaries().map(\.category), DiskCategory.inventoryCategories)
        }
    }
}
