import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskPathValidationTests: XCTestCase {
    func testByteValidationRetainsPathBoundarySemanticsForUnicodeAndInvalidComponents() {
        let roots = ["/", "/Users/example", "/Users/João/文档"]
        let endings = ["file", "a.b", ".hidden", "...", "é", "e\u{301}", "雪/👩🏽‍💻", "a/", "./file", "../file", "a/./file", "a/../file", "a//file", "a\0/file", ".", ".."]
        for root in roots {
            for ending in endings {
                let path = root + (root == "/" ? "" : "/") + ending
                let reference = path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("//")
                    && !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
                XCTAssertEqual(FileReviewPolicy.isNormalizedAbsolutePath(path), reference, path)
                XCTAssertEqual(FileReviewPolicy.isNormalizedAbsolutePath(path, allowTrailingSlash: false), reference && !path.hasSuffix("/"), path)
                XCTAssertEqual(DiskDatabase.contains(path, below: root), reference, path)
            }
        }
        for path in ["", "relative/file", "//", "/../outside", "/./file", "/path/.", "/path/..", "/path\0"] {
            XCTAssertFalse(FileReviewPolicy.isNormalizedAbsolutePath(path), path)
        }
        XCTAssertTrue(FileReviewPolicy.isNormalizedAbsolutePath("/"))
        XCTAssertFalse(DiskDatabase.contains("/Users/example-other/file", below: "/Users/example"))
    }
}
