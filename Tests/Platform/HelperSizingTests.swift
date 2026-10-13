import XCTest
@testable import MacSpacePlatform

final class HelperSizingTests: XCTestCase {
    /// The helper sizes root's folders with links refused anywhere in the path, purgeable files counted and helper threads: every
    /// combination must give the tree's size.
    func testEverySettingTheScanAndTheHelperUseGivesTheSameSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("a/b/file"))
        try Data(count: 1_000_000).write(to: root.appendingPathComponent("top"))
        // The temporary folder is under /var, a link to /private/var: name it as the helper's callers do.
        let path = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/var/", with: "/private/var/"))
        let plain = try XCTUnwrap(FileTreeSizer().size(at: path)?.bytes)
        XCTAssertGreaterThanOrEqual(plain, 3_000_000)
        for refuses in [false, true] {
            for pool in [nil, ScanPool(free: 2)] {
                let size = FileTreeSizer(countsPurgeable: true, pool: pool, refusesLinks: refuses).size(at: path)?.bytes
                XCTAssertEqual(size, plain, "refusesLinks \(refuses), pool \(pool != nil)")
            }
        }
    }
}
