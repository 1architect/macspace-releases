import Darwin
import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskDuplicateSelectionTests: XCTestCase {
    private func fixture(_ body: (URL, URL, DiskDatabase, DiskSelectionStorage) async throws -> Void) async throws {
        let home = URL(fileURLWithPath: "/private/tmp/duplicate-selection-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), source = home.appendingPathComponent("cache/source.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try DiskDatabase(url: source, root: root.path, home: home.path)
        try db.put(DiskDirectory(path: root.path))
        var state = DiskIndex(root: root.path); state.storageRevision = 4; state.summaryVersion = DiskIndex.summarySchemaVersion; state.revision = 1
        try db.saveState(state)
        let storage = DiskSelectionStorage(url: source.appendingPathExtension("selection"), root: root.path, home: home.path)
        try await body(root, source, db, storage)
    }
    private func group(_ names: [String], byte: UInt8, root: URL, db: DiskDatabase) throws -> [DiskFile] {
        try db.beginDuplicatePass(folder: root.path, minimumSize: 1)
        var files: [DiskFile] = []
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: byte, count: 8192).write(to: url)
            let identity = try XCTUnwrap(FileReviewIdentity(url.path))
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
            let file = DiskFile(path: url.path, bytes: UInt64(info.st_blocks) * 512, logicalBytes: UInt64(identity.size), ownerUID: identity.uid, identity: identity)
            let digest = try DiskDatabase.digest(url.path)
            try db.stageDuplicate(file, identity: identity)
            try db.saveDuplicate(.init(file: file, identity: identity), sample: digest, digest: digest)
            files.append(file)
        }
        return files
    }
    private func scope(_ root: URL) -> String { DiskMapScreenBuilder.selectionPageID(.init(folder: root.path, kind: .duplicates)) }
    private func toggle(_ file: DiskFile, token: String? = nil) throws -> SelectionBulkRequest {
        let id = DiskFileRemoval.id(file.path)
        return .init(token: token, operation: "toggle", toggledID: id,
            reviewed: [id: String(decoding: try JSONEncoder().encode(try XCTUnwrap(file.identity)), as: UTF8.self)],
            origins: file.duplicateVerification.map { [id: String(decoding: try! JSONEncoder().encode($0), as: UTF8.self)] } ?? [:], visible: [id])
    }
    func testHeaderRetainsOnePerSetAcrossPaginationAndClearsOnlyItsScope() async throws {
        try await fixture { root, source, db, storage in
            _ = try self.group(["pair/a.zip", "pair/b.zip"], byte: 11, root: root, db: db)
            _ = try self.group((0..<207).map { String(format: "many/%03d.bin", $0) }, byte: 22, root: root, db: db)
            let page = try db.duplicatePage(.init(folder: root.path, kind: .duplicates))
            XCTAssertEqual(page.files.count, 200)
            let scope = self.scope(root), visible = page.files.map { DiskFileRemoval.id($0.path) }
            let all = try await storage.apply(.init(operation: "toggleAll", scopePageID: scope, visible: visible, sections: [scope]), sourceURL: source)
            XCTAssertEqual(all.count, 207, "2 + 207 copies leave exactly one survivor per set")
            XCTAssertNil(all.unavailableReason); XCTAssertEqual(all.all, [scope])
            let reopened = try await storage.apply(.init(token: all.token, visible: visible, sections: [scope]), sourceURL: source)
            XCTAssertEqual(reopened.all, [scope], "Header membership must survive a fresh complete scope read")
            let clear = try await storage.apply(.init(token: all.token, operation: "toggleAll", scopePageID: scope, sections: [scope]), sourceURL: source)
            XCTAssertEqual(clear.count, 0); XCTAssertTrue(clear.all.isEmpty)
            XCTAssertTrue(clear.partialScopes?.isEmpty != false)
        }
    }
    func testManualFirstCopyChoiceIsPreservedWhenHeaderCompletesASet() async throws {
        try await fixture { root, source, db, storage in
            _ = try self.group(["a.zip", "b.zip", "c.zip"], byte: 3, root: root, db: db)
            let files = try db.duplicatePage(.init(folder: root.path, kind: .duplicates)).files
            let a = try XCTUnwrap(files.first), scope = self.scope(root)
            let manual = try await storage.apply(try self.toggle(a), sourceURL: source)
            let all = try await storage.apply(.init(token: manual.token, operation: "toggleAll", scopePageID: scope, visible: files.map { DiskFileRemoval.id($0.path) }, sections: [scope]), sourceURL: source)
            XCTAssertEqual(all.count, 2); XCTAssertTrue(all.checked.contains(DiskFileRemoval.id(a.path)))
            XCTAssertNil(all.unavailableReason); XCTAssertEqual(all.all, [scope])
            let selected = try await storage.files(token: all.token, after: "", limit: 200)
            XCTAssertEqual(selected.first { $0.path == a.path }?.identity, a.identity)
            let resolved = try await storage.resolved(selected, token: all.token, sourceURL: source)
            XCTAssertTrue(resolved.allSatisfy { $0.duplicateVerification?.keeper == files[1].path })
        }
    }
    func testManuallySelectingEveryCopyInDuplicateReviewStillRequiresASurvivor() async throws {
        try await fixture { root, source, db, storage in
            _ = try self.group(["a.zip", "b.zip"], byte: 6, root: root, db: db)
            let files = try db.duplicatePage(.init(folder: root.path, kind: .duplicates)).files
            let first = try await storage.apply(try self.toggle(files[0]), sourceURL: source)
            let both = try await storage.apply(try self.toggle(files[1], token: first.token), sourceURL: source)
            XCTAssertEqual(both.count, 2)
            XCTAssertNotNil(both.unavailableReason, "Duplicate review retains its survivor rule; ordinary file review does not inherit it")
        }
    }
    func testOpenVerifiedCopyCanBeTheSurvivor() async throws {
        try await fixture { root, source, db, storage in
            _ = try self.group(["a.zip", "b.zip"], byte: 4, root: root, db: db)
            let a = root.appendingPathComponent("a.zip"), b = root.appendingPathComponent("b.zip")
            let handle = try FileHandle(forReadingFrom: a); defer { try? handle.close() }
            let scope = self.scope(root)
            let selected = try await storage.apply(.init(operation: "toggleAll", scopePageID: scope, visible: [DiskFileRemoval.id(a.path), DiskFileRemoval.id(b.path)], sections: [scope]), sourceURL: source)
            XCTAssertEqual(selected.count, 1); XCTAssertEqual(selected.checked, [DiskFileRemoval.id(b.path)])
            XCTAssertEqual(selected.all, [scope]); XCTAssertNil(selected.unavailableReason)
            let files = try await storage.files(token: selected.token, after: "", limit: 200)
            let reviewed = try await storage.resolved(files, token: selected.token, sourceURL: source)
            XCTAssertEqual(reviewed.first?.duplicateVerification?.keeper, a.path)
        }
    }
    func testNewProjectEvidenceExcludesCachedCopiesButNotOrdinaryFileReview() async throws {
        try await fixture { root, source, db, storage in
            let project = try self.group(["Project/Resources/a.png", "Project/Resources/b.png"], byte: 8, root: root, db: db)
            _ = try self.group(["ordinary/a.zip", "ordinary/b.zip"], byte: 9, root: root, db: db)
            XCTAssertEqual(try db.duplicateTotals(folder: root.path).count, 4)
            try Data("project(Sample)".utf8).write(to: root.appendingPathComponent("Project/CMakeLists.txt"))
            let page = try db.duplicatePage(.init(folder: root.path, kind: .duplicates))
            XCTAssertEqual(page.files.count, 2); XCTAssertFalse(page.files.contains { $0.path.contains("/Project/") })
            let all = try await storage.apply(.init(operation: "toggleAll", scopePageID: self.scope(root)), sourceURL: source)
            XCTAssertEqual(all.count, 1); XCTAssertNil(all.unavailableReason)
            let file = project[0], id = DiskFileRemoval.id(file.path)
            let reviewed = [id: String(decoding: try JSONEncoder().encode(file.identity), as: UTF8.self)]
            XCTAssertNotNil(try db.selectedFiles([id], folder: root.path, reviewed: reviewed), "Ordinary explicit file authority is unchanged")
            let policy = DiskDuplicateEligibility(home: root.deletingLastPathComponent().path)
            XCTAssertFalse(policy.allows(file.path))
            try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
            XCTAssertTrue(policy.allows(root.appendingPathComponent("ordinary/a.zip").path), "A downloaded manifest in the personal root does not classify every download as project data")
            let xcode = root.appendingPathComponent("XcodeOnly")
            try FileManager.default.createDirectory(at: xcode.appendingPathComponent("Example.xcodeproj"), withIntermediateDirectories: true)
            XCTAssertFalse(policy.allows(xcode.appendingPathComponent("Sources/icon.png").path))
            XCTAssertTrue(policy.allows(root.appendingPathComponent("tests/oracle_data/a.bin").path), "Directory names alone are not project evidence")
        }
    }
    func testExecutionReusesVerifiedSurvivorAndRejectsNewProjectEvidence() async throws {
        try await fixture { root, source, db, storage in
            _ = try self.group(["pair/a.zip", "pair/b.zip", "pair/c.zip"], byte: 5, root: root, db: db)
            let a = try XCTUnwrap(db.duplicatePage(.init(folder: root.path, kind: .duplicates)).files.first)
            let selection = try await storage.apply(try self.toggle(a), sourceURL: source)
            let files = try await storage.files(token: selection.token, after: "", limit: 200)
            let verified = try await storage.resolved(files, token: selection.token, sourceURL: source)
            let proof = try XCTUnwrap(verified.first?.duplicateVerification)
            XCTAssertTrue(try proof.verify(eligible: { _ in true }))
            try await storage.pin(token: selection.token)
            try await storage.recordPreflight(verified, token: selection.token)
            try FileManager.default.removeItem(atPath: proof.keeper)
            let execution = try await storage.executionFiles(files, token: selection.token)
            XCTAssertEqual(execution.first?.duplicateVerification?.keeper, proof.keeper, "Do not silently replace the survivor after content preflight")
            var index = DiskIndex(root: root.path); index.directories[root.path] = DiskDirectory(path: root.path)
            var removed: [String] = []
            let result = DiskFileRemoval.execute(ids: [DiskFileRemoval.id(a.path)], folder: root.path, index: index, files: execution, eligible: { _ in true }, remove: { removed.append($0) })
            XCTAssertTrue(removed.isEmpty); XCTAssertEqual(result?.failures.count, 1)
            try Data("project(Sample)".utf8).write(to: root.appendingPathComponent("pair/CMakeLists.txt"))
            do { _ = try await storage.executionFiles(files, token: selection.token); XCTFail("New project evidence must stop duplicate cleanup") } catch {}
            await storage.unpin(token: selection.token)
        }
    }
}
