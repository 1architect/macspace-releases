import Foundation
import XCTest
@testable import MacSpacePlatform

final class DirectoryEntryNameTests: XCTestCase {
    func testNativeApplicationSuffixMatchesExistingCaseSensitivePathRule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = ["A.app", "upper.APP", "regular.app", ".app", "é.app", "文档.app", "👩🏽‍💻.app", "x.app.txt", "x.app\u{301}", "file"]
        for name in names { try Data([1]).write(to: root.appendingPathComponent(name)) }
        var found: [String: Bool] = [:]
        XCTAssertTrue(DirectoryWalk.entries(at: root.path) { name, entry in found[name] = entry.hasApplicationSuffix })
        XCTAssertEqual(found.count, names.count)
        for name in names { XCTAssertEqual(found[name], name.hasSuffix(".app"), name) }
    }
}
