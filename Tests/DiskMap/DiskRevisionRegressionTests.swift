import Darwin
import Foundation
import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceDiskMap

final class DiskRevisionRegressionTests: DiskSecurityFixtureCase {
    func testRemovedApplicationInvalidatesCatalogAfterItsMetadataDisappears() async throws {
        try await fixture { root, _, db in
            let app = root.appendingPathComponent("Example.app"), contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "org.example.app"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            try self.scan(db)
            let before = try XCTUnwrap(db.state()?.catalogRevision)
            try FileManager.default.removeItem(at: app)
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(recursive: [app.path]), cursor: 2, progress: nil)
            XCTAssertGreaterThan(try XCTUnwrap(db.state()?.catalogRevision), before)
            XCTAssertFalse(try db.snapshot().index.appPaths?.contains(app.path) == true)
        }
    }
    private func fixture(_ body: (URL, URL, DiskDatabase) async throws -> Void) async throws {
        let home = URL(fileURLWithPath: "/private/tmp/disk-revision-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), source = home.appendingPathComponent("cache/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try DiskDatabase(url: source, root: root.path, home: home.path)
        try await body(root, source, db)
    }
    private func scan(_ db: DiskDatabase) throws {
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil)
    }
    private func verify(_ files: [URL], db: DiskDatabase) throws {
        try db.beginDuplicatePass(folder: db.root, minimumSize: 1)
        for url in files {
            let identity = try XCTUnwrap(FileReviewIdentity(url.path))
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
            let file = DiskFile(path: url.path, bytes: UInt64(info.st_blocks) * 512, logicalBytes: UInt64(identity.size), ownerUID: getuid(), identity: identity)
            try db.stageDuplicate(file, identity: identity)
            let digest = try DiskDatabase.digest(url.path)
            try db.saveDuplicate(.init(file: file, identity: identity), sample: digest, digest: digest)
        }
    }
    func testOrdinaryCategorySelectionsCanRemoveBothIdenticalFiles() async throws {
        try await fixture { root, source, db in
            let a = root.appendingPathComponent("first.zip"), b = root.appendingPathComponent("second.pdf")
            try Data(repeating: 31, count: 8192).write(to: a)
            try FileManager.default.copyItem(at: a, to: b)
            try self.scan(db); try self.verify([a, b], db: db)
            XCTAssertEqual(try db.duplicatePage(.init(folder: root.path, kind: .duplicates)).files.count, 2)
            let storage = DiskSelectionStorage(url: source.appendingPathExtension("selection"), root: root.path, home: root.deletingLastPathComponent().path)
            var archives = DiskBrowseRequest(folder: root.path, kind: .category, category: .archives); archives.includeSmaller = true
            var documents = DiskBrowseRequest(folder: root.path, kind: .category, category: .documents); documents.includeSmaller = true
            let first = try await storage.apply(.init(operation: "toggleAll", scopePageID: "select:" + archives.pageID), sourceURL: source)
            let both = try await storage.apply(.init(token: first.token, operation: "toggleAll", scopePageID: "select:" + documents.pageID), sourceURL: source)
            XCTAssertEqual(both.count, 2); XCTAssertNil(both.unavailableReason); XCTAssertTrue(both.issues?.isEmpty != false)
            let selected = try await storage.files(token: both.token, after: "", limit: 200)
            XCTAssertTrue(selected.allSatisfy { $0.duplicateVerification == nil }, "Ordinary file selections do not inherit duplicate-review restrictions")
            let resolved = try await storage.resolved(selected, token: both.token, sourceURL: source)
            try await storage.pin(token: both.token)
            try await storage.recordPreflight(resolved, token: both.token)
            let execution = try await storage.executionFiles(selected, token: both.token)
            var index = DiskIndex(root: root.path); index.directories[root.path] = .init(path: root.path)
            var removed: [String] = []
            let result = DiskFileRemoval.execute(ids: Set(execution.map { DiskFileRemoval.id($0.path) }), folder: root.path,
                index: index, files: execution, eligible: { _ in true }, remove: { removed.append($0) })
            XCTAssertEqual(Set(removed), [a.path, b.path]); XCTAssertTrue(result?.failures.isEmpty == true)
            await storage.unpin(token: both.token)
        }
    }
    func testTypeSelectionAndCompleteTotalsRemainCorrectBeyondBoundedCache() async throws {
        try await fixture { root, source, db in
            for n in 0..<451 { try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("pdf-\(n).pdf")) }
            try Data(repeating: 2, count: 8192).write(to: root.appendingPathComponent("notes.txt"))
            try Data(repeating: 3, count: 4096).write(to: root.appendingPathComponent("small.pkg"))
            try self.scan(db)
            XCTAssertEqual(try db.categorySummaries().first { $0.category == .installers }?.count, 1)
            db.smallerLimit = 256
            var request = DiskBrowseRequest(folder: root.path, kind: .category, category: .documents); request.includeSmaller = true
            let first = try XCTUnwrap(db.browse(request))
            XCTAssertEqual(first.eligibleCount, 452)
            XCTAssertEqual(first.types.first?.key, "ext:pdf")
            XCTAssertEqual(first.types.first?.count, 451)
            XCTAssertTrue(first.files.allSatisfy { $0.path.hasSuffix(".pdf") }, "Type groups are ordered by full group allocation")
            var stored: UInt64 = 0
            try db.query("SELECT 1 FROM sqlite_temp_master WHERE name='smaller'") { stored = DiskDatabase.number($0, 0) }
            XCTAssertEqual(stored, 0, "The prepared personal inventory serves all-size pages")
            request.fileType = "ext:pdf"
            var files: [DiskFile] = []; try db.streamScope(request) { files.append($0) }
            XCTAssertEqual(files.count, 451)
            XCTAssertTrue(files.allSatisfy { $0.path.hasSuffix(".pdf") })
            let storage = DiskSelectionStorage(url: source.appendingPathExtension("selection"), root: root.path, home: root.deletingLastPathComponent().path)
            let full = try await storage.apply(.init(operation: "toggleAll", scopePageID: "select:" + request.pageID, sections: ["select:" + request.pageID]), sourceURL: source)
            let partial = try await storage.apply(.init(token: full.token, operation: "toggle", toggledID: DiskFileRemoval.id(files[0].path), sections: ["select:" + request.pageID]), sourceURL: source)
            XCTAssertEqual(partial.count, 450); XCTAssertTrue(partial.all.isEmpty)
            XCTAssertEqual(partial.partialScopes, ["select:" + request.pageID])
        }
    }
    func testDuplicatePaginationIncludesEveryCopyAndRecoversFromVanishedCursor() async throws {
        try await fixture { root, _, db in
            var urls: [URL] = []
            for n in 0..<207 {
                let url = root.appendingPathComponent(String(format: "%03d.zip", n))
                try Data(repeating: 7, count: 4096).write(to: url); urls.append(url)
            }
            try self.scan(db); try self.verify(urls, db: db)
            let request = DiskBrowseRequest(folder: root.path, kind: .duplicates)
            let first = try db.duplicatePage(request)
            XCTAssertEqual(first.files.count, 200); XCTAssertEqual(first.eligibleCount, 207)
            let next = try XCTUnwrap(first.next), second = try db.duplicatePage(next)
            XCTAssertEqual(second.files.count, 7)
            XCTAssertEqual(Set((first.files + second.files).map(\.path)).count, 207)
            XCTAssertNil(second.next)
            try FileManager.default.removeItem(atPath: try XCTUnwrap(next.afterPath))
            let recovered = try db.duplicatePage(next)
            XCTAssertFalse(recovered.files.isEmpty, "A stale cursor cannot fabricate an empty duplicate set")
            XCTAssertEqual(recovered.eligibleCount, 206)
        }
    }
    func testFolderProjectionCannotEraseCompletedUnmatchedMeasurements() {
        var previous = DiskApplications(); previous.catalogReadAt = Date(); previous.measurementsComplete = true
        previous.reviewableLeftovers = [.init(identifier: "org.example.unmatched", path: "/fixture/Library/Application Support/org.example.unmatched", bytes: 123456)]
        var projected = DiskIndex(root: "/"); projected.directories["/fixture/Documents"] = DiskDirectory(path: "/fixture/Documents")
        let result = DiskApplications.read(projected, previous: previous)
        XCTAssertEqual(result.reviewableLeftovers.first?.bytes, 123456)
        XCTAssertEqual(result.catalogReadAt, previous.catalogReadAt)
        XCTAssertEqual(previous.remeasured(projected).reviewableLeftovers.first?.bytes, 123456)
    }
    func testCanceledScanDoesNotPublishPartialStateAndIdleStoreDoesNoWork() async throws {
        try await fixture { root, source, db in
            try Data([1]).write(to: root.appendingPathComponent("one.txt"))
            var scanner = DiskDatabaseScanner(db: db, excluded: []); scanner.cancelled = { true }
            XCTAssertThrowsError(try scanner.scan(.init(), cursor: 1, progress: nil)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertNil(try db.state())
            let store = DiskStore(root: root.path, cache: source.deletingPathExtension(), home: root.deletingLastPathComponent().path)
            await store.setActive(false)
            let view = await store.view()
            XCTAssertNil(view.index.directories[root.path])
            XCTAssertNil(try db.state(), "An inactive store cannot start an index or duplicate pass")
            await store.setActive(true)
            let ready = await store.view()
            XCTAssertNotEqual(ready.index.loadError, true)
            XCTAssertNil(DiskMapScreenBuilder.tile(ready.index).refreshAfter, "Completed Disk data never asks for idle polling")
        }
    }
    func testCachedDirectPageAndGraphFileFocusNeedNoMetadataWorker() async throws {
        try await fixture { root, source, db in
            for n in 0..<420 { try Data([1]).write(to: root.appendingPathComponent("small-\(n).txt")) }
            try self.scan(db)
            let store = DiskStore(root: root.path, cache: source.deletingPathExtension(), home: root.deletingLastPathComponent().path)
            var request = DiskBrowseRequest(folder: root.path, kind: .direct)
            request.focusPath = root.appendingPathComponent("small-419.txt").path
            let previewValue = await store.browse(request)
            let preview = try XCTUnwrap(previewValue)
            XCTAssertNil(preview.loadingFraction); XCTAssertLessThanOrEqual(preview.files.count, 200)
            var complete: DiskBrowsePage?
            for _ in 0..<100 {
                let page = await store.browse(request)
                if page?.loadingFraction == nil { complete = page; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let final = try XCTUnwrap(complete)
            XCTAssertEqual(final.eligibleCount, 420)
            XCTAssertTrue(final.files.contains { $0.path == request.focusPath })
            await store.setActive(false)
        }
    }
}
