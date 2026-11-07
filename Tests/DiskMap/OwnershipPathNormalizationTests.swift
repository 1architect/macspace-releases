import XCTest
import MacSpaceDiskMapPrivileged

final class OwnershipPathNormalizationTests: DiskSecurityFixtureCase {
    private func reference(_ paths: [String]) -> [String] {
        func parent(_ path: String) -> String {
            guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
            return String(path[..<slash])
        }
        var selected = Set<String>()
        for path in Set(paths).sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"), !path.contains("//"), !path.utf8.contains(0),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { continue }
            var ancestor = parent(path), covered = false
            while ancestor != "/" && !ancestor.isEmpty {
                if selected.contains(ancestor) { covered = true; break }
                ancestor = parent(ancestor)
            }
            if !covered { selected.insert(path) }
        }
        return selected.sorted()
    }
    func testNormalizationMatchesExistingCoverageAndOrderingAcrossPermutationsAndUnicode() {
        let paths = ["/A", "/A/child", "/A-B/child", "/AB/file", "/AB", "/雪/é", "/雪/é/child", "/雪/e\u{301}",
                     "/other/👩🏽‍💻/file", "/other/👩🏽‍💻", "/", "relative", "/bad/../path", "/bad//path", "/bad\0/file", "/trailing/"]
        let expected = reference(paths)
        for offset in paths.indices {
            let input = Array(paths[offset...]) + Array(paths[..<offset]) + paths
            XCTAssertEqual(AppOwnership.normalizedPaths(input), expected)
            XCTAssertEqual(AppOwnership.normalizedPaths(input.reversed()), expected)
        }
    }
    func testLargeReceiptStylePathSetRetainsEveryUncoveredFile() {
        let paths = (0..<20_000).map { "/Library/Packages/receipt-\($0)/long-directory/another-component/file-雪" }
        let start = Date(), normalized = AppOwnership.normalizedPaths(paths)
        XCTAssertEqual(normalized.count, paths.count)
        XCTAssertEqual(Set(normalized), Set(paths))
        print("OWNERSHIP_PATH_NORMALIZATION paths=20000 seconds=\(Date().timeIntervalSince(start))")
    }
}
