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

    // MARK: Sandboxed apps' containers

    private func write(_ relative: String, under base: URL, bytes: Int = 3_000_000) throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// With Full Disk Access, the caches folder of each third-party app's own container is measured as an app cache, owned by the
    /// container's bundle identifier; what macOS's services keep in it is left out. Apple's containers and group containers are not.
    func testTheInspectorMeasuresThirdPartyContainersCaches() throws {
        let home = root.appendingPathComponent("home")
        try write("Library/Containers/com.example.Sandboxed/Data/Library/Caches/com.example.Sandboxed/Cache.db", under: home)
        try write("Library/Containers/com.example.Sandboxed/Data/Library/Caches/com.apple.nsurlsessiond/Downloads/x.tmp", under: home, bytes: 2_000_000)
        try write("Library/Containers/com.example.Sandboxed/Data/Library/Preferences/com.example.Sandboxed.plist", under: home)
        try write("Library/Containers/com.apple.Notes/Data/Library/Caches/blob", under: home)
        try write("Library/Group Containers/group.com.example.shared/Library/Caches/blob", under: home)
        let locations = SystemDataLocations(home: home, userSystemDirectory: nil, systemPaths: [:])
        var inspector = SystemDataInspector(locations: locations, runningApps: { [] }, volumes: { [] }, claimedPlaces: { [] })
        inspector.hasFullDiskAccess = true
        inspector.processCheck = .none
        inspector.containerOwner = { id in (.app(name: "Sandboxed", lastOpened: nil), [id, "com.example.Host"]) }
        let caches = inspector.inspect().appCaches
        XCTAssertEqual(caches.map(\.id), ["containercache:com.example.Sandboxed"])
        let cache = try XCTUnwrap(caches.first)
        XCTAssertEqual(cache.container, "com.example.Sandboxed")
        XCTAssertEqual(cache.path, home.appendingPathComponent("Library/Containers/com.example.Sandboxed/Data/Library/Caches").path)
        XCTAssertEqual(cache.bundleIdentifiers, ["com.example.Sandboxed", "com.example.Host"])
        XCTAssertEqual(cache.title, "Sandboxed")
        XCTAssertEqual(Double(cache.bytes), 3_000_000, accuracy: 200_000, "macOS's background downloads are not counted")
        XCTAssertFalse(cache.ownerRunning)

        inspector.hasFullDiskAccess = false
        XCTAssertTrue(inspector.inspect().appCaches.isEmpty, "without Full Disk Access, containers are not read")
    }

    /// A container belongs to the app with its bundle identifier, or to the app whose identifier an extension's begins with; Apple's
    /// containers, and names that are not one folder's, have no caches folder to offer.
    func testAContainerBelongsToItsAppOrTheAppOfItsExtension() {
        let whatsApp = URL(fileURLWithPath: "/Applications/WhatsApp.app")
        let installed: (String) -> URL? = { $0 == "net.whatsapp.WhatsApp" ? whatsApp : nil }
        XCTAssertEqual(AppCaches.containerApp("net.whatsapp.WhatsApp", appURL: installed)?.bundleIdentifier, "net.whatsapp.WhatsApp")
        XCTAssertEqual(AppCaches.containerApp("net.whatsapp.WhatsApp.ServiceExtension", appURL: installed)?.bundleIdentifier, "net.whatsapp.WhatsApp")
        XCTAssertNil(AppCaches.containerApp("com.parallels.desktop.console.OpenInIE", appURL: installed), "an app that was removed")
        XCTAssertNil(AppCaches.containerCachesFolder(home: "/h", container: "com.apple.Notes"))
        XCTAssertNil(AppCaches.containerCachesFolder(home: "/h", container: "group.com.apple.notes"))
        XCTAssertNil(AppCaches.containerCachesFolder(home: "/h", container: "../x"))
        XCTAssertEqual(AppCaches.containerCachesFolder(home: "/h", container: "net.whatsapp.WhatsApp"), "/h/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches")
    }

    /// A container's app is running only by its bundle identifier, or by a process from inside its bundle: the Finder, always open, does
    /// not keep a Finder extension's caches, as it would by name.
    func testAContainersAppIsRunningByBundleIdentifierOnly() {
        let finder = RunningApp(bundleIdentifier: "com.apple.finder", name: "Finder")
        let ids = ["com.example.App.FinderSync", "com.example.App"]
        let appPath: (String) -> String? = { $0 == "com.example.App" ? "/Applications/Example.app" : nil }
        XCTAssertNotNil(ProcessCheck.runningOwner(ids, apps: [finder], processes: [], appPath: appPath), "by name, the Finder would count")
        XCTAssertNil(ProcessCheck.runningApp(ids, apps: [finder], processes: [], appPath: appPath))
        XCTAssertEqual(ProcessCheck.runningApp(ids, apps: [RunningApp(bundleIdentifier: "com.example.App", name: "Example")], processes: [], appPath: appPath), "Example")
        let fileExtension = RunningProcess(pid: 1, name: "FinderSync", executablePath: "/Applications/Example.app/Contents/PlugIns/FinderSync.appex/Contents/MacOS/FinderSync")
        let bundleOf: (String) -> String? = { $0.contains("FinderSync.appex") ? "com.example.App.FinderSync" : "com.example.App" }
        XCTAssertEqual(ProcessCheck.runningApp(ids, apps: [finder], processes: [fileExtension], appPath: appPath, bundleOf: bundleOf), "FinderSync",
                       "its extension runs")
        // The app's own container is kept by the app, not by an extension macOS keeps running while the app is closed (WhatsApp's).
        XCTAssertNil(ProcessCheck.runningApp(["com.example.App"], apps: [finder], processes: [fileExtension], appPath: appPath, bundleOf: bundleOf))
        let app = RunningProcess(pid: 2, name: "Example", executablePath: "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(ProcessCheck.runningApp(["com.example.App"], apps: [], processes: [app], appPath: appPath, bundleOf: bundleOf), "Example")
        XCTAssertEqual(ProcessCheck.bundleIdentifier(ofProgram: "/System/Applications/Calculator.app/Contents/MacOS/Calculator"), "com.apple.calculator")
    }

    /// Freeing a container's caches empties its caches folder, which stays, of all but macOS's own; nothing else in the container, nor
    /// another container, is touched, and the cleaner may delete nowhere else.
    func testFreeingAContainersCachesEmptiesOnlyItsCachesFolder() throws {
        let home = root.appendingPathComponent("home")
        let container = home.appendingPathComponent("Library/Containers/com.example.Sandboxed")
        let caches = container.appendingPathComponent("Data/Library/Caches")
        try write("Data/Library/Caches/com.example.Sandboxed/Cache.db", under: container)
        try write("Data/Library/Caches/thumbnails/a3f9c01b7e2d4f55.png", under: container)
        try write("Data/Library/Caches/com.apple.nsurlsessiond/Downloads/x.tmp", under: container)
        try write("Data/Library/Preferences/com.example.Sandboxed.plist", under: container)
        try write("Library/Containers/com.example.Other/Data/Library/Caches/blob", under: home)
        for url in [caches.appendingPathComponent("com.example.Sandboxed/Cache.db"), caches.appendingPathComponent("thumbnails/a3f9c01b7e2d4f55.png"),
                    caches.appendingPathComponent("com.example.Sandboxed"), caches.appendingPathComponent("thumbnails"), caches] {
            try age(url, days: 40)
        }
        var cache = AppCache(id: "containercache:com.example.Sandboxed", name: "com.example.Sandboxed", path: caches.path, bytes: 6_000_000,
                             lastChange: now.addingTimeInterval(-40 * day), recentBytes: 0, dataLikeBytes: 0, owner: .notInstalled)
        cache.container = "com.example.Sandboxed"
        cache.bundleIdentifiers = ["com.example.Sandboxed"]
        let cleaner = SystemDataCleaner(runningApps: { [RunningApp(bundleIdentifier: "com.apple.finder", name: "Finder")] }, processCheck: .none, freeSpace: { nil })
        let result = SystemDataModule.cleanAppCaches([cache.id], in: snapshot([cache]), now: now, home: home.path, cleaner: cleaner)
        XCTAssertNotEqual(result.outcome, .failed, result.details.joined(separator: "\n"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: caches.path), ["com.apple.nsurlsessiond"], "the folder stays, with macOS's own")
        XCTAssertTrue(fm.fileExists(atPath: container.appendingPathComponent("Data/Library/Preferences/com.example.Sandboxed.plist").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("Library/Containers/com.example.Other/Data/Library/Caches/blob").path))

        // Its roots are the chosen containers' caches folders: the rest of a container is outside them.
        let preferences = SystemDataItem(id: "x", title: "x", kind: .appCache, paths: [container.appendingPathComponent("Data/Library/Preferences").path],
                                         bytes: 1, readable: true, owners: ["com.example.Sandboxed"], inUse: false,
                                         cleanup: SystemDataCleanup(kind: .deleteWhenNotRunning, description: "", command: nil), notes: [])
        XCTAssertFalse(cleaner.clean([preferences], allowedRoots: [caches.standardizedFileURL.path], ownersAreBundleIdentifiers: true).results[0].deleted)
        // An Apple container is never freed, whatever the snapshot says.
        var apple = cache
        apple.id = "containercache:com.apple.Notes"
        apple.container = "com.apple.Notes"
        apple.path = home.appendingPathComponent("Library/Containers/com.apple.Notes/Data/Library/Caches").path
        XCTAssertEqual(SystemDataModule.cleanAppCaches([apple.id], in: snapshot([apple]), now: now, home: home.path, cleaner: cleaner).outcome, .failed)
    }

    /// A container's cache is an app cache of the caches page, under the same rules; one holding media named by people is not listed.
    /// It is listed there only: third-party containers are in no block or list of System Data's page.
    func testContainerCachesAreAppCachesListedOnce() throws {
        var gone = cache(.notInstalled, unchangedDays: 45, bytes: 40_000_000)
        gone.id = "containercache:com.example.Gone"
        gone.name = "com.example.Gone"
        gone.path = "/h/Library/Containers/com.example.Gone/Data/Library/Caches"
        gone.container = "com.example.Gone"
        var media = cache(.app(name: "Player", lastOpened: nil), unchangedDays: 45, dataLike: 60_000_000, bytes: 80_000_000)
        media.id = "containercache:com.example.Player"
        media.container = "com.example.Player"
        let container = SystemDataItem(id: "container:com.example.Gone", title: "App container: com.example.Gone", kind: .appContainer,
                                       paths: ["/h/Library/Containers/com.example.Gone"], bytes: 300_000_000, readable: true, owners: ["com.example.Gone"],
                                       inUse: false, cleanup: SystemDataCleanup(kind: .review, description: "", command: nil), notes: [])
        var snap = snapshot([gone, media], items: [container])
        snap.report.items[0].cachesBytes = 40_000_000
        let entries = CachesPage.entries(snap, now: now)
        XCTAssertEqual(entries.map(\.id), ["containercache:com.example.Gone"], "media named by people is never listed")
        XCTAssertEqual(entries.first?.within, "container:com.example.Gone")
        let row = try XCTUnwrap(CachesPage.row(snap, now: now))
        XCTAssertEqual(row.selection?.checked, ["containercache:com.example.Gone"])
        XCTAssertEqual(row.children.first?.badges.map(\.text), ["App cache", "App not installed"])
        XCTAssertEqual(row.children.first?.paths, [gone.path])
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 40_000_000)
        let listedElsewhere = SystemDataScreenBuilder.blocksWithItems(snap).filter { $0.id != "freeable" }.flatMap(\.items).map(\.id)
            + SystemDataScreenBuilder.leftAlone(snap).map(\.id)
        XCTAssertFalse(listedElsewhere.contains("container:com.example.Gone"))
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
        XCTAssertNotNil(selection.choices["appcache:open"], "its app is open: chosen, it is freed once MacSpace may quit the app")
        XCTAssertEqual(selection.noteNames.keys.sorted(), ["appcache:open"], "its app is named in the confirmation, which quits it")
        XCTAssertEqual(selection.note, "Quits %@.")
        XCTAssertEqual(selection.action.workingTitle, "Freeing space…")
        XCTAssertEqual(selection.action.id, "freeCaches")
        XCTAssertNotNil(selection.save)
        let gone = try XCTUnwrap(row.children.first { $0.id == "appcache:gone" })
        XCTAssertEqual(gone.badges.map(\.text), ["App cache", "App not installed"])
        XCTAssertNil(gone.detail)
        XCTAssertEqual(row.children.first { $0.id == "appcache:open" }?.badges.map(\.text), ["Open now"])
        XCTAssertEqual(row.children.first { $0.id == "appcache:busy" }?.badges.map(\.text), [],
                       "the part's title says it comes back; an app MacSpace cannot name gets no pill")
        XCTAssertEqual(row.children.first { $0.id == "appcache:tool" }?.badges.map(\.text), [])
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

    /// An open app's cache is chosen as any other, by its box or its part's; it has no button of its own, and the main Free's
    /// confirmation names the app it quits.
    func testAnOpenAppsCacheIsChosenLikeAnyOther() throws {
        var running = cache(.app(name: "Firefox", lastOpened: now), unchangedDays: 1, bytes: 300_000_000)
        running.id = "appcache:org.mozilla.firefox"
        running.name = "org.mozilla.firefox"
        running.ownerRunning = true
        var snap = snapshot([running])
        let row = try XCTUnwrap(CachesPage.row(snap, now: now))
        XCTAssertEqual(row.children.first?.actions, [])
        XCTAssertEqual(CachesPage.entries(snap, now: now).first?.owners, ["org.mozilla.firefox", "Firefox"])
        XCTAssertEqual(SystemDataScreenBuilder.cleanAll(snap)?.confirmation?.message ?? "", "", "not chosen: nothing quits")
        snap.choices = CacheChoices(chosen: [], all: ["apps"])
        XCTAssertEqual(CachesPage.chosenBytes(snap, now: now), 300_000_000, "the part's box takes it")
        XCTAssertEqual(SystemDataScreenBuilder.cleanAll(snap)?.confirmation?.message, "Quits Firefox.")
    }

    /// The apps quit for a cache are found as the cleaner finds them; a container's only by bundle identifier, and never MacSpace or
    /// the Finder.
    func testTheAppsQuitForACacheAreItsOwners() {
        let apps = [RunningApp(bundleIdentifier: "org.mozilla.firefox", name: "Firefox"), RunningApp(bundleIdentifier: "com.apple.finder", name: "Finder"),
                    RunningApp(bundleIdentifier: "com.macspace.app", name: "MacSpace"), RunningApp(bundleIdentifier: "com.example.Notes", name: "Notes")]
        XCTAssertEqual(AppQuitter.owning(["org.mozilla.firefox"], exact: true, apps: apps), [0])
        XCTAssertEqual(AppQuitter.owning(["Firefox"], exact: false, apps: apps), [0])
        XCTAssertEqual(AppQuitter.owning(["Firefox"], exact: true, apps: apps), [], "a container is named after its app's identifier")
        XCTAssertEqual(AppQuitter.owning(["com.apple.finder", "MacSpace"], exact: false, apps: apps), [])
        XCTAssertEqual(AppQuitter.owning(["com.example.FinderSync"], exact: false, apps: apps), [], "a short name inside another's is not it")
    }

    /// A program that is not an app is closed for its cache by the owner's exact name, as the cleaner finds it running; never one of
    /// macOS's programs, never MacSpace, never a process the apps already cover.
    func testTheToolsClosedForACacheAreFoundByTheCleanersRule() {
        let processes = [RunningProcess(pid: 10, name: "opencode", executablePath: "/opt/homebrew/bin/opencode"),
                         RunningProcess(pid: 11, name: "opencode-helper", executablePath: "/opt/homebrew/bin/opencode-helper"),
                         RunningProcess(pid: 12, name: "opencode", executablePath: "/usr/libexec/opencode"),
                         RunningProcess(pid: 13, name: "opencode", executablePath: "/Applications/OpenCode.app/Contents/MacOS/opencode"),
                         RunningProcess(pid: 99, name: "opencode", executablePath: "/x/opencode")]
        XCTAssertEqual(AppQuitter.tools(["opencode"], processes: processes, appPIDs: [13], ownPID: 99).map(\.pid), [10])
    }

    /// An app of macOS is never matched by name nor quit: "Siri" is in `SiriEntityCache`, and quitting it for that cache brought up
    /// the Siri orb (2026-10-13).
    func testAnAppOfMacOSIsNeverQuitForACache() {
        let siri = RunningApp(bundleIdentifier: "com.apple.siri.launcher", name: "Siri", system: true)
        XCTAssertEqual(AppQuitter.owning(["SiriEntityCache"], exact: false, apps: [siri]), [])
        XCTAssertNil(ProcessCheck.runningOwner(["SiriEntityCache"], apps: [siri], processes: [], appPath: { _ in nil }))
        XCTAssertTrue(RunningApp.isSystem(URL(fileURLWithPath: "/System/Library/CoreServices/Siri.app")))
        XCTAssertFalse(RunningApp.isSystem(URL(fileURLWithPath: "/Applications/Firefox.app")))
        // Apple's by rule, not by a list: it begins with an app of macOS's, then a word of its own.
        XCTAssertTrue(AppCaches.isApple("SiriEntityCache"))
        XCTAssertFalse(AppCaches.isApple("Siriusly"), "not at a word's start")
        XCTAssertFalse(AppCaches.isApple("FirefoxCache"), "not a name macOS has")
    }

    /// Settings › System Data decides who frees the caches: off, they are not on the caches page; another app, the page shows what
    /// can be freed and opens it, and neither Free nor automatic cleaning touches them.
    func testTheCacheCleanerChosenInSettings() throws {
        var gone = cache(.notInstalled, unchangedDays: 45, bytes: 30_000_000)
        gone.id = "appcache:gone"
        var snap = snapshot([gone])
        snap.cleaner = .off
        XCTAssertNil(CachesPage.row(snap, now: now))
        XCTAssertEqual(CachesPage.chosenBytes(snap, now: now), 0)
        snap.cleaner = .app(name: "OnyX", url: URL(fileURLWithPath: "/Applications/OnyX.app"))
        let row = try XCTUnwrap(CachesPage.row(snap, now: now))
        XCTAssertEqual(row.trailing, ByteFormat.string(30_000_000))
        XCTAssertEqual(row.actions.map(\.id), ["openCleaner"])
        XCTAssertTrue(row.children.isEmpty, "no page of boxes: the other app chooses")
        XCTAssertEqual(CachesPage.chosenBytes(snap, now: now), 0)
    }

    /// The choice reads the app it names from the manifest; one that is not installed falls back to MacSpace.
    func testACleanerThatIsNotInstalledFallsBackToMacSpace() {
        let manifest = ModuleManifest(id: "m", name: "M", summary: "", version: "1", symbol: "x", options: [
            OptionDefinition(id: CacheCleaner.switchID, title: "Free caches", kind: .toggle(defaultValue: true)),
            OptionDefinition(id: CacheCleaner.choiceID, title: "Cache cleaner", kind: .choice(options: [
                OptionChoice(id: "macspace", title: "MacSpace"), OptionChoice(id: "onyx", title: "OnyX", apps: ["com.titanium.OnyX"]),
            ], defaultValue: "macspace"), under: CacheCleaner.switchID),
        ])
        func context(_ on: Bool, _ choice: String) -> ModuleContext {
            ModuleContext(manifest: manifest, options: Options(on: on, choice: choice), permissions: NoPermissions())
        }
        let onyx = URL(fileURLWithPath: "/Applications/OnyX.app")
        XCTAssertEqual(CacheCleaner.read(context(false, "onyx"), locate: { _ in onyx }), .off)
        XCTAssertEqual(CacheCleaner.read(context(true, "macspace"), locate: { _ in onyx }), .macSpace)
        XCTAssertEqual(CacheCleaner.read(context(true, "onyx"), locate: { $0 == "com.titanium.OnyX" ? onyx : nil }), .app(name: "OnyX", url: onyx))
        XCTAssertEqual(CacheCleaner.read(context(true, "onyx"), locate: { _ in nil }), .macSpace)
    }

    private struct Options: OptionStore {
        let on: Bool
        let choice: String
        func bool(_ id: String) -> Bool { on }
        func string(_ id: String) -> String { choice }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }

    private struct NoPermissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
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
        XCTAssertEqual(row.actions.map(\.id), ["emptyTrash"])
        XCTAssertEqual(row.paths, [SystemDataScreenBuilder.trashPath], "the folder pill shows it in the Finder")
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
