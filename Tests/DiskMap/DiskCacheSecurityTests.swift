import Darwin
import Foundation
import XCTest
@testable import MacSpaceDiskMap

final class DiskCacheSecurityTests: DiskSecurityFixtureCase {
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/macspace-cache-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    func testNewCacheArtifactsHavePrivatePermissionsAndCanBeReopened() async throws {
        try await fixture { folder in
            let url = folder.appendingPathComponent("cache/index.sqlite")
            do { let db = try DiskDatabase(url: url, root: folder.path); try db.saveState(.init(root: folder.path)) }
            let db = try DiskDatabase(url: url, root: folder.path)
            XCTAssertEqual(try db.state()?.root, folder.path)
            var value = stat()
            XCTAssertEqual(lstat(url.path, &value), 0); XCTAssertEqual(value.st_mode & 0o777, 0o600)
            XCTAssertEqual(lstat(url.deletingLastPathComponent().path, &value), 0); XCTAssertEqual(value.st_mode & 0o777, 0o700)
        }
    }

    func testCacheLinksAreRefusedBeforeAnyDatabaseWrites() async throws {
        try await fixture { folder in
            let destination = folder.appendingPathComponent("existing.txt")
            let bytes = Data("keep this fixture".utf8)
            try bytes.write(to: destination)
            let link = folder.appendingPathComponent("linked.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            XCTAssertThrowsError(try DiskDatabase(url: link, root: folder.path))
            let hardlink = folder.appendingPathComponent("hardlinked.sqlite")
            try FileManager.default.linkItem(at: destination, to: hardlink)
            XCTAssertThrowsError(try DiskDatabase(url: hardlink, root: folder.path))
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            let alias = folder.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
            XCTAssertThrowsError(try DiskDatabase(url: alias.appendingPathComponent("new.sqlite"), root: folder.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("new.sqlite").path))
        }
    }

    func testUnopenedStoreRemovesOnlyItsOwnDisposableArtifacts() async throws {
        try await fixture { folder in
            let cache = folder.appendingPathComponent("cache/index")
            let base = cache.appendingPathExtension("sqlite")
            do { _ = try DiskDatabase(url: base, root: folder.path) }
            for suffix in [".receipts.json", ".current", ".selection", "." + UUID().uuidString] {
                try Data("fixture".utf8).write(to: URL(fileURLWithPath: base.path + suffix))
            }
            let unrelated = folder.appendingPathComponent("cache/keep.txt")
            let history = folder.appendingPathComponent("history.json")
            try Data("keep".utf8).write(to: unrelated)
            try Data("history".utf8).write(to: history)
            let store = DiskStore(root: folder.path, cache: cache, home: folder.path)
            try await store.prepareForUninstall()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.deletingLastPathComponent().path), ["keep.txt"])
            XCTAssertEqual(try Data(contentsOf: history), Data("history".utf8))
            // A second invocation is safe, including after a prior interrupted app uninstall.
            try await store.prepareForUninstall()
        }
    }

    func testActiveStoreClosesItsIndexBeforeRemovingTheCache() async throws {
        try await fixture { folder in
            let root = folder.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let cache = folder.appendingPathComponent("cache/index")
            let store = DiskStore(root: root.path, cache: cache, home: folder.path)
            _ = await store.snapshot()
            try await store.prepareForUninstall()
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathExtension("sqlite").path))
            await store.setActive(true)
            _ = await store.snapshot()
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathExtension("sqlite").path), "A canceled app uninstall can restart normally")
            try await store.prepareForUninstall()
        }
    }
}
