import XCTest
import Darwin
import MacSpacePlatform
@testable import MacSpaceSystemData
@testable import MacSpaceSystemDataPrivileged

final class WallpaperDownloadTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("idleassets-\(UUID().uuidString)")
        root = base.appendingPathComponent("folders")
        outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root.deletingLastPathComponent()) }

    private var downloads: String { root.appendingPathComponent("zz/rootdir/T/com.apple.idleassetsd").path }

    @discardableResult
    private func file(_ relative: String, in base: URL? = nil, days: Double, bytes: Int = 100_000) throws -> String {
        let url = (base ?? root).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)], ofItemAtPath: url.path)
        return url.path
    }

    /// A symbolic link whose own modification date (not its target's) is `days` old.
    private func link(_ path: String, to target: String, days: Double) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        let time = timeval(tv_sec: Int(Date(timeIntervalSinceNow: -days * 86_400).timeIntervalSince1970), tv_usec: 0)
        XCTAssertEqual([time, time].withUnsafeBufferPointer { lutimes(path, $0.baseAddress) }, 0)
    }

    private func cleaner() -> WallpaperDownloadCleaner { WallpaperDownloadCleaner(foldersRoot: root.path) }

    func testAnOldDownloadIsRemovedAndANewOneKept() throws {
        let old = try file("zz/rootdir/T/com.apple.idleassetsd/CFNetworkDownload_old.tmp", days: 10, bytes: 2_000_000)
        let new = try file("zz/rootdir/T/com.apple.idleassetsd/CFNetworkDownload_new.tmp", days: 1)
        let result = cleaner().execute()
        XCTAssertTrue(result.executed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.folders, 1)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertGreaterThanOrEqual(result.removedBytes, 2_000_000)
        XCTAssertEqual(result.keptRecentFiles, 1)
        XCTAssertFalse(fm.fileExists(atPath: old))
        XCTAssertTrue(fm.fileExists(atPath: new), "a download that may still be running stays")
        XCTAssertTrue(fm.fileExists(atPath: downloads), "the folder itself stays")
    }

    func testFilesWithAnotherNameAndSubfoldersAreKept() throws {
        let others = try [
            file("zz/rootdir/T/com.apple.idleassetsd/asset.mov", days: 30),
            file("zz/rootdir/T/com.apple.idleassetsd/CFNetworkDownload_.tmp", days: 30),
            file("zz/rootdir/T/com.apple.idleassetsd/CFNetworkDownload_a.tmp.part", days: 30),
            file("zz/rootdir/T/com.apple.idleassetsd/cfnetworkdownload_a.tmp", days: 30),
            file("zz/rootdir/T/com.apple.idleassetsd/sub/CFNetworkDownload_deep.tmp", days: 30),
        ]
        let result = cleaner().execute()
        XCTAssertEqual(result.removedFiles, 0)
        for path in others { XCTAssertTrue(fm.fileExists(atPath: path), path) }
    }

    func testFoldersOutsideThePatternAreNeverTouched() throws {
        let kept = try [
            file("zz/rootdir/T/com.apple.other/CFNetworkDownload_a.tmp", days: 30),
            file("zz/rootdir/C/com.apple.idleassetsd/CFNetworkDownload_a.tmp", days: 30),
            file("zz/rootdir/com.apple.idleassetsd/CFNetworkDownload_a.tmp", days: 30),
            file("zz/rootdir/T/x/com.apple.idleassetsd/CFNetworkDownload_a.tmp", days: 30),
            file("zz/com.apple.idleassetsd/CFNetworkDownload_a.tmp", days: 30),
            file("CFNetworkDownload_a.tmp", days: 30),
        ]
        let removed = try file("yy/someone/T/com.apple.idleassetsd/CFNetworkDownload_a.tmp", days: 30)
        let result = cleaner().execute()
        XCTAssertEqual(result.folders, 1)
        XCTAssertEqual(result.removedFiles, 1, "only the file in the pattern's folder")
        XCTAssertFalse(fm.fileExists(atPath: removed))
        for path in kept { XCTAssertTrue(fm.fileExists(atPath: path), path) }
    }

    func testSymbolicLinksAreRefused() throws {
        // A link with a download's name, pointing at an old file elsewhere: neither goes.
        let target = try file("CFNetworkDownload_target.tmp", in: outside, days: 30)
        let named = downloads + "/CFNetworkDownload_link.tmp"
        try link(named, to: target, days: 30)
        // A link in place of a folder on the way: what it points to is never reached.
        let elsewhere = try file("T/com.apple.idleassetsd/CFNetworkDownload_a.tmp", in: outside, days: 30)
        try link(root.appendingPathComponent("zz/linked").path, to: outside.path, days: 30)
        try link(root.appendingPathComponent("zz/linkedT/T").path, to: outside.appendingPathComponent("T").path, days: 30)
        try link(root.appendingPathComponent("zz/linkedFolder/T/com.apple.idleassetsd").path,
                 to: outside.appendingPathComponent("T/com.apple.idleassetsd").path, days: 30)

        let result = cleaner().execute()
        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertEqual(result.refusedEntries, 1)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: named), "the link stays")
        XCTAssertTrue(fm.fileExists(atPath: target), "what it points to stays")
        XCTAssertTrue(fm.fileExists(atPath: elsewhere), "folders behind a link are never entered")
    }

    func testMissingRootIsReported() {
        XCTAssertFalse(WallpaperDownloadCleaner(foldersRoot: "/nonexistent-\(UUID().uuidString)").execute().executed)
    }

    func testTheHelperOperationTakesNoPath() throws {
        let handler = SystemDataPrivilegedOperations()
        XCTAssertTrue(handler.operations.contains(SystemDataPrivilegedOperations.deleteWallpaperDownloads))
        XCTAssertEqual(SystemDataPrivilegedOperations.deleteWallpaperDownloads, "systemdata.wallpaper-downloads.delete")
    }

    // MARK: The page

    private func snapshot(downloads bytes: UInt64) -> SystemDataSnapshot {
        let items = ["zz/rootdir", "yy/other"].map { folder in
            SystemDataItem(id: "downloads:idleassetsd:\((folder as NSString).lastPathComponent)", title: "Wallpaper and screen saver downloads", kind: .systemLibrary,
                           paths: ["/private/var/folders/\(folder)/T/com.apple.idleassetsd"], bytes: bytes / 2, readable: true, owners: [], inUse: false,
                           cleanup: SystemDataCleanup(kind: .review, description: "d", command: nil), notes: [])
        }
        return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: items, measuredBytes: 0, cleanableBytes: 0,
                                                           manualCleanup: [], unreadable: [], warnings: []),
                                  purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []),
                                  takenAt: Date())
    }

    func testThePageOffersTheDeletionInFreeNowAndCleanLeavesItOut() throws {
        let snap = snapshot(downloads: 200_000_000_000)
        guard case let .section(section)? = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = section.widgets[0] else { return XCTFail() }
        let row = try XCTUnwrap(list.rows.first { $0.id == "wallpaper-downloads" })
        XCTAssertEqual(row.trailing, ByteFormat.string(200_000_000_000), "both folders in one row")
        let action = try XCTUnwrap(row.actions.first)
        XCTAssertEqual(action.id, "deleteWallpaperDownloads")
        XCTAssertEqual(action.requires, [.privilegedHelper])
        XCTAssertNotNil(action.confirmation)
        XCTAssertTrue(SystemDataScreenBuilder.leftAlone(snap).isEmpty, "listed once, under Free now")
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 0, "Clean and automatic cleaning leave it out")
        XCTAssertNil(SystemDataScreenBuilder.freeNow(snapshot(downloads: 10_000_000)), "too small for a row")
    }
}
