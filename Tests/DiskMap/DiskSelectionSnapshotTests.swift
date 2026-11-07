import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskSelectionSnapshotTests: DiskSecurityFixtureCase {
    func testEncryptedSnapshotSupportsBoundedPagesAndExactMembership() throws {
        let snapshot = try DiskSelectionSnapshot()
        for n in 0..<405 {
            try snapshot.append(.init(path: String(format: "/fixture/%04d", n), bytes: 4096, logicalBytes: 1))
        }
        XCTAssertEqual(snapshot.count, 405)
        XCTAssertEqual(snapshot.bytes, 405 * 4096)
        let first = try snapshot.page(after: "", limit: .max)
        XCTAssertEqual(first.count, 200)
        let second = try snapshot.page(after: XCTUnwrap(first.last).path, limit: 200)
        XCTAssertEqual(second.count, 200)
        let third = try snapshot.page(after: XCTUnwrap(second.last).path, limit: 200)
        XCTAssertEqual(third.count, 5)
        XCTAssertEqual(try snapshot.file(at: "/fixture/0200")?.path, second.first?.path)
        XCTAssertNil(try snapshot.file(at: "/fixture/0200-extra"))
        XCTAssertTrue(try snapshot.page(after: "/fixture/9999", limit: 200).isEmpty)
    }

    func testSnapshotRejectsDuplicateOrUnsortedEntries() throws {
        let snapshot = try DiskSelectionSnapshot()
        try snapshot.append(.init(path: "/fixture/b", bytes: 1, logicalBytes: 1))
        XCTAssertThrowsError(try snapshot.append(.init(path: "/fixture/b", bytes: 1, logicalBytes: 1)))
        XCTAssertThrowsError(try snapshot.append(.init(path: "/fixture/a", bytes: 1, logicalBytes: 1)))
        XCTAssertEqual(snapshot.count, 1)
    }

    func testPublishedSelectionSurvivesDisposableCacheLoss() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let downloads = base.appendingPathComponent("Downloads"), source = base.appendingPathComponent("cache/source.sqlite")
        let selectedURL = base.appendingPathComponent("cache/selected.sqlite")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = downloads.appendingPathComponent("selected.txt")
        try Data("review fixture".utf8).write(to: target)
        do {
            let db = try DiskDatabase(url: source, root: downloads.path, home: base.path)
            var scanner = DiskDatabaseScanner(db: db, excluded: [base.appendingPathComponent("cache").path])
            try scanner.scan(.init(recursive: [downloads.path]), cursor: 1, progress: nil)
            try db.seal()
        }
        let storage = DiskSelectionStorage(url: selectedURL, root: downloads.path, home: base.path)
        let id = DiskFileRemoval.id(target.path)
        let identity = try XCTUnwrap(FileReviewIdentity(target.path))
        let reviewed = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        let selection = try await storage.apply(.init(ids: [id], reviewed: [id: reviewed]), sourceURL: source)
        let original = try await storage.files(token: selection.token, after: "", limit: 200)
        XCTAssertEqual(original.map(\.path), [target.path])
        try await storage.pin(token: selection.token)
        try await storage.recordPreflight(original, token: selection.token)
        do {
            let disposable = try DiskDatabase(url: selectedURL, root: downloads.path, home: base.path)
            XCTAssertEqual(try disposable.query("SELECT 1 FROM sqlite_master WHERE name IN ('selected_rows','selected_versions','preflight_files')"), 0,
                           "Review authority is not stored in externally addressable tables")
            try disposable.execute("DELETE FROM state")
        }
        let restored = try await storage.files(token: selection.token, after: "", limit: 200)
        let summary = try await storage.summary(token: selection.token)
        let execution = try await storage.executionFiles(original, token: selection.token)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(execution, original)
        await storage.unpin(token: selection.token)
        do {
            _ = try await storage.executionFiles(original, token: selection.token)
            XCTFail("Unpinning must retire the preflight evidence")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "This test only reads review evidence")
    }
}
