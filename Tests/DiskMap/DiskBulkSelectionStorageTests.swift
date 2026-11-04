import Darwin
import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpaceDiskMap

final class DiskBulkSelectionStorageTests: XCTestCase {
    func testRealCategoryBeyondTenThousandUsesFrozenPagedSelectionAndDeltaRemoval() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/bulk-selection-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("cache/source.sqlite")
        do {
            let db = try DiskDatabase(url: source, root: root.path, home: home.path)
            try db.put(DiskDirectory(path: root.path))
            for n in 0..<10_021 {
                try Data([UInt8(n % 251)]).write(to: root.appendingPathComponent(String(format: "%05d.txt", n)))
            }
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(recursive: [root.path]), cursor: 1, progress: nil)
            try db.seal()
        }
        let storage = DiskSelectionStorage(url: home.appendingPathComponent("cache/selected.sqlite"), root: root.path, home: home.path)
        var scope = DiskBrowseRequest(folder: root.path, kind: .category, category: .documents)
        scope.includeSmaller = true
        let firstID = DiskFileRemoval.id(root.appendingPathComponent("00000.txt").path)
        let request = SelectionBulkRequest(operation: "toggleAll", scopePageID: "select:" + scope.pageID, visible: [firstID], sections: ["select:" + scope.pageID])
        let first = try await storage.apply(request, sourceURL: source)
        XCTAssertEqual(first.count, 10_021)
        XCTAssertEqual(first.checked, [firstID])
        let membership = try await storage.apply(.init(token: first.token, operation: "membership", visible: [firstID], sections: ["select:" + scope.pageID]), sourceURL: source)
        XCTAssertEqual(membership.checked, [firstID])
        XCTAssertEqual(membership.all, ["select:" + scope.pageID], "Bounded navigation preserves an already resolved complete header")
        let page = try await storage.files(token: first.token, after: "", limit: 999999)
        XCTAssertEqual(page.count, 200)
        XCTAssertNotNil(page.first?.identity)
        let toggled = try await storage.apply(.init(token: first.token, operation: "toggle", toggledID: firstID, visible: [firstID]), sourceURL: source)
        XCTAssertEqual(toggled.count, 10_020)
        let old = try await storage.summary(token: first.token)
        XCTAssertEqual(old.count, 10_021, "Previously prepared confirmations keep their immutable membership")
        try await storage.pin(token: toggled.token)
        do {
            _ = try await storage.apply(.init(token: toggled.token, operation: "toggle", toggledID: firstID), sourceURL: source)
            XCTFail("A running removal must exclude selection edits")
        } catch {}
        let removed = Array(page.dropFirst().prefix(5).map(\.path))
        try await storage.recordRemoved(token: toggled.token, paths: removed)
        let remaining = try await storage.removing(token: toggled.token, paths: [])
        XCTAssertEqual(remaining.count, 10_015)
        await storage.unpin(token: toggled.token)
        do {
            _ = try await storage.summary(token: first.token)
            XCTFail("Unreferenced old confirmations must expire rather than retain unbounded history")
        } catch { XCTAssertTrue(String(describing: error).contains("expired")) }
        print("DISK_REAL_BULK_SELECTION files=10021 visibleMembership=1 batch=200 originalSnapshotPreserved=true")
    }
}
