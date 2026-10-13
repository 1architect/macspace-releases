import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceSystemData

/// The third-party caches nothing uses (`AppCaches`), Homebrew's cleanup (`HomebrewCleanup`) and the Trash row.
final class AppCacheTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_791_800_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("macspace-appcache-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func cache(_ owner: AppCache.Owner, unchangedDays: Double, dataLike: UInt64 = 0, bytes: UInt64 = 20_000_000) -> AppCache {
        AppCache(id: "appcache:x", name: "x", path: "/x", bytes: bytes, lastChange: now.addingTimeInterval(-unchangedDays * day), recentBytes: 0,
                 dataLikeBytes: dataLike, owner: owner)
    }

    /// Time first, owner second: a month unchanged with its app not opened for as long (or not installed) is suggested; an owner that
    /// cannot be told is only offered; a cache that changed this week, or whose app was opened this month, comes back.
    func testTheOutcomeComesFromTheCachesDatesAndItsAppsLastLaunch() {
        let old = now.addingTimeInterval(-60 * day), recent = now.addingTimeInterval(-3 * day)
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: old), unchangedDays: 45), now: now), .suggested)
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: recent), unchangedDays: 45), now: now), .comesBack,
                       "an app opened this month may only read its cache, which leaves no date")
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: old), unchangedDays: 10), now: now), .offered)
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: nil), unchangedDays: 45), now: now), .offered)
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: nil), unchangedDays: 10), now: now), .comesBack)
        XCTAssertEqual(AppCaches.outcome(cache(.notInstalled, unchangedDays: 45), now: now), .suggested)
        XCTAssertEqual(AppCaches.outcome(cache(.notInstalled, unchangedDays: 10), now: now), .offered)
        XCTAssertEqual(AppCaches.outcome(cache(.unknown, unchangedDays: 400), now: now), .offered, "an unknown owner is never suggested")
        XCTAssertEqual(AppCaches.outcome(cache(.unknown, unchangedDays: 2), now: now), .comesBack)
        XCTAssertEqual(AppCaches.outcome(cache(.notInstalled, unchangedDays: 90, dataLike: 60_000_000), now: now), .heldBack)
    }

    func testMediaAndDocumentsWithPeoplesNamesLookLikeData() {
        XCTAssertTrue(AppCaches.isDataLike("Episode 12.mp3"))
        XCTAssertTrue(AppCaches.isDataLike("Report.pdf"))
        XCTAssertFalse(AppCaches.isDataLike("a3f9c01b7e2d4f55.mp4"), "a key, not a name")
        XCTAssertFalse(AppCaches.isDataLike("thumbnail.jpg"), "images are what caches hold")
        XCTAssertFalse(AppCaches.isDataLike("Cache.db"))
    }

    /// Apple's by a name macOS has on its system volume, compared exactly: the disk ignores case, and `pip` is not `PIP.framework`.
    func testAppleNamesAreMatchedExactly() {
        XCTAssertTrue(AppCaches.isApple("PassKit"))
        XCTAssertFalse(AppCaches.isApple("pip"))
        XCTAssertFalse(AppCaches.isApple("passkit"))
        XCTAssertFalse(AppCaches.isApple("Firefox"))
    }

    func testOnlyNamesWithTwoDotsAreBundleIdentifiers() {
        XCTAssertTrue(AppCaches.looksLikeBundleIdentifier("com.example.App"))
        XCTAssertFalse(AppCaches.looksLikeBundleIdentifier("Firefox"))
        XCTAssertFalse(AppCaches.looksLikeBundleIdentifier("Sublime Text"))
        XCTAssertFalse(AppCaches.looksLikeBundleIdentifier("pip"))
    }

    /// The folder's dates are read from the file system alone: its newest file write, creation or first read, and its folders' writes.
    func testTheFoldersLastChangeIsItsNewestDate() throws {
        let folder = root.appendingPathComponent("com.example.Old")
        try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sub/blob")
        try Data(count: 2_000_000).write(to: file)
        try age(file, days: 40)
        try age(folder.appendingPathComponent("sub"), days: 40)
        try age(folder, days: 40)
        let measured = try XCTUnwrap(AppCaches.measure(folder.path, now: now))
        XCTAssertEqual(measured.lastChange.timeIntervalSince1970, now.addingTimeInterval(-40 * day).timeIntervalSince1970, accuracy: 2)
        XCTAssertEqual(measured.recentBytes, 0)
    }

    /// The inspector lists every third-party cache folder, whatever its size, but not Apple's (by prefix or by a name macOS has on its
    /// system volume) nor MacSpace's own.
    func testTheInspectorListsThirdPartyCachesOfEverySize() throws {
        let caches = root.appendingPathComponent("home/Library/Caches")
        for name in ["com.example.Small", "com.apple.Something", "PassKit", "com.macspace.app"] {
            try fm.createDirectory(at: caches.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(count: 3_000_000).write(to: caches.appendingPathComponent("\(name)/blob"))
        }
        let locations = SystemDataLocations(home: root.appendingPathComponent("home"), userSystemDirectory: nil, systemPaths: [:])
        var inspector = SystemDataInspector(locations: locations, runningApps: { [] }, volumes: { [] }, claimedPlaces: { [] })
        inspector.hasFullDiskAccess = true
        inspector.appCacheOwner = { _ in .notInstalled }
        let listed = inspector.inspect().appCaches
        XCTAssertEqual(listed.map(\.name), ["com.example.Small"])
        XCTAssertEqual(Double(listed.first?.bytes ?? 0), 3_000_000, accuracy: 200_000)
    }

    // MARK: The page

    private func snapshot(_ caches: [AppCache], items: [SystemDataItem] = []) -> SystemDataSnapshot {
        var report = SystemDataReport(schemaVersion: 1, generatedAt: now, volumes: [], items: items, measuredBytes: 0, cleanableBytes: 0,
                                      manualCleanup: [], unreadable: [], warnings: [])
        report.appCaches = caches
        return SystemDataSnapshot(report: report, purgeableAssetsBytes: nil,
                                  reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []),
                                  takenAt: now)
    }

    /// One group under Free now; its page lets the user choose, with the suggested ones checked: what nothing uses first, then the
    /// caches in use (unchecked, saying they come back), and never one whose app is running.
    func testAppCachesAreAGroupWhosePageLetsTheUserChoose() throws {
        var suggested = cache(.notInstalled, unchangedDays: 45, bytes: 30_000_000)
        suggested.id = "appcache:gone"
        var offered = cache(.unknown, unchangedDays: 20, bytes: 10_000_000)
        offered.id = "appcache:tool"
        var inUse = cache(.unknown, unchangedDays: 1, bytes: 90_000_000)
        inUse.id = "appcache:busy"
        inUse.recentBytes = 40_000_000
        var running = cache(.unknown, unchangedDays: 1, bytes: 300_000_000)
        running.id = "appcache:open"
        running.ownerRunning = true
        let row = try XCTUnwrap(SystemDataScreenBuilder.appCachesRow(snapshot([offered, inUse, suggested, running]), now: now))
        XCTAssertEqual(row.children.map(\.id), ["appcache:gone", "appcache:tool", "appcache:busy"])
        XCTAssertEqual(row.selection?.checked, ["appcache:gone"])
        XCTAssertEqual(row.selection?.choices["appcache:busy"], 90_000_000)
        XCTAssertNil(row.selection?.choices["appcache:open"], "its app is open: the cleaner would refuse it")
        XCTAssertEqual(row.selection?.action.id, "cleanAppCaches")
        XCTAssertNotNil(row.selection?.action.confirmation)
        XCTAssertEqual(row.children.first?.subtitle, "App not installed")
        XCTAssertEqual(row.children.last?.subtitle, "Comes back as it is used")
        XCTAssertTrue(row.children.last?.detail?.contains(ByteFormat.string(40_000_000)) == true)
        XCTAssertEqual(row.children.first?.paths, ["/x"])
        XCTAssertNil(SystemDataScreenBuilder.appCachesRow(snapshot([running]), now: now))
    }

    /// The rows with buttons of their own are not part of what Clean frees, so not of the "can be freed" block.
    func testOwnButtonRowsAreNotInTheFreeableBlock() {
        var gone = cache(.notInstalled, unchangedDays: 45, bytes: 30_000_000)
        gone.id = "appcache:gone"
        var snap = snapshot([gone], items: [SystemDataItem(id: "trash:user", title: "Trash", kind: .trash, paths: ["/t"], bytes: 5_000_000, readable: true,
                                                          owners: [], inUse: false, cleanup: SystemDataCleanup(kind: .review, description: "", command: nil),
                                                          notes: [])])
        snap.homebrew = HomebrewCleanup.Plan(brew: "/b", standard: .init(bytes: 33_000_000, error: nil), allDownloads: .init(bytes: 138_000_000, error: nil))
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 0)
        let freeable = SystemDataScreenBuilder.blocksWithItems(snap).first { $0.id == "freeable" }
        XCTAssertNil(freeable)
    }

    /// Homebrew's two ways, each with what its dry run said; when its default stops on a tap it does not trust, the other way stays,
    /// with the reason.
    func testHomebrewOffersBothWaysOrSaysWhyOneStopped() throws {
        var snap = snapshot([])
        snap.homebrew = HomebrewCleanup.Plan(brew: "/b", standard: .init(bytes: 33_400_000, error: nil), allDownloads: .init(bytes: 138_200_000, error: nil))
        let both = try XCTUnwrap(SystemDataScreenBuilder.homebrewRow(snap))
        XCTAssertEqual(both.actions.map { $0.parameters["all"] }, ["false", "true"])
        XCTAssertEqual(both.trailing, ByteFormat.string(33_400_000))
        snap.homebrew?.standard = .init(bytes: nil, error: "Refusing to load cask 1architect/macspace/macspace from untrusted tap 1architect/macspace.")
        let one = try XCTUnwrap(SystemDataScreenBuilder.homebrewRow(snap))
        XCTAssertEqual(one.actions.map { $0.parameters["all"] }, ["true"])
        XCTAssertTrue(one.detail?.contains("untrusted tap") == true)
        snap.homebrew = nil
        XCTAssertNil(SystemDataScreenBuilder.homebrewRow(snap))
    }

    func testHomebrewsOutputIsRead() {
        XCTAssertEqual(HomebrewCleanup.freed("Would remove: /x (1B)\n==> This operation would free approximately 138.2MB of disk space.\n"), 138_200_000)
        XCTAssertEqual(HomebrewCleanup.freed("==> This operation has freed approximately 1.5GB of disk space."), 1_500_000_000)
        XCTAssertNil(HomebrewCleanup.freed(""))
        XCTAssertEqual(HomebrewCleanup.errorLine("Warning: x\nError: Refusing to load cask a/b/c from untrusted tap a/b.\nRun `brew trust`"),
                       "Refusing to load cask a/b/c from untrusted tap a/b.")
        XCTAssertEqual(HomebrewCleanup.arguments(allDownloads: true, dryRun: true), ["cleanup", "-n", "--prune=all"])
        XCTAssertTrue(HomebrewCleanup.isRunning("/opt/homebrew/bin/brew", processes: [RunningProcess(pid: 1, name: "ruby",
                                                                                                    executablePath: "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby")]))
        XCTAssertFalse(HomebrewCleanup.isRunning("/opt/homebrew/bin/brew", processes: [RunningProcess(pid: 1, name: "ruby", executablePath: "/usr/bin/ruby")]))
    }

    func testTheTrashRowOpensTheTrashAndNamesFindersOwnSetting() throws {
        var snap = snapshot([], items: [SystemDataItem(id: "trash:user", title: "Trash", kind: .trash, paths: ["/t"], bytes: 5_000_000, readable: true,
                                                      owners: [], inUse: false, cleanup: SystemDataCleanup(kind: .review, description: "", command: nil), notes: [])])
        let row = try XCTUnwrap(SystemDataScreenBuilder.trashRow(snap))
        XCTAssertEqual(row.actions.map(\.id), ["openTrash"])
        XCTAssertTrue(row.detail?.contains("Finder > Settings > Advanced") == true)
        snap.trashEmptiesItself = true
        XCTAssertTrue(SystemDataScreenBuilder.trashRow(snap)?.detail?.contains("Finder deletes items") == true)
    }

    /// The file's and folder's dates set back, as an app that last used its cache weeks ago leaves them.
    private func age(_ url: URL, days: Double) throws {
        let date = now.addingTimeInterval(-days * day)
        var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        XCTAssertEqual(utimes(url.path, &times), 0)
        try fm.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }
}
