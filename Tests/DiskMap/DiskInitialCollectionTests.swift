import Darwin
import Foundation
import XCTest
@testable import MacSpaceDiskMap

final class DiskInitialCollectionTests: DiskSecurityFixtureCase {
    func testEnumeratedDirectoryMetadataMatchesFreshStatsAcrossInitialAndFullRefresh() throws {
        let base = URL(fileURLWithPath: "/private/tmp/initial-metadata-" + UUID().uuidString)
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        for relative in ["Downloads/empty", "Documents/文档", "Library/Caches"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        // Exercise a partial directory batch as well as the final directory write.
        for index in 0..<300 {
            try Data(repeating: UInt8(index % 255), count: 4096).write(to: home.appendingPathComponent("Downloads/file-\(index).txt"))
        }
        XCTAssertEqual(link(home.appendingPathComponent("Downloads/file-0.txt").path,
                            home.appendingPathComponent("Documents/文档/linked.txt").path), 0)
        XCTAssertEqual(symlink(home.appendingPathComponent("Downloads").path,
                               home.appendingPathComponent("Documents/alias").path), 0)
        let batched = try DiskDatabase(url: base.appendingPathComponent("batched/index.sqlite"), root: home.path, home: home.path)
        let statted = try DiskDatabase(url: base.appendingPathComponent("statted/index.sqlite"), root: home.path, home: home.path)
        // Cross-directory hard links may attribute their blocks to different parents in a parallel traversal.
        // Compare their combined total and the directory metadata separately from that existing attribution policy.
        func rows(_ db: DiskDatabase) throws -> [String] {
            var result: [String] = []
            try db.query("SELECT d.path,COALESCE(p.path,''),d.readable,d.uid,d.bundle,d.items FROM dirs d LEFT JOIN dirs p ON d.parent=p.id ORDER BY d.path") { row in
                result.append((0..<6).map { DiskDatabase.text(row, $0) }.joined(separator: "\t"))
            }
            return result
        }
        for cursor: UInt64 in [1, 2] {
            for (db, freshStats) in [(batched, false), (statted, true)] {
                var scanner = DiskDatabaseScanner(db: db, excluded: [])
                if freshStats {
                    scanner.metadata = { path in
                        var info = stat()
                        return lstat(path, &info) == 0 ? info : nil
                    }
                }
                try scanner.scan(.init(recursive: [home.path]), cursor: cursor, progress: nil)
            }
            XCTAssertEqual(try rows(batched), try rows(statted))
            XCTAssertEqual(try batched.directory(home.path)?.bytes, try statted.directory(home.path)?.bytes)
            XCTAssertEqual(try batched.query("SELECT 1 FROM dirs WHERE path<>? AND parent=0", [.text(home.path)]), 0)
        }
    }

    func testLazyPathsRetainExplicitFileExclusionsAndArbitraryInventoryPredicates() throws {
        let base = URL(fileURLWithPath: "/private/tmp/initial-paths-" + UUID().uuidString)
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        for relative in ["Downloads/keep.bin", "Downloads/skip.txt", "Library/keep.bin", "Library/skip.bin", "Excluded/keep.bin"] {
            let file = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: file)
        }
        let excluded = ["Downloads/skip.txt", "Library/skip.bin", "Excluded"].map { home.appendingPathComponent($0).path }
        for custom in [false, true] {
            let db = try DiskDatabase(url: base.appendingPathComponent("cache-\(custom)/index.sqlite"), root: home.path, home: home.path)
            if custom { db.inventoryIncludes = { $0.hasSuffix("keep.bin") } }
            var scanner = DiskDatabaseScanner(db: db, excluded: excluded)
            try scanner.scan(.init(), cursor: 1, progress: nil)
            var paths: [String] = []
            try db.query("SELECT path FROM file_details ORDER BY path") { paths.append(DiskDatabase.text($0, 0)) }
            let expected = [home.appendingPathComponent("Downloads/keep.bin").path]
                + (custom ? [home.appendingPathComponent("Library/keep.bin").path] : [])
            XCTAssertEqual(paths, expected)
            XCTAssertNil(try db.directory(home.appendingPathComponent("Excluded").path))
        }
        let db = try DiskDatabase(url: base.appendingPathComponent("excluded-root/index.sqlite"), root: home.path, home: home.path)
        var scanner = DiskDatabaseScanner(db: db, excluded: [home.path])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        XCTAssertEqual(try db.directory(home.path)?.bytes, 0)
        XCTAssertEqual(try db.query("SELECT path FROM file_details"), 0)
    }

    func testInitialCollectionRetainsUntraversedDatalessDirectoryWithoutReadingItsContents() throws {
        let base = URL(fileURLWithPath: "/private/tmp/initial-dataless-" + UUID().uuidString)
        let home = base.appendingPathComponent("home"), cloud = base.appendingPathComponent("home/Documents/cloud")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: cloud.appendingPathComponent("not-local.txt"))
        let db = try DiskDatabase(url: base.appendingPathComponent("cache/index.sqlite"), root: home.path, home: home.path)
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        scanner.metadata = { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            if path == cloud.path { info.st_flags |= UInt32(SF_DATALESS) }
            return info
        }
        try scanner.scan(.init(), cursor: 1, progress: nil)
        let placeholder = try XCTUnwrap(db.directory(cloud.path))
        XCTAssertEqual(placeholder.bytes, 0)
        XCTAssertNil(placeholder.itemCount)
        XCTAssertEqual(placeholder.ownerUID, getuid())
        XCTAssertEqual(try db.directory(home.path)?.bytes, 0)
        XCTAssertEqual(try db.query("SELECT path FROM file_details"), 0)
    }

    func testParallelInitialCollectionMatchesIncrementalReaderForExcludedFilesAndHardLinks() throws {
        let base = URL(fileURLWithPath: "/private/tmp/initial-collection-" + UUID().uuidString)
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = ["Downloads/file.txt", "Downloads/zero.txt", "Downloads/.hidden/file.txt", "Downloads/nested/node_modules/file.js",
                     "Documents/文档/é.pdf", "Library/Caches/ignored.bin", "Downloads/Example.app/Contents/Info.plist"]
        for (index, relative) in paths.enumerated() {
            let file = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = relative.hasSuffix("Info.plist")
                ? try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.fixture.example"], format: .xml, options: 0)
                : Data(repeating: UInt8(index), count: relative.contains("zero") ? 0 : 8192)
            try data.write(to: file)
        }
        // Keep both names in one parent: existing cross-parent hard-link attribution follows directory insertion IDs,
        // which legitimately differ between a parallel initial walk and the sequential reference.
        XCTAssertEqual(link(home.appendingPathComponent(paths[0]).path, home.appendingPathComponent("Downloads/linked.txt").path), 0)
        XCTAssertEqual(symlink(home.appendingPathComponent("Documents").path, home.appendingPathComponent("Downloads/alias").path), 0)
        let initial = try DiskDatabase(url: base.appendingPathComponent("initial/index.sqlite"), root: home.path, home: home.path)
        var parallel = DiskDatabaseScanner(db: initial, excluded: [])
        try parallel.scan(.init(), cursor: 1, progress: nil)
        let reference = try DiskDatabase(url: base.appendingPathComponent("reference/index.sqlite"), root: home.path, home: home.path)
        try reference.put(DiskDirectory(path: home.path))
        try reference.saveState(DiskIndex(root: home.path))
        var sequential = DiskDatabaseScanner(db: reference, excluded: [])
        sequential.parallelRootRefresh = false
        try sequential.scan(.init(recursive: [home.path]), cursor: 1, progress: nil)
        func rows(_ db: DiskDatabase, _ sql: String, columns: Int32) throws -> [String] {
            var values: [String] = []
            try db.query(sql) { row in values.append((0..<columns).map { DiskDatabase.text(row, $0) }.joined(separator: "\t")) }
            return values
        }
        XCTAssertEqual(try rows(initial, "SELECT path,direct,total,readable,uid,bundle,items FROM dirs ORDER BY path", columns: 7),
                       try rows(reference, "SELECT path,direct,total,readable,uid,bundle,items FROM dirs ORDER BY path", columns: 7))
        XCTAssertEqual(try rows(initial, "SELECT path,bytes,logical,uid,link,category,modified,kind FROM files ORDER BY path", columns: 8),
                       try rows(reference, "SELECT path,bytes,logical,uid,link,category,modified,kind FROM files ORDER BY path", columns: 8))
        XCTAssertEqual(try rows(initial, "SELECT path FROM file_details ORDER BY path", columns: 1),
                       try rows(reference, "SELECT path FROM file_details ORDER BY path", columns: 1))
        XCTAssertEqual(try initial.directory(home.path)?.bytes, try reference.directory(home.path)?.bytes)
        XCTAssertEqual(try initial.state()?.eventID, 1)
    }
}
