import Foundation
import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class ReviewedFileRemovalTests: XCTestCase {
    func testKeeperChangedAfterBatchVerificationBlocksLaterCopy() throws {
        let root = URL(fileURLWithPath: "/private/tmp/keeper-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keeper = root.appendingPathComponent("keeper")
        try Data([1, 2]).write(to: keeper)
        let kept = try XCTUnwrap(FileReviewIdentity(keeper.path))
        var files: [DiskFile] = []
        for name in ["one", "two"] {
            let path = root.appendingPathComponent(name)
            try Data([1, 2]).write(to: path)
            let identity = try XCTUnwrap(FileReviewIdentity(path.path))
            var file = DiskFile(path: path.path, bytes: 4096, logicalBytes: 2, ownerUID: getuid(), identity: identity)
            file.duplicateVerification = .init(path: path.path, identity: identity, keeper: keeper.path, keeperIdentity: kept, digest: Data(repeating: 0, count: 32))
            files.append(file)
        }
        var index = DiskIndex(root: root.path); index.directories[root.path] = DiskDirectory(path: root.path)
        var removed: [String] = []
        let result = DiskFileRemoval.execute(ids: Set(files.map { DiskFileRemoval.id($0.path) }), folder: root.path, index: index, files: files, eligible: { _ in true }, remove: { path in
            removed.append(path)
            try Data([3, 4, 5]).write(to: keeper)
        })
        XCTAssertEqual(removed, [files[0].path])
        XCTAssertEqual(result?.failures.count, 1)
    }

    func testPolicyUsesPersonalRootsAndExcludesManagedAndPackagePaths() {
        let home = "/fixture/home"
        for path in ["Downloads/file.zip", "Documents/notes.txt", "Pictures/photo.jpg"] {
            XCTAssertTrue(FileReviewPolicy.includes(home + "/" + path, home: home))
        }
        for path in ["Library/Caches/app/file", "Documents/node_modules/file", "Pictures/Photos.photoslibrary/database", "Downloads/../Library/key", "Downloads//file", "Downloads/.hidden/file", "Documents/target/output", "Applications/App.app/file"] {
            XCTAssertFalse(FileReviewPolicy.includes(home + "/" + path, home: home), path)
        }
        XCTAssertFalse(FileReviewPolicy.includes("/System/Library/file", home: home))
        XCTAssertFalse(FileReviewPolicy.includes("/fixture/other/Downloads/file", home: home))
    }
    func testStaleIdentityAndSymlinkNeverRemoveReplacement() throws {
        let home = URL(fileURLWithPath: "/private/tmp/removal-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("chosen").path
        try Data([1, 2]).write(to: URL(fileURLWithPath: path))
        let identity = try XCTUnwrap(FileReviewIdentity(path))
        try Data([3, 4, 5]).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ReviewedFileRemoval.remove(path, expected: identity, moveToTrash: false, home: home.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([3, 4, 5]))
        let current = try XCTUnwrap(FileReviewIdentity(path))
        let alias = directory.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
        XCTAssertThrowsError(try ReviewedFileRemoval.remove(alias, expected: current, moveToTrash: false, home: home.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try ReviewedFileRemoval.remove(path, expected: current, moveToTrash: false, home: home.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".macspace-review-") })
    }
}
