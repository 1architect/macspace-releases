import Darwin
import Foundation
import MacSpacePlatform
import XCTest
@testable import MacSpaceDiskMap

final class DiskBrowseProjectionTests: DiskSecurityFixtureCase {
    func testPreparedBrowseReusesDisplayedIdentityUntilInvalidationAndPreflightStillRejectsReplacement() async throws {
        let home = "/private/tmp/prepared-browse-" + UUID().uuidString
        let root = home + "/Downloads", path = root + "/large.bin"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        func write() throws {
            try Data([1]).write(to: URL(fileURLWithPath: path))
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
            try handle.truncate(atOffset: 100_000_000)
        }
        try write()
        let smallPath = root + "/small.txt"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: smallPath))
        let store = DiskStore(root: root, cache: URL(fileURLWithPath: home + "/cache/index"), home: home)
        _ = await store.view()
        let request = DiskBrowseRequest(folder: root, kind: .category, category: .largeFiles)
        let original = try XCTUnwrap(FileReviewIdentity(path))
        let originalSmall = try XCTUnwrap(FileReviewIdentity(smallPath))
        await store.prepareNavigation()
        try FileManager.default.moveItem(atPath: path, toPath: home + "/original.bin")
        try write()
        try FileManager.default.moveItem(atPath: smallPath, toPath: home + "/original-small.txt")
        try Data([3, 2, 1]).write(to: URL(fileURLWithPath: smallPath))
        let cached = await store.browse(request)
        XCTAssertEqual(cached?.files.first?.identity, original, "Navigation should reuse the prepared projection")
        let other = await store.browse(.init(folder: root, kind: .category, category: .other))
        XCTAssertEqual(other?.files.first?.identity, original)
        var smaller = request; smaller.includeSmaller = true; smaller.smallerOnly = true
        let cachedSmall = await store.browse(smaller)
        XCTAssertEqual(cachedSmall?.files.first?.identity, originalSmall)
        let proof = [DiskFileRemoval.id(path): String(decoding: try JSONEncoder().encode(original), as: UTF8.self)]
        let selected = await store.selectedFiles([DiskFileRemoval.id(path)], folder: root, reviewed: proof)
        XCTAssertNil(selected, "Cached display metadata cannot authorize removal of a replacement")
        await store.mark([root], recursive: true)
        let invalidated = await store.browse(request)
        XCTAssertNotEqual(invalidated?.files.first?.identity, original)
        let replacement = try XCTUnwrap(invalidated?.files.first?.identity)
        try FileManager.default.moveItem(atPath: path, toPath: home + "/replacement.bin")
        try write()
        await store.invalidate()
        let refreshed = await store.browse(request)
        XCTAssertNotEqual(refreshed?.files.first?.identity, replacement, "Full invalidation must also discard prepared pages")
        await store.setActive(false)
    }

    func testPreparedSizeAndCategoryPagesKeepTotalsTypesAndPagination() throws {
        let home = "/private/tmp/browse-projection-" + UUID().uuidString
        let root = home + "/Downloads"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let db = try DiskDatabase(url: URL(fileURLWithPath: home + "/cache/index.sqlite"), root: root, home: home)
        try db.transaction {
            try db.put(DiskDirectory(path: root))
            for n in 0..<30_000 {
                let ext = ["zip", "bin", "pdf"][n % 3]
                let linked = n == 2 || n == 4
                let file = DiskFile(path: root + String(format: "/file-%05d.", n) + ext,
                    bytes: linked ? 4096 : UInt64(4096 * (1 + n % 8)),
                    logicalBytes: linked ? 120_000_042 : UInt64(n % 2 == 0 ? 120_000_000 + n : 1_000_000 + n), ownerUID: getuid())
                try db.put(file, link: linked ? "shared-fixture-link" : "", parentExists: true)
            }
        }
        var small = DiskBrowseRequest(folder: root, kind: .category, category: .largeFiles)
        small.includeSmaller = true; small.smallerOnly = true
        let requests = [DiskBrowseRequest(folder: root, kind: .category, category: .largeFiles), small,
                        DiskBrowseRequest(folder: root, kind: .category, category: .other), DiskBrowseRequest(folder: root, kind: .direct)]
        for request in requests {
            let filter = try XCTUnwrap(db.browseFilter(request))
            var counts: [String: UInt64] = [:], bytes: [String: UInt64] = [:]
            try db.query("SELECT kind,COUNT(*),SUM(bytes) FROM file_details f WHERE " + filter.0 + " AND " + db.countedDetails + " GROUP BY kind", filter.1) {
                counts[DiskDatabase.text($0, 0)] = DiskDatabase.number($0, 1)
                bytes[DiskDatabase.text($0, 0)] = DiskDatabase.number($0, 2)
            }
            let start = Date(), page = try XCTUnwrap(db.browse(request))
            print("PREPARED_BROWSE records=30000 kind=\(request.kind) category=\(String(describing: request.category)) small=\(request.smallerOnly) seconds=\(Date().timeIntervalSince(start))")
            XCTAssertEqual(page.eligibleCount, counts.values.reduce(0, +))
            XCTAssertEqual(page.eligibleBytes, bytes.values.reduce(0, +))
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: page.types.map { ($0.key, $0.count) }), counts)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: page.types.map { ($0.key, $0.bytes) }), bytes)
            XCTAssertEqual(page.files.count, 200)
            let next = try XCTUnwrap(page.next), second = try XCTUnwrap(db.browse(next))
            XCTAssertTrue(Set(page.files.map(\.path)).isDisjoint(with: second.files.map(\.path)))
            XCTAssertEqual(second.eligibleCount, page.eligibleCount)
        }
    }
}
