import Foundation
import Darwin
import XCTest
import MacSpaceSdk
import MacSpaceDiskMapPrivileged
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskUnmatchedDataTests: DiskSecurityFixtureCase {
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func record(_ ids: [String]) { lock.withLock { value = ids } }
        var finished: [String] { lock.withLock { value } }
    }
    private func fixture(_ body: (String, DiskIndex) throws -> Void) throws {
        let home = "/private/tmp/unmatched-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        var index = DiskIndex(root: home)
        for base in ["Caches", "Containers"] {
            let parent = home + "/Library/" + base
            var folders: [String] = []
            for id in ["org.example.unknown", "org.example.installed.extension", "com.apple.system.extension", "org.example.zero"] {
                let path = parent + "/" + id
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path + "/payload"))
                folders.append(path)
                index.directories[path] = DiskDirectory(path: path, bytes: id.hasSuffix(".zero") ? 0 : 8192, ownerUID: getuid())
            }
            index.directories[parent] = DiskDirectory(path: parent, folders: folders)
        }
        try body(home, index)
    }

    func testIndexedInstalledComponentsAreNotOrphansAndRowsAreFlatAndSelectable() throws {
        try fixture { home, index in
            let candidates = DiskApplications.unmatchedData(index, apps: [], knownIdentifiers: ["org.example.installed.extension", "com.apple.system.extension"], home: home)
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates.contains { $0.path.contains("/Caches/") })
            XCTAssertTrue(candidates.allSatisfy { $0.identifier == "org.example.unknown" })
            var apps = DiskApplications(); apps.catalogReadAt = Date(); apps.reviewableLeftovers = candidates
            let screen = DiskMapScreenBuilder.leftoversPage(apps)
            guard case let .list(list)? = screen.widgets.last else { return XCTFail() }
            XCTAssertEqual(list.rows.count, 2)
            XCTAssertTrue(list.rows.allSatisfy { $0.children.isEmpty && $0.detail == nil && $0.subtitle?.contains("/Library/") == true })
            XCTAssertEqual(Set(list.rows.map(\.id)).count, 2)
            XCTAssertEqual(screen.selection?.choices.count, 2)
            XCTAssertEqual(screen.selection?.action.id, "freeUnmatchedData")
            XCTAssertTrue(screen.selection?.checked.isEmpty == true)
            XCTAssertFalse(screen.title.contains("removed"))
        }
    }

    func testManualBatchRejectsForgedAndChangedTargetsBeforeRemovingAnything() throws {
        try fixture { home, index in
            let candidates = DiskApplications.unmatchedData(index, apps: [], knownIdentifiers: ["org.example.installed.extension", "com.apple.system.extension"], home: home)
            let ids = Set(candidates.map(\.choiceID))
            var removed: [String] = []
            XCTAssertNil(DiskUnmatchedRemoval.execute(ids: ids.union(["forged"]), candidates: candidates, home: home, remove: { removed.append($0) }))
            XCTAssertTrue(removed.isEmpty)
            let progress = Progress()
            let valid = try XCTUnwrap(DiskUnmatchedRemoval.execute(ids: ids, candidates: candidates, home: home, remove: { removed.append($0) }, progress: { progress.record($0.finished) }))
            XCTAssertTrue(valid.failures.isEmpty)
            XCTAssertEqual(Set(removed), Set(candidates.map(\.path)))
            XCTAssertEqual(Set(progress.finished), ids)
            let path = candidates[0].path
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            removed = []
            XCTAssertNil(DiskUnmatchedRemoval.execute(ids: ids, candidates: candidates, home: home, remove: { removed.append($0) }))
            XCTAssertTrue(removed.isEmpty)
            XCTAssertFalse(DiskUnmatchedRemoval.eligible(home + "/Library", home: home))
        }
    }

    func testNativeScanRetainsSystemAndEmbeddedBundleIdentities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let component = root.path + "/System/Library/ExtensionKit/Extensions/Example.appex"
        try FileManager.default.createDirectory(atPath: component, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "org.example.system.extension"] as NSDictionary).write(to: URL(fileURLWithPath: component + "/Info.plist"))
        let db = try DiskDatabase(url: root.appendingPathComponent("cache/index.sqlite"), root: root.path)
        var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        XCTAssertTrue(try db.snapshot().index.knownBundleIdentifiers?.contains("org.example.system.extension") == true)
    }

    private func guardedFixture(_ body: (String, String) throws -> Void) throws {
        guard getuid() != 0, geteuid() == getuid() else { throw XCTSkip("Removal explicitly refuses elevated execution") }
        let home = "/private/tmp/unmatched-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/Library/Containers/org.example.unmatched"
        try FileManager.default.createDirectory(atPath: path + "/nested", withIntermediateDirectories: true)
        try Data("reviewed".utf8).write(to: URL(fileURLWithPath: path + "/nested/payload"))
        try body(home, path)
    }

    private func reviewed(_ path: String) throws -> ReviewedDirectoryRemoval.Target {
        let value = try XCTUnwrap(AppFileIdentity(path: path))
        return .init(path: path, expected: .init(device: value.device, inode: value.inode, uid: value.uid,
            modifiedSeconds: value.modifiedSeconds, modifiedNanos: value.modifiedNanos))
    }

    func testGuardedProductionRemovalIsRecursiveAndReportsFinishedChoice() throws {
        try guardedFixture { home, path in
            let candidate = AppLeftover(identifier: "org.example.unmatched", path: path, bytes: 8, identity: AppFileIdentity(path: path))
            let progress = Progress()
            let result = try XCTUnwrap(DiskUnmatchedRemoval.execute(ids: [candidate.choiceID], candidates: [candidate], home: home,
                progress: { progress.record($0.finished) }))
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            XCTAssertEqual(result.targets, [path])
            XCTAssertEqual(progress.finished, [candidate.choiceID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent), [])
        }
    }

    func testProductionRemovalAcceptsMoreThanThirtyTwoReviewedLocations() throws {
        try guardedFixture { home, path in
            var candidates = try (0..<33).map { n in
                let folder = path + "-\(n)"
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
                try Data("reviewed".utf8).write(to: URL(fileURLWithPath: folder + "/payload"))
                return AppLeftover(identifier: "org.example.unmatched-\(n)", path: folder, bytes: 8, identity: AppFileIdentity(path: folder))
            }
            let preferences = home + "/Library/Preferences"
            try FileManager.default.createDirectory(atPath: preferences, withIntermediateDirectories: false)
            let file = preferences + "/org.example.unmatched.plist"
            try Data("reviewed".utf8).write(to: URL(fileURLWithPath: file))
            candidates.append(AppLeftover(identifier: "org.example.unmatched", path: file, bytes: 8,
                identity: try XCTUnwrap(AppFileIdentity(path: file)), fileIdentity: try XCTUnwrap(FileReviewIdentity(file))))
            let ids = Set(candidates.map(\.choiceID)), progress = Progress()
            let result = try XCTUnwrap(DiskUnmatchedRemoval.execute(ids: ids, candidates: candidates, home: home,
                progress: { progress.record($0.finished) }))
            XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
            XCTAssertEqual(result.targets.count, candidates.count)
            XCTAssertEqual(Set(progress.finished), ids)
            XCTAssertTrue(candidates.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    func testDirectoryPolicyAllowsReviewedAppDataButRejectsRootsAndTraversal() throws {
        try guardedFixture { home, path in
            XCTAssertTrue(ReviewedDirectoryRemoval.includes(path, home: home))
            XCTAssertTrue(ReviewedDirectoryRemoval.includes(home + "/Library/Application Support/org.example.data", home: home))
            for allowed in [path + "/nested", home + "/Library/Caches/org.example.data", home + "/Library/Group Containers/org.example.data", home + "/Library/Application Support/Vendor/Product"] {
                XCTAssertTrue(ReviewedDirectoryRemoval.includes(allowed, home: home), allowed)
            }
            for invalid in [home + "/Library/Containers", home + "/Library/Application Support/CloudDocs", path + "/../other", path + "/", path + "\0suffix",
                            home + "/Library/Containers//other", home + "/Library/Containers/."] {
                XCTAssertFalse(ReviewedDirectoryRemoval.includes(invalid, home: home), invalid)
            }
        }
        if getuid() == 0 || geteuid() != getuid() {
            XCTAssertFalse(ReviewedDirectoryRemoval.includes("/Users/example/Library/Containers/org.example.data", home: "/Users/example"))
        }
    }

    func testUnsafeDescendantBlocksOnlyItsOwnLocation() throws {
        try guardedFixture { home, first in
            let second = home + "/Library/Application Support/org.example.second"
            try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
            let outside = home + "/outside"
            try Data("keep".utf8).write(to: URL(fileURLWithPath: outside))
            try FileManager.default.createSymbolicLink(atPath: second + "/alias", withDestinationPath: outside)
            let candidates = [first, second].map { AppLeftover(identifier: ($0 as NSString).lastPathComponent, path: $0, bytes: 8, identity: AppFileIdentity(path: $0)) }
            var removed: [String] = []
            let result = try XCTUnwrap(DiskUnmatchedRemoval.execute(ids: Set(candidates.map(\.choiceID)), candidates: candidates, home: home, remove: { removed.append($0) }))
            XCTAssertEqual(removed, [first])
            XCTAssertTrue(result.failures.contains { $0.contains(second + "/alias") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: first + "/nested/payload"))
            XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "keep")
        }
    }

    func testPinnedParentRejectsSymlinkedAncestor() throws {
        try guardedFixture { home, path in
            let realLibrary = home + "/RealLibrary"
            try FileManager.default.moveItem(atPath: home + "/Library", toPath: realLibrary)
            try FileManager.default.createSymbolicLink(atPath: home + "/Library", withDestinationPath: realLibrary)
            var info = stat()
            XCTAssertEqual(lstat(realLibrary + "/Containers/org.example.unmatched", &info), 0)
            let target = ReviewedDirectoryRemoval.Target(path: path, expected: .init(device: info.st_dev, inode: info.st_ino, uid: info.st_uid,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec)))
            XCTAssertThrowsError(try ReviewedDirectoryRemoval.prepare([target], home: home))
            XCTAssertTrue(FileManager.default.fileExists(atPath: realLibrary + "/Containers/org.example.unmatched/nested/payload"))
        }
    }

    func testObservableOpenDescendantRefusesWholeBatch() throws {
        try guardedFixture { home, path in
            let file = open(path + "/nested/payload", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(file, 0)
            guard file >= 0 else { return }
            defer { close(file) }
            XCTAssertThrowsError(try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home)) { error in
                XCTAssertEqual((error as? ReviewedDirectoryRemoval.Failure)?.path, path)
                XCTAssertTrue(error.localizedDescription.contains("open file descriptors"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/nested/payload"))
        }
    }

    func testReplacementTopAndAncestorArePreservedAfterPreflight() throws {
        try guardedFixture { home, path in
            let plan = try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home)
            try FileManager.default.moveItem(atPath: path, toPath: path + ".original")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data("foreign".utf8).write(to: URL(fileURLWithPath: path + "/keep"))
            XCTAssertThrowsError(try plan.remove(at: 0))
            XCTAssertEqual(try String(contentsOfFile: path + "/keep", encoding: .utf8), "foreign")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".original/nested/payload"))
        }
        try guardedFixture { home, path in
            let plan = try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home)
            let parent = (path as NSString).deletingLastPathComponent
            try FileManager.default.moveItem(atPath: parent, toPath: parent + ".original")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            XCTAssertThrowsError(try plan.remove(at: 0))
            XCTAssertTrue(FileManager.default.fileExists(atPath: parent + ".original/org.example.unmatched/nested/payload"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    func testForeignDescendantReplacementIsRestoredWithoutDeletion() throws {
        try guardedFixture { home, path in
            let plan = try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home)
            let payload = path + "/nested/payload"
            try FileManager.default.moveItem(atPath: payload, toPath: home + "/original-payload")
            try Data("foreign replacement".utf8).write(to: URL(fileURLWithPath: payload))
            XCTAssertThrowsError(try plan.remove(at: 0)) { error in
                XCTAssertTrue(error is ReviewedDirectoryRemoval.Failure)
            }
            XCTAssertEqual(try String(contentsOfFile: payload, encoding: .utf8), "foreign replacement")
            XCTAssertEqual(try String(contentsOfFile: home + "/original-payload", encoding: .utf8), "reviewed")
        }
    }

    func testChangedFileWithUnchangedParentIsPreservedAndReportsItsPath() throws {
        try guardedFixture { home, path in
            let plan = try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home)
            let payload = path + "/nested/payload"
            try Data("changed after preflight".utf8).write(to: URL(fileURLWithPath: payload), options: [])
            XCTAssertThrowsError(try plan.remove(at: 0)) { error in
                XCTAssertEqual((error as? ReviewedDirectoryRemoval.Failure)?.path, payload)
            }
            XCTAssertEqual(try String(contentsOfFile: payload, encoding: .utf8), "changed after preflight")
        }
    }

    func testProtectedDescendantAndSpecialFileRejectPreflight() throws {
        try guardedFixture { home, path in
            let payload = path + "/nested/payload"
            XCTAssertEqual(chflags(payload, UInt32(UF_IMMUTABLE)), 0)
            defer { _ = chflags(payload, 0) }
            XCTAssertThrowsError(try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home))
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload))
        }
        try guardedFixture { home, path in
            XCTAssertEqual(mkfifo(path + "/pipe", 0o600), 0)
            XCTAssertThrowsError(try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/nested/payload"))
        }
    }

    func testExpectedOwnerMismatchAndExcessiveDepthRejectBeforeRemoval() throws {
        try guardedFixture { home, path in
            let target = try reviewed(path), value = target.expected
            let forged = ReviewedDirectoryRemoval.Target(path: path, expected: .init(device: value.device, inode: value.inode, uid: value.uid &+ 1,
                modifiedSeconds: value.modifiedSeconds, modifiedNanos: value.modifiedNanos))
            XCTAssertThrowsError(try ReviewedDirectoryRemoval.prepare([forged], home: home))
            let deep = path + String(repeating: "/d", count: 50)
            try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
            XCTAssertThrowsError(try ReviewedDirectoryRemoval.prepare([try reviewed(path)], home: home)) { error in
                XCTAssertTrue(error.localizedDescription.contains("limit"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/nested/payload"))
        }
    }

}
