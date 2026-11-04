import Darwin
import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskDirectoryRemovalTests: XCTestCase {
    private func fixture(_ body: (String, String) throws -> Void) throws {
        guard getuid() != 0, geteuid() == getuid() else { throw XCTSkip("Requires ordinary user execution") }
        let home = "/private/tmp/personal-directory-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/Downloads/Folder"
        try FileManager.default.createDirectory(atPath: path + "/Nested", withIntermediateDirectories: true)
        try Data("reviewed".utf8).write(to: URL(fileURLWithPath: path + "/Nested/file.txt"))
        try body(home, path)
    }

    func testWholeFolderRemovalIncludesDescendantsAndPreservesSiblings() throws {
        try fixture { home, path in
            let sibling = home + "/Downloads/keep.txt"
            try Data("keep".utf8).write(to: URL(fileURLWithPath: sibling))
            let identity = try XCTUnwrap(ReviewedDirectoryRemoval.Identity(path))
            XCTAssertGreaterThan(try DiskDirectoryRemoval.remove(path, expected: identity, moveToTrash: false, home: home), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sibling)), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home + "/Downloads"), ["keep.txt"])
        }
    }

    func testDirectoryActionsAppearOnRowsAndNameWholeFolderAndTrashPolicyInConfirmation() throws {
        try fixture { home, path in
            var index = DiskIndex(root: home)
            let node = DiskDirectory(path: path, bytes: 8192, ownerUID: getuid())
            index.directories[path] = node
            let action = try XCTUnwrap(DiskDirectoryRemoval.action(path, node: node, home: home))
            XCTAssertEqual(action.id, "deleteFolder")
            XCTAssertEqual(action.role, .destructive)
            XCTAssertEqual(action.requires, [.fullDiskAccess])
            XCTAssertEqual(action.parameters["path"], path)
            XCTAssertNotNil(action.parameters["reviewed"])
            XCTAssertEqual(action.parameters["trash"], FileRemovalSettings.movesToTrash() ? "1" : "0")
            XCTAssertTrue(action.confirmation?.message.contains("all its contents") == true)
            XCTAssertTrue(action.confirmation?.message.contains(path) == true)
            let row = DiskMapScreenBuilder.folderRow(path, index: index, home: home)
            XCTAssertEqual(row.contextActions?.delete, action)
            XCTAssertEqual(row.actions, [action])
            var missingProjection = DiskIndex(root: home)
            missingProjection.personalFolders = [node]
            XCTAssertEqual(DiskMapScreenBuilder.folderRow(path, index: missingProjection, directory: node, home: home).trailing, row.trailing)
        }
    }

    func testPersonalBoundaryAllowsWholeHomeSubfoldersWithoutBroadeningAppDataRemoval() throws {
        try fixture { home, path in
            for allowed in [path, home + "/Downloads", home + "/Work/Project"] {
                XCTAssertTrue(ReviewedDirectoryRemoval.includesPersonal(allowed, home: home), allowed)
                XCTAssertFalse(ReviewedDirectoryRemoval.includes(allowed, home: home), "App-data cleanup retains its separate boundary")
            }
            for denied in [home, "/", "/Applications/App.app", home + "/Library", home + "/Downloads/App.app", home + "/.ssh", path + "/../other"] {
                XCTAssertFalse(ReviewedDirectoryRemoval.includesPersonal(denied, home: home), denied)
            }
        }
    }

    func testReplacedFolderAndOpenDescendantAreRejectedWithoutDeletingAnything() throws {
        try fixture { home, path in
            let old = try XCTUnwrap(ReviewedDirectoryRemoval.Identity(path))
            try FileManager.default.moveItem(atPath: path, toPath: path + "-original")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            XCTAssertThrowsError(try DiskDirectoryRemoval.remove(path, expected: old, moveToTrash: false, home: home))
            let original = path + "-original", payload = original + "/Nested/file.txt"
            let open = try FileHandle(forReadingFrom: URL(fileURLWithPath: payload))
            defer { try? open.close() }
            let expected = try XCTUnwrap(ReviewedDirectoryRemoval.Identity(original))
            XCTAssertThrowsError(try DiskDirectoryRemoval.remove(original, expected: expected, moveToTrash: false, home: home))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: payload)), Data("reviewed".utf8))
        }
    }

    func testPersonalFolderWithCrossOverStyleLinksDeletesLinksWithoutFollowingTargets() throws {
        try fixture { home, path in
            let outside = home + "/outside"
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/keep.txt"))
            let links = path + "/dosdevices"
            try FileManager.default.createDirectory(atPath: links, withIntermediateDirectories: false)
            for (name, target) in [("c:", "../Nested"), ("z:", "/"), ("external", outside), ("broken", home + "/missing"), ("loop", ".")] {
                try FileManager.default.createSymbolicLink(atPath: links + "/" + name, withDestinationPath: target)
            }
            let expected = try XCTUnwrap(ReviewedDirectoryRemoval.Identity(path))
            _ = try DiskDirectoryRemoval.remove(path, expected: expected, moveToTrash: false, home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outside + "/keep.txt")), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), ["keep.txt"])
        }
    }

    func testReplacedSymlinkIsPreservedAfterPreflight() throws {
        try fixture { home, path in
            let link = path + "/Nested/link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/old")
            let expected = try XCTUnwrap(ReviewedDirectoryRemoval.Identity(path))
            let plan = try ReviewedDirectoryRemoval.preparePersonal([.init(path: path, expected: expected)], home: home)
            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/")
            XCTAssertThrowsError(try plan.remove(at: 0))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "/")
        }
    }

    func testDirectoryOwnershipChecksIncludeDescendantsAndAncestors() throws {
        try fixture { home, path in
            let db = try DiskDatabase(url: URL(fileURLWithPath: home + "/cache/index"), root: home, home: home)
            try db.put(DiskDirectory(path: path))
            XCTAssertTrue(try db.canRemoveDirectory(path))
            let claim = DiskOwnershipClaim(paths: [path], ownerPaths: ["/Applications/App.app"], confidence: .unknown, source: "test", reason: "owned")
            try db.query("INSERT INTO claims(id,data) VALUES(1,?)", [.data(try JSONEncoder().encode(claim))])
            for protected in [path + "/Nested/file.txt", path, home + "/Downloads"] {
                try db.execute("DELETE FROM ownership")
                try db.query("INSERT INTO ownership VALUES(?,1)", [.text(protected)])
                XCTAssertFalse(try db.canRemoveDirectory(path), protected)
            }
        }
    }
}
