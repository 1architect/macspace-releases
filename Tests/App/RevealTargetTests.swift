import XCTest
@testable import MacSpaceApp

final class RevealTargetTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testFilesInOneFolderAreSelectedThere() {
        let files = [url("/Users/me/Library/Logs/DiagnosticReports/a.ips"), url("/Users/me/Library/Logs/DiagnosticReports/b.ips")]
        XCTAssertEqual(RevealTarget.of(files), .select(files))
    }

    /// A hidden folder (the Trash) is opened: selected in its parent, it is not drawn there.
    func testAHiddenFolderIsOpened() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(".hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(RevealTarget.of([folder]), .open(folder.standardizedFileURL))
    }

    func testFilesInManyFoldersOpenOneWindowOnTheFolderHoldingThemAll() {
        // Each account's temporary folder under /private/var/folders: one window, not one per account.
        let files = (0..<30).map { url("/private/var/folders/zz/account\($0)/T") }
        XCTAssertEqual(RevealTarget.of(files), .open(url("/private/var/folders/zz")))
    }

    func testAFewPlacesWithOnlyTheRootInCommonAreEachSelected() {
        let places = [url("/opt/homebrew"), url("/usr/local")]
        XCTAssertEqual(RevealTarget.of(places), .select(places))
    }

    func testManyPlacesWithOnlyTheRootInCommonOpenTheRoot() {
        XCTAssertEqual(RevealTarget.of([url("/opt/a"), url("/usr/b"), url("/var/c"), url("/Library/d")]), .open(url("/")))
    }

    func testNothingToShow() {
        XCTAssertNil(RevealTarget.of([]))
    }
}
