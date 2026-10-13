import XCTest
@testable import MacSpaceSystemData
import MacSpacePlatform

final class SystemDataTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("macspace-sysdata-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func file(_ relative: String, mb: Int) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: mb * 1_000_000).write(to: url)
    }

    private var locations: SystemDataLocations {
        SystemDataLocations(home: root.appendingPathComponent("home"), userSystemDirectory: root.appendingPathComponent("folders"),
                            systemPaths: ["commandLineTools": root.appendingPathComponent("clt").path])
    }

    private func inspector(running: [RunningApp] = [], fullDiskAccess: Bool = true, apps: [String] = [], processes: ProcessCheck = .none) -> SystemDataInspector {
        var inspector = SystemDataInspector(locations: locations, runningApps: { running }, volumes: { [VolumeUsage(name: "Data", roles: ["Data"], usedBytes: 1)] },
                                            claimedPlaces: { apps })
        inspector.hasFullDiskAccess = fullDiskAccess
        inspector.processCheck = processes
        return inspector
    }

    /// Homebrew is only where its `brew` is: on Apple silicon `/usr/local` holds other tools, which were counted as Homebrew and
    /// opened a second Finder window from its row. Without Homebrew, `/usr/local` is an item of its own.
    func testHomebrewIsOnlyWhereItsBrewIs() throws {
        try file("opt/homebrew/Cellar/x/data", mb: 60)
        try file("usrlocal/bin/node", mb: 70)
        let brew = root.appendingPathComponent("opt/homebrew/bin/brew")
        try fm.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        let locations = SystemDataLocations(home: root.appendingPathComponent("home"), userSystemDirectory: nil,
                                            systemPaths: ["homebrew": root.appendingPathComponent("opt/homebrew").path, "usrLocal": root.appendingPathComponent("usrlocal").path])
        var inspector = SystemDataInspector(locations: locations, runningApps: { [] }, volumes: { [] }, claimedPlaces: { [] })
        inspector.processCheck = .none
        let report = inspector.inspect()
        XCTAssertEqual(report.items.first { $0.id == "packages:homebrew" }?.paths, [root.appendingPathComponent("opt/homebrew").path])
        XCTAssertEqual(report.items.first { $0.id == "usrlocal" }?.paths, [root.appendingPathComponent("usrlocal").path])
    }

    func testWithoutFullDiskAccessProtectedFoldersAreSkippedAndReported() throws {
        try file("home/Library/Containers/net.whatsapp.WhatsApp/Data/cache", mb: 110)
        try file("home/Library/CloudStorage/OneDrive-X/big.pdf", mb: 120)
        try file("home/Downloads/x.ipsw", mb: 600)
        try file("home/Library/Application Support/BigApp/data", mb: 120)
        let report = inspector(fullDiskAccess: false).inspect()
        let ids = Set(report.items.map(\.id))
        XCTAssertFalse(ids.contains("container:net.whatsapp.WhatsApp"))
        XCTAssertFalse(ids.contains("cloud:OneDrive-X"))
        XCTAssertFalse(ids.contains("ipsw:x.ipsw"))
        XCTAssertTrue(ids.contains("appsupport:BigApp"), "unprotected places are still measured")
        for name in ["Library/Containers", "Library/CloudStorage", "Downloads"] {
            XCTAssertTrue(report.unreadable.contains(root.appendingPathComponent("home/\(name)").path), name)
        }
        let withAccess = Set(inspector().inspect().items.map(\.id))
        XCTAssertTrue(withAccess.isSuperset(of: ["container:net.whatsapp.WhatsApp", "cloud:OneDrive-X", "ipsw:x.ipsw"]))
    }

    /// A code-signing copy shares its blocks with the app: an APFS clone of it.
    private func copy(ofApp relative: String, as clone: String) throws {
        let source = root.appendingPathComponent(relative), destination = root.appendingPathComponent(clone)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(clonefile(source.path, destination.path, 0), 0, "the test folder is on APFS")
    }

    func testClassifiesClonesCachesAndAppleCaches() throws {
        try file("apps/Big.app/Contents/MacOS/Big", mb: 60)
        try copy(ofApp: "apps/Big.app/Contents/MacOS/Big", as: "folders/X/com.example.Big.code_sign_clone/code_sign_clone.abc123/Big.app/Contents/MacOS/Big")
        try file("folders/C/clang/ModuleCache/a.pcm", mb: 55)
        try file("home/Library/Caches/com.example.Tool/blob", mb: 70)
        try file("home/Library/Caches/com.apple.Safari/blob", mb: 80)
        try file("home/Library/Caches/tiny/blob", mb: 1)
        try file("home/Library/Caches/.DS_Store", mb: 0)
        try file("home/Library/Application Support/BigApp/data", mb: 120)
        try file("clt/usr/bin/clang", mb: 2)

        let report = inspector(running: [RunningApp(bundleIdentifier: "com.example.Big", name: "Big")]).inspect()
        let byID = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
        XCTAssertEqual(byID["clone:com.example.Big"]?.cleanup.kind, .deleteWhenNotRunning)
        XCTAssertLessThan(byID["clone:com.example.Big"]?.expectedReclaimBytes ?? .max, 1_000_000, "a copy that shares its app's blocks frees ~nothing (measured)")
        XCTAssertEqual(byID["clone:com.example.Big"]?.title, "Big", "named after the app inside")
        XCTAssertEqual(byID["clone:com.example.Big"]?.inUse, true)
        XCTAssertEqual(byID["usercache:clang"]?.cleanup.kind, .deleteWhenNotRunning)
        XCTAssertEqual(byID["appcache:com.example.Tool"]?.cleanup.kind, .review, "third-party app caches are outside System Data cleanup")
        XCTAssertEqual(byID["appcache:com.apple.Safari"]?.cleanup.kind, .managedByMacOS, "Apple daemon caches are never offered")
        XCTAssertNil(byID["appcache:tiny"], "below the listing threshold")
        XCTAssertNil(byID["appcache:.DS_Store"])
        XCTAssertEqual(byID["appsupport:BigApp"]?.cleanup.kind, .review)
        XCTAssertEqual(byID["developer:commandLineTools"]?.cleanup.kind, .review, "small fixed items are still shown")
        XCTAssertTrue(report.unreadable.isEmpty, "single files are not unreadable folders")
        XCTAssertEqual(report.volumes.first?.name, "Data")
        XCTAssertGreaterThanOrEqual(report.cleanableBytes, 55_000_000, "the system cache, not the shared copy or app caches")
        XCTAssertLessThan(report.cleanableBytes, 100_000_000)
    }

    /// Electron and Chromium apps keep their web caches in Application Support. Found in any app's profile by name, cleaned while the
    /// app is closed, and taken off the app's own figure so nothing counts twice; a folder named Cache outside a profile is data.
    func testChromiumCachesInApplicationSupportAreCleanableAndCountedOnce() throws {
        try file("home/Library/Application Support/Chatty/Network Persistent State", mb: 0)
        try file("home/Library/Application Support/Chatty/Cache/Cache_Data/blob", mb: 60)
        try file("home/Library/Application Support/Chatty/Code Cache/js/blob", mb: 20)
        try file("home/Library/Application Support/Chatty/Local Storage/leveldb/data", mb: 40)
        try file("home/Library/Application Support/Chatty/IndexedDB/data", mb: 30)
        try file("home/Library/Application Support/Google/Chrome/Local State", mb: 0)
        try file("home/Library/Application Support/Google/Chrome/Default/Network Persistent State", mb: 0)
        try file("home/Library/Application Support/Google/Chrome/Default/GPUCache/data", mb: 55)
        try file("home/Library/Application Support/Plain/Cache/project.db", mb: 120)

        let report = inspector().inspect()
        let byID = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
        let chatty = try XCTUnwrap(byID["supportcache:Chatty"])
        XCTAssertEqual(chatty.cleanup.kind, .deleteWhenNotRunning)
        XCTAssertEqual(Set(chatty.paths.map { ($0 as NSString).lastPathComponent }), ["Cache", "Code Cache"], "never Local Storage or IndexedDB")
        let support = try XCTUnwrap(byID["appsupport:Chatty"]?.bytes)
        XCTAssertLessThan(support, 75_000_000, "the app's own figure no longer holds its caches")
        XCTAssertEqual(byID["supportcache:Google"]?.paths.map { ($0 as NSString).lastPathComponent }, ["GPUCache"], "a profile two levels down")
        XCTAssertTrue(byID["supportcache:Google"]?.owners.contains("Google Chrome") == true, "the running check finds the browser by its name")
        XCTAssertNil(byID["supportcache:Plain"], "a folder named Cache outside a Chromium profile is the app's data")

        let closed = inspector(running: [RunningApp(bundleIdentifier: "com.example.chatty", name: "Chatty")]).inspect()
        XCTAssertEqual(closed.items.first { $0.id == "supportcache:Chatty" }?.inUse, true, "not offered while the app runs")

        let cleaner = SystemDataCleaner(runningApps: { [] }, processCheck: .none, freeSpace: { nil })
        let roots = SystemDataCleaner.allowedRoots(locations)
        XCTAssertTrue(cleaner.clean([chatty], allowedRoots: roots).results.allSatisfy(\.deleted))
        XCTAssertFalse(fm.fileExists(atPath: chatty.paths[0]))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("home/Library/Application Support/Chatty/Local Storage/leveldb/data").path))
        // Anything else in Application Support is refused, whatever an item says.
        var data = chatty
        data = SystemDataItem(id: "x", title: "x", kind: .appCache, paths: [root.appendingPathComponent("home/Library/Application Support/Chatty/IndexedDB").path],
                              bytes: 1, readable: true, owners: [], inUse: false, cleanup: data.cleanup, notes: [])
        XCTAssertFalse(cleaner.clean([data], allowedRoots: roots).results[0].deleted)
    }

    /// What System Settings lists in another category is not System Data: an app inside a measured folder (an installer's helper
    /// app, a tool's own app) is taken off it, an item in a claimed place or in the home folder outside ~/Library (Documents) is left
    /// out whole, and the apps Spotlight finds are counted once even when they nest.
    /// Containers too small to list are summed apart: Apple's are System Data, third-party ones are Settings' Applications. Summed
    /// together, Apple's (0.73 GB on the development Mac) were left out with the others and ended up in "not identified".
    func testSmallAppleContainersAreSummedApartFromThirdPartyOnes() throws {
        try file("home/Library/Containers/com.apple.Notes/Data/a", mb: 2)
        try file("home/Library/Group Containers/group.com.apple.notes/b", mb: 3)
        try file("home/Library/Containers/com.example.App/Data/c", mb: 4)
        let items = inspector().inspect().items
        let apple = try XCTUnwrap(items.first { $0.id == "small:appContainer.managedByMacOS" })
        XCTAssertEqual(Double(apple.bytes ?? 0), 5_000_000, accuracy: 300_000)
        XCTAssertFalse(SystemDataScreenBuilder.countedByAnotherCategory(apple), "Apple's containers are System Data")
        let thirdParty = try XCTUnwrap(items.first { $0.id == "small:appContainer" })
        XCTAssertEqual(Double(thirdParty.bytes ?? 0), 4_000_000, accuracy: 300_000)
        XCTAssertTrue(SystemDataScreenBuilder.countedByAnotherCategory(thirdParty), "third-party containers are Applications")
    }

    /// Folders another entry measures only in part are measured for the rest: apps' logs beside the crash reports, the Messages
    /// database beside its attachments (Settings' Messages category).
    func testFoldersMeasuredElsewhereOnlyInPartAreMeasuredForTheRest() throws {
        try file("home/Library/Logs/DiagnosticReports/a.ips", mb: 60)
        try file("home/Library/Logs/SomeApp/log.txt", mb: 70)
        try file("home/Library/Messages/Attachments/x.jpg", mb: 80)
        try file("home/Library/Messages/chat.db", mb: 55)
        let items = inspector().inspect().items
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "library:Logs" }).paths.map { ($0 as NSString).lastPathComponent }, ["SomeApp"])
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "library:Messages" }).paths.map { ($0 as NSString).lastPathComponent }, ["chat.db"])
    }

    /// Only a folder closed even to root ("operation not permitted", System Integrity Protection) is protected; one only root can
    /// open ("permission denied") is the helper's to measure.
    func testOnlyFoldersClosedEvenToRootAreProtected() throws {
        let caches = root.appendingPathComponent("home/Library/Caches")
        let rootOnly = caches.appendingPathComponent("rootonly")
        try fm.createDirectory(at: rootOnly, withIntermediateDirectories: true)
        try fm.createDirectory(at: caches.appendingPathComponent("open"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: rootOnly.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootOnly.path) }
        XCTAssertEqual(SystemDataInspector.protectedFolders(under: [(caches.path, 1)]), [])
        XCTAssertEqual(inspector(fullDiskAccess: false).inspect().protectedFolders, [], "without Full Disk Access a refusal proves nothing")
    }

    func testWhatSettingsListsElsewhereIsNotSystemData() throws {
        try file("home/Library/Application Support/Tool/data.db", mb: 70)
        try file("home/Library/Application Support/Tool/1.2/Tool.app/Contents/MacOS/Tool", mb: 60)
        try file("home/.toolcache/blob", mb: 80)
        let support = root.appendingPathComponent("home/Library/Application Support/Tool").path
        let items = inspector(apps: ["\(support)/1.2/Tool.app"]).inspect().items
        let tool = try XCTUnwrap(items.first { $0.id == "appsupport:Tool" })
        XCTAssertEqual(Double(tool.elsewhereBytes ?? 0), 60_000_000, accuracy: 2_000_000, "the app inside is Applications")
        let dotFolder = try XCTUnwrap(items.first { $0.id == "home:.toolcache" })
        XCTAssertEqual(dotFolder.elsewhereBytes, dotFolder.bytes, "the home folder outside ~/Library is Documents")
        XCTAssertNil(try XCTUnwrap(inspector().inspect().items.first { $0.id == "appsupport:Tool" }).elsewhereBytes)
        XCTAssertEqual(IndexedApps.outermost(["/a/X.app", "/a/X.app/Contents/Helpers/Y.app", "/System/Applications/Mail.app"]), ["/a/X.app"])
    }

    func testStagedUpdateDataOlderThanTheInstalledSystemIsALeftoverNotAWaitingUpdate() throws {
        try file("installdata/UpdateBundle/pkg", mb: 60)
        try file("system/SystemVersion.plist", mb: 0)
        func inspect(stagedModified: Date, systemModified: Date) throws -> SystemDataItem {
            try fm.setAttributes([.modificationDate: stagedModified], ofItemAtPath: root.appendingPathComponent("installdata").path)
            try fm.setAttributes([.modificationDate: systemModified], ofItemAtPath: root.appendingPathComponent("system/SystemVersion.plist").path)
            let locations = SystemDataLocations(home: root.appendingPathComponent("home"), userSystemDirectory: nil,
                                                systemPaths: ["installData": root.appendingPathComponent("installdata").path,
                                                              "systemVersion": root.appendingPathComponent("system/SystemVersion.plist").path])
            var inspector = SystemDataInspector(locations: locations, runningApps: { [] }, volumes: { [] }, claimedPlaces: { [] })
            inspector.hasFullDiskAccess = true
            return try XCTUnwrap(inspector.inspect().items.first { $0.id == "update:staged" })
        }
        let old = Date(timeIntervalSinceNow: -90 * 86_400), recent = Date(timeIntervalSinceNow: -5 * 86_400)
        let leftover = try inspect(stagedModified: old, systemModified: recent)
        XCTAssertEqual(leftover.title, "Leftover macOS update files")
        XCTAssertNil(leftover.guide, "there is no update to install")
        XCTAssertEqual(leftover.cleanup.kind, .managedByMacOS)
        let waiting = try inspect(stagedModified: recent, systemModified: old)
        XCTAssertEqual(waiting.title, "Staged macOS update")
        XCTAssertEqual(waiting.guide?.app, "macOS update")
    }

    func testUnreadableChildrenAreNamedIndividually() throws {
        for name in ["com.example.A", "com.example.B"] {
            let dir = root.appendingPathComponent("home/Library/Containers/\(name)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        }
        defer {
            for name in ["com.example.A", "com.example.B"] {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("home/Library/Containers/\(name)").path)
            }
        }
        let report = inspector().inspect()
        XCTAssertEqual(Set(report.unreadable), Set(["com.example.A", "com.example.B"].map { root.appendingPathComponent("home/Library/Containers/\($0)").path }), "the exact places are named")
    }

    func testFindsUnfinishedDownloadsRestoreImagesAndVirtualMachines() throws {
        // Observed on 26B5091g: Parallels downloading a restore image into Downloads/{GUID}/…ipsw.prlupd-part.
        try file("home/Downloads/{af79c1b5}/UniversalMac_27.0.1_26A434_Restore.ipsw.prlupd-part", mb: 120)
        try file("home/Downloads/UniversalMac_26.0_Restore.ipsw", mb: 600)
        try file("home/Parallels/macOS 27.pvm/harddisk.hdd", mb: 700)
        try file("home/Downloads/small.crdownload", mb: 1)
        let report = inspector().inspect()
        let kinds = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds["download:UniversalMac_27.0.1_26A434_Restore.ipsw.prlupd-part"], .partialDownload)
        XCTAssertEqual(kinds["ipsw:UniversalMac_26.0_Restore.ipsw"], .restoreImage)
        XCTAssertEqual(kinds["vm:macOS 27.pvm"], .virtualMachine)
        XCTAssertNil(kinds["download:small.crdownload"], "below the threshold")
        XCTAssertEqual(report.manualCleanup.first?.app, "Parallels Desktop", "the partial download and the VM share the Parallels guide")
        XCTAssertEqual(report.manualCleanup.first?.itemIDs.count, 2)
    }

    func testManualGuidesAggregatePerApp() throws {
        try file("home/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/media", mb: 150)
        try file("home/Library/Containers/net.whatsapp.WhatsApp/Data/cache", mb: 110)
        try file("home/Library/CloudStorage/OneDrive-Pessoal/big.pdf", mb: 120)
        try file("home/Library/Caches/com.anthropic.claudefordesktop.ShipIt/update.zip", mb: 90)
        let report = inspector().inspect()
        let apps = report.manualCleanup.map(\.app)
        XCTAssertEqual(apps.first, "WhatsApp", "largest first")
        XCTAssertEqual(report.manualCleanup.first?.itemIDs.count, 2, "both WhatsApp containers in one line")
        XCTAssertTrue(apps.contains("OneDrive"))
        XCTAssertFalse(apps.contains("Claude"), "an updater cache is an app cache, not a manual step")
        XCTAssertFalse(report.manualCleanup.first!.guide.steps.isEmpty)
    }

    func testCleanerRespectsRunningAppsAndAllowedRoots() throws {
        try file("folders/X/com.example.Big.code_sign_clone/Contents/MacOS/Big", mb: 60)
        try file("home/Library/Caches/com.example.Tool/blob", mb: 70)
        try file("home/Library/Application Support/BigApp/data", mb: 120)
        let report = inspector().inspect()
        let items = report.items.filter { ["clone:com.example.Big", "appcache:com.example.Tool", "appsupport:BigApp"].contains($0.id) }

        var free: UInt64 = 1_000
        let blocked = SystemDataCleaner(runningApps: { [RunningApp(bundleIdentifier: "com.example.Big", name: "Big")] }, processCheck: .none, freeSpace: { free })
            .clean(items, allowedRoots: SystemDataCleaner.allowedRoots(locations))
        XCTAssertEqual(blocked.results.first { $0.itemID == "clone:com.example.Big" }?.deleted, false, "a copy stays while its app runs")
        XCTAssertEqual(blocked.results.first { $0.itemID == "appsupport:BigApp" }?.deleted, false, "review items are never deleted")
        XCTAssertEqual(blocked.results.first { $0.itemID == "appcache:com.example.Tool" }?.deleted, false, "app caches are not cleaned by this module")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("folders/X/com.example.Big.code_sign_clone").path))

        try file("folders/C/clang/ModuleCache/a.pcm", mb: 60)
        let clang = try XCTUnwrap(inspector().inspect().items.first { $0.id == "usercache:clang" })
        let cleaner = SystemDataCleaner(runningApps: { [] }, processCheck: .none, freeSpace: { defer { free += 60_000_000 }; return free })
        let result = cleaner.clean([clang], allowedRoots: SystemDataCleaner.allowedRoots(locations))
        XCTAssertEqual(result.results.map(\.deleted), [true])
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("folders/C/clang").path))
        XCTAssertEqual(result.freeBytesAfter.map { $0 - result.freeBytesBefore! }, 60_000_000, "freed space is measured, not estimated")

        // A crafted item outside the allowed roots is refused even if it claims to be cleanable.
        let outside = SystemDataItem(id: "x", title: "x", kind: .appCache, paths: [root.appendingPathComponent("home/Library/Application Support/BigApp").path],
                                     bytes: 1, readable: true, owners: [], inUse: false,
                                     cleanup: SystemDataCleanup(kind: .deleteWhenNotRunning, description: "", command: nil), notes: [])
        XCTAssertEqual(cleaner.clean([outside], allowedRoots: SystemDataCleaner.allowedRoots(locations)).results.first?.deleted, false)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("home/Library/Application Support/BigApp").path))
    }

    /// The running apps miss what is not an app. A command-line tool with the owner's name, a helper running from inside the owner's
    /// app, or any process holding a file open in the item keeps it; so does a check that cannot be made.
    func testCleanerChecksProcessesAndOpenFilesBeforeEachItem() throws {
        try file("folders/C/clang/ModuleCache/a.pcm", mb: 60)
        try file("folders/C/com.example.chatty/blob", mb: 60)
        let items = inspector().inspect().items
        let clang = try XCTUnwrap(items.first { $0.id == "usercache:clang" })
        let chatty = try XCTUnwrap(items.first { $0.id == "usercache:com.example.chatty" })
        let roots = SystemDataCleaner.allowedRoots(locations)
        func clean(_ item: SystemDataItem, _ check: ProcessCheck) -> SystemDataCleanupResult {
            SystemDataCleaner(runningApps: { [] }, processCheck: check, freeSpace: { nil }).clean([item], allowedRoots: roots).results[0]
        }
        func check(_ processes: [RunningProcess]? = [], open: Bool? = false, app: String? = nil) -> ProcessCheck {
            ProcessCheck(processes: { processes }, holdsOpen: { _ in open }, appPath: { _ in app })
        }

        let compiler = RunningProcess(pid: 10, name: "clang", executablePath: "/usr/bin/clang")
        XCTAssertFalse(clean(clang, check([compiler])).deleted, "a compiler is not an app, but it is running")
        XCTAssertTrue(inspector(processes: check([compiler])).inspect().items.first { $0.id == "usercache:clang" }?.inUse == true,
                      "and the scan does not offer it either")

        let helper = RunningProcess(pid: 11, name: "Chatty Helper", executablePath: "/Applications/Chatty.app/Contents/Frameworks/Chatty Helper.app/Contents/MacOS/Chatty Helper")
        XCTAssertFalse(clean(chatty, check([helper], app: "/Applications/Chatty.app")).deleted, "a helper inside the app keeps its cache")
        let other = RunningProcess(pid: 12, name: "Chatty Helper", executablePath: "/Applications/Chatty Two.app/Contents/MacOS/Chatty Helper")
        XCTAssertFalse(clean(chatty, check([other], open: nil, app: "/Applications/Chatty.app")).deleted, "an open-file check that cannot be made keeps it")
        XCTAssertFalse(clean(chatty, check(open: true)).deleted, "a process holding a file open keeps it")
        XCTAssertFalse(clean(chatty, check(nil)).deleted, "processes that cannot be listed keep it")
        XCTAssertTrue(fm.fileExists(atPath: chatty.paths[0]))

        XCTAssertTrue(clean(chatty, check([other], app: "/Applications/Chatty.app")).deleted, "an app whose name only starts the same does not count")
        XCTAssertTrue(clean(clang, check([RunningProcess(pid: 13, name: "clangd-helper", executablePath: nil)])).deleted, "a name must match exactly")
        XCTAssertFalse(fm.fileExists(atPath: clang.paths[0]))
    }

    /// The live check, on this test process: it is one of the user's processes, and a file it holds open is seen until it is closed.
    func testLiveProcessCheckSeesThisProcessAndItsOpenFiles() throws {
        try file("folders/C/com.example.open/blob", mb: 1)
        let folder = root.appendingPathComponent("folders/C/com.example.open").path
        XCTAssertTrue(ProcessCheck.live.processes()?.contains { $0.pid == getpid() } == true)
        XCTAssertEqual(ProcessCheck.live.holdsOpen([folder]), false)
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent("folders/C/com.example.open/blob"))
        XCTAssertEqual(ProcessCheck.live.holdsOpen([folder]), true, "found under /private/var, although the path says /var")
        try handle.close()
        XCTAssertEqual(ProcessCheck.live.holdsOpen([folder]), false)
        XCTAssertEqual(ProcessCheck.live.holdsOpen([root.appendingPathComponent("missing").path]), false, "nothing open in what does not exist")
    }

    /// The per-user folders of the other accounts (root, macOS's services, deleted accounts) are one item, without the user's own,
    /// which other items measure; the folder idleassetsd downloads into is named in advance for the helper.
    func testOtherAccountsFoldersAreMeasuredAndWallpaperDownloadsNamed() throws {
        try file("varfolders/58/mine/T/own", mb: 60)
        try file("varfolders/zz/rootdir/C/cache", mb: 40)
        try file("varfolders/zz/rootdir/T/com.apple.idleassetsd/CFNetworkDownload_a.tmp", mb: 30)
        try file("varfolders/zz/spotlightdir/T/x", mb: 1)
        let locations = SystemDataLocations(home: root.appendingPathComponent("home"), userSystemDirectory: root.appendingPathComponent("varfolders/58/mine"),
                                            systemPaths: ["varFolders": root.appendingPathComponent("varfolders").path])
        var inspector = SystemDataInspector(locations: locations, runningApps: { [] }, volumes: { [] }, claimedPlaces: { [] })
        inspector.processCheck = .none
        let report = inspector.inspect()
        let other = try XCTUnwrap(report.items.first { $0.id == "folders:other" })
        XCTAssertEqual(Double(other.bytes ?? 0), 71_000_000, accuracy: 2_000_000, "root's and the services' folders, not the user's own")
        XCTAssertFalse(other.paths.contains { $0.contains("/mine") })
        XCTAssertEqual(Set(report.rootOnly.map(\.path)), [root.appendingPathComponent("varfolders/zz/rootdir/T/com.apple.idleassetsd").path,
                                                          root.appendingPathComponent("varfolders/zz/spotlightdir/T/com.apple.idleassetsd").path])
        XCTAssertTrue(report.rootOnly.allSatisfy { $0.within == "folders:other" })
    }

    /// An item too small to list from what this process can read stays when part of it waits for the helper, so the helper's sizes
    /// have an item to go to; before, the item was dropped and root's caches and temporary files went unmeasured.
    func testAnItemPartlyClosedToThisProcessWaitsForTheHelper() throws {
        // The kernel's path (/private/var/…), which the helper may measure; the temporary folder's own path says /var.
        let real = try XCTUnwrap(realpath(root.path, nil).map { defer { free($0) }; return String(cString: $0) })
        try file("varfolders/zz/rootdir/X/small", mb: 1)
        try file("varfolders/zz/rootdir/T/secret", mb: 1)
        let closed = real + "/varfolders/zz/rootdir/T"
        XCTAssertEqual(chmod(closed, 0), 0)
        defer { chmod(closed, 0o755) }
        let locations = SystemDataLocations(home: root.appendingPathComponent("home"), userSystemDirectory: nil, systemPaths: ["varFolders": real + "/varfolders"])
        var inspector = SystemDataInspector(locations: locations, runningApps: { [] }, volumes: { [] }, claimedPlaces: { [] })
        inspector.processCheck = .none
        let report = inspector.inspect()
        XCTAssertTrue(report.unreadable.contains(closed))
        let other = try XCTUnwrap(report.items.first { $0.id == "folders:other" }, "kept, though its readable part is under the minimum")
        let merged = RootMeasurements.merge([closed: 900_000_000], into: SystemDataSnapshot(report: report, purgeableAssetsBytes: nil,
            reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date()))
        XCTAssertEqual(Double(merged.report.items.first { $0.id == other.id }?.bytes ?? 0), 901_000_000, accuracy: 2_000_000)
    }

    func testHomeFoldersOfDeletedAccountsAreListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-users-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tester = root.appendingPathComponent("tester")
        try FileManager.default.createDirectory(at: tester.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try Data(count: 60_000).write(to: tester.appendingPathComponent("Library/file"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Deleted Users/old.dmg"), withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        func inspect(root canRead: Bool) -> SystemDataReport {
            var inspector = SystemDataInspector(locations: SystemDataLocations(home: home, userSystemDirectory: nil, systemPaths: ["users": root.path]),
                                                runningApps: { [] }, volumes: { [] }, accountExists: { _ in false }, claimedPlaces: { [] })
            inspector.canReadOtherHomes = canRead
            return inspector.inspect()
        }
        let asUser = inspect(root: false)
        let item = try XCTUnwrap(asUser.items.first { $0.id == "orphanhome:tester" })
        XCTAssertEqual(item.kind, .orphanedHome)
        XCTAssertNil(item.bytes, "another account's folder cannot be measured without root")
        XCTAssertTrue(asUser.unreadable.contains(tester.path))
        XCTAssertEqual(item.guide?.app, "Deleted accounts' home folders")
        XCTAssertNotNil(asUser.items.first { $0.id == "orphanhome:deleted:old.dmg" })
        XCTAssertNil(asUser.items.first { $0.id == "orphanhome:Shared" })
        XCTAssertGreaterThan(try XCTUnwrap(inspect(root: true).items.first { $0.id == "orphanhome:tester" }?.bytes), 50_000)
    }
}
