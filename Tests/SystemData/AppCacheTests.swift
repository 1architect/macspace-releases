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

    /// Recommended once the app is gone or the cache was left alone for 3 days (a week when no app can be named for it); a cache
    /// changed since comes back.
    func testTheOutcomeComesFromTheCachesDatesAndItsOwner() {
        let old = now.addingTimeInterval(-60 * day), recent = now.addingTimeInterval(-1 * day)
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: old), unchangedDays: 4), now: now), .suggested)
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: recent), unchangedDays: 4), now: now), .suggested,
                       "opened yesterday, but its cache untouched for days: it rebuilds what it needs")
        XCTAssertEqual(AppCaches.outcome(cache(.app(name: "A", lastOpened: nil), unchangedDays: 2), now: now), .comesBack)
        XCTAssertEqual(AppCaches.outcome(cache(.notInstalled, unchangedDays: 0), now: now), .suggested)
        XCTAssertEqual(AppCaches.outcome(cache(.unknown, unchangedDays: 5), now: now), .comesBack, "no app to ask: a week first")
        XCTAssertEqual(AppCaches.outcome(cache(.unknown, unchangedDays: 8), now: now), .suggested)
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

    /// One group under Free now, in parts: Recommended (checked), the apps' caches (unchecked; one whose app is open has no box),
    /// largest first in each, with pills instead of notes and no (i).
    func testCachesPageIsInPartsWithTheRecommendedChecked() throws {
        var suggested = cache(.notInstalled, unchangedDays: 45, bytes: 30_000_000)
        suggested.id = "appcache:gone"
        var offered = cache(.unknown, unchangedDays: 5, bytes: 10_000_000)
        offered.id = "appcache:tool"
        var inUse = cache(.unknown, unchangedDays: 1, bytes: 90_000_000)
        inUse.id = "appcache:busy"
        var running = cache(.unknown, unchangedDays: 1, bytes: 300_000_000)
        running.id = "appcache:open"
        running.ownerRunning = true
        let row = try XCTUnwrap(CachesPage.row(snapshot([offered, inUse, suggested, running]), now: now))
        let selection = try XCTUnwrap(row.selection)
        XCTAssertEqual(selection.sections.map(\.id), ["recommended", "apps"])
        XCTAssertEqual(selection.sections[1].rows, ["appcache:open", "appcache:busy", "appcache:tool"], "largest first")
        XCTAssertEqual(selection.checked, ["appcache:gone"])
        XCTAssertEqual(selection.suggested, ["appcache:gone"])
        XCTAssertNil(selection.choices["appcache:open"], "its app is open: the cleaner would refuse it")
        XCTAssertEqual(selection.action.id, "freeCaches")
        XCTAssertNotNil(selection.save)
        let gone = try XCTUnwrap(row.children.first { $0.id == "appcache:gone" })
        XCTAssertEqual(gone.badges.map(\.text), ["App cache", "App not installed"])
        XCTAssertNil(gone.detail)
        XCTAssertEqual(row.children.first { $0.id == "appcache:open" }?.badges.map(\.text), ["Open now", "Unknown app"])
        XCTAssertEqual(row.children.first { $0.id == "appcache:busy" }?.badges.map(\.text), ["Unknown app"],
                       "the part's title says it comes back; the pill says only what it does not")
        XCTAssertEqual(row.children.first { $0.id == "appcache:tool" }?.badges.map(\.text), ["Unknown app"])
    }

    /// The user's choice is kept: what they checked, and every cache of a part whose box is on, newcomers too.
    func testTheSavedChoiceDecidesWhatIsFreed() throws {
        var gone = cache(.notInstalled, unchangedDays: 45, bytes: 30_000_000)
        gone.id = "appcache:gone"
        var busy = cache(.unknown, unchangedDays: 1, bytes: 90_000_000)
        busy.id = "appcache:busy"
        var other = cache(.unknown, unchangedDays: 2, bytes: 5_000_000)
        other.id = "appcache:other"
        var snap = snapshot([gone, busy, other])
        XCTAssertEqual(CachesPage.chosenBytes(snap, now: now), 30_000_000, "the recommendation until the user chooses")
        snap.choices = CacheChoices(chosen: ["appcache:busy"], all: [])
        XCTAssertEqual(CachesPage.chosenBytes(snap, now: now), 90_000_000)
        snap.choices = CacheChoices(chosen: [], all: ["apps"])
        XCTAssertEqual(CachesPage.chosenBytes(snap, now: now), 95_000_000, "the whole part")
        XCTAssertEqual(CachesPage.row(snap, now: now)?.selection?.sections.map(\.all), [false, true])
    }

    /// A cache listed on the caches page is not listed again in its block's page; what it is taken from goes to "can be freed".
    func testCachesAreListedOnce() {
        var gone = cache(.notInstalled, unchangedDays: 45, bytes: 60_000_000)
        gone.id = "appcache:gone"
        gone.path = "/c/gone"
        let item = SystemDataItem(id: "appcache:gone", title: "App cache: gone", kind: .appCache, paths: ["/c/gone"], bytes: 60_000_000, readable: true,
                                  owners: [], inUse: false, cleanup: SystemDataCleanup(kind: .review, description: "", command: nil), notes: [])
        let snap = snapshot([gone], items: [item])
        let blocks = SystemDataScreenBuilder.blocksWithItems(snap)
        XCTAssertNil(blocks.first { $0.id == "caches" }, "all of it is on the caches page")
        XCTAssertEqual(blocks.first { $0.id == "freeable" }?.items.map(\.id), ["caches"])
        XCTAssertTrue(SystemDataScreenBuilder.leftAlone(snap).isEmpty)
    }

    /// Homebrew's old versions are recommended; its downloads are offered on their own, saying they come back.
    func testHomebrewIsTwoDeveloperCaches() {
        var snap = snapshot([])
        snap.homebrew = HomebrewCleanup.Plan(brew: "/b", standard: .init(bytes: 33_400_000, error: nil), allDownloads: .init(bytes: 138_200_000, error: nil))
        let entries = CachesPage.entries(snap, now: now)
        XCTAssertEqual(entries.map(\.id), [CachesPage.homebrewDownloads, CachesPage.homebrewOld])
        XCTAssertEqual(entries.last?.recommended, true)
        XCTAssertEqual(entries.first?.bytes, 104_800_000)
        snap.homebrew?.standard = .init(bytes: nil, error: "Refusing to load cask")
        XCTAssertEqual(CachesPage.entries(snap, now: now).map(\.id), [CachesPage.homebrewDownloads])
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

    /// The Trash is freed with its own button, which cannot be undone, never with Clean; Open shows it in the Finder, and the row says
    /// whether the Finder empties it by itself.
    func testTheTrashRowFreesOrOpensTheTrashAndNamesFindersOwnSetting() throws {
        var snap = snapshot([], items: [SystemDataItem(id: "trash:user", title: "Trash", kind: .trash, paths: ["/t"], bytes: 5_000_000, readable: true,
                                                      owners: [], inUse: false, cleanup: SystemDataCleanup(kind: .review, description: "", command: nil), notes: [])])
        let row = try XCTUnwrap(SystemDataScreenBuilder.trashRow(snap)?.row)
        XCTAssertEqual(row.actions.map(\.id), ["emptyTrash", "openTrash"])
        XCTAssertEqual(row.actions.first?.title, "Free")
        XCTAssertNotNil(row.actions.first?.confirmation, "emptying the Trash asks first")
        XCTAssertEqual(row.badge?.text, "Cannot be undone")
        XCTAssertTrue(row.detail?.contains("Finder > Settings > Advanced") == true)
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 0, "Clean never empties the Trash")
        snap.trashEmptiesItself = true
        XCTAssertEqual(SystemDataScreenBuilder.trashRow(snap)?.row.badges.map(\.text), ["Cannot be undone", "Empties after 30 days"])
    }

    func testEmptyingTheTrashDeletesEverythingInIt() throws {
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trash) }
        try FileManager.default.createDirectory(at: trash.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: trash.appendingPathComponent("Folder/a"))
        try Data(count: 1_000).write(to: trash.appendingPathComponent("b.pdf"))
        let result = SystemDataModule.emptyTrash(trash: trash)
        XCTAssertNotEqual(result.outcome, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path), "the Trash folder itself stays")
        XCTAssertEqual(SystemDataModule.emptyTrash(trash: trash).outcome, .failed, "an empty Trash has nothing to free")
    }

    /// The file's and folder's dates set back, as an app that last used its cache weeks ago leaves them.
    private func age(_ url: URL, days: Double) throws {
        let date = now.addingTimeInterval(-days * day)
        var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        XCTAssertEqual(utimes(url.path, &times), 0)
        try fm.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }
}
