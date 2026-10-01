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

    private func inspector(running: [RunningApp] = [], fullDiskAccess: Bool = true) -> SystemDataInspector {
        var inspector = SystemDataInspector(locations: locations, runningApps: { running }, volumes: { [VolumeUsage(name: "Data", roles: ["Data"], usedBytes: 1)] })
        inspector.hasFullDiskAccess = fullDiskAccess
        return inspector
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

    func testClassifiesClonesCachesAndAppleCaches() throws {
        try file("folders/X/com.example.Big.code_sign_clone/Contents/MacOS/Big", mb: 60)
        try file("folders/C/clang/ModuleCache/a.pcm", mb: 55)
        try file("home/Library/Caches/com.example.Tool/blob", mb: 70)
        try file("home/Library/Caches/com.apple.Safari/blob", mb: 80)
        try file("home/Library/Caches/tiny/blob", mb: 1)
        try file("home/Library/Caches/.DS_Store", mb: 0)
        try file("home/Library/Application Support/BigApp/data", mb: 120)
        try file("clt/usr/bin/clang", mb: 2)

        let report = inspector(running: [RunningApp(bundleIdentifier: "com.example.Big", name: "Big")]).inspect()
        let byID = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
        XCTAssertEqual(byID["clone:com.example.Big"]?.cleanup.kind, .managedByMacOS, "clones free ~nothing (measured)")
        XCTAssertEqual(byID["clone:com.example.Big"]?.expectedReclaimBytes, 0)
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
        XCTAssertGreaterThanOrEqual(report.cleanableBytes, 55_000_000, "only the system cache, not the clone or app caches")
        XCTAssertLessThan(report.cleanableBytes, 100_000_000)
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
        let blocked = SystemDataCleaner(runningApps: { [RunningApp(bundleIdentifier: "com.example.Big", name: "Big")] }, freeSpace: { free })
            .clean(items, allowedRoots: SystemDataCleaner.allowedRoots(locations))
        XCTAssertEqual(blocked.results.first { $0.itemID == "clone:com.example.Big" }?.deleted, false, "clones are not cleanable")
        XCTAssertEqual(blocked.results.first { $0.itemID == "appsupport:BigApp" }?.deleted, false, "review items are never deleted")
        XCTAssertEqual(blocked.results.first { $0.itemID == "appcache:com.example.Tool" }?.deleted, false, "app caches are not cleaned by this module")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("folders/X/com.example.Big.code_sign_clone").path))

        try file("folders/C/clang/ModuleCache/a.pcm", mb: 60)
        let clang = try XCTUnwrap(inspector().inspect().items.first { $0.id == "usercache:clang" })
        let cleaner = SystemDataCleaner(runningApps: { [] }, freeSpace: { defer { free += 60_000_000 }; return free })
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
                                                runningApps: { [] }, volumes: { [] }, accountExists: { _ in false })
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
