import XCTest
@testable import MacSpacePlatform

final class SettingsStorageTests: XCTestCase {
    /// Settings' macOS is the startup container without its Data volume, plus the Recovery container on the same disk; not the ISC
    /// container, and not another disk's. Volumes of the Apple silicon Mac it was measured on (47.4458 GB; Settings showed 47.45 GB).
    func testMacOSIsTheStartupContainerAndTheRecoveryContainer() {
        let volumes = [
            APFSVolumeUsage(device: "disk1s1", container: "disk1", roles: ["Preboot"], bytesInUse: 6_283_264, store: "disk0s1", storeType: "Apple_APFS_ISC"),
            APFSVolumeUsage(device: "disk1s2", container: "disk1", roles: ["xART"], bytesInUse: 6_311_936, store: "disk0s1", storeType: "Apple_APFS_ISC"),
            APFSVolumeUsage(device: "disk2s1", container: "disk2", roles: ["System"], bytesInUse: 18_579_587_072, store: "disk0s2", storeType: "Apple_APFS"),
            APFSVolumeUsage(device: "disk2s2", container: "disk2", roles: ["Preboot"], bytesInUse: 21_943_734_272, store: "disk0s2", storeType: "Apple_APFS"),
            APFSVolumeUsage(device: "disk2s3", container: "disk2", roles: ["Recovery"], bytesInUse: 3_040_796_672, store: "disk0s2", storeType: "Apple_APFS"),
            APFSVolumeUsage(device: "disk2s4", container: "disk2", roles: ["Update"], bytesInUse: 1_262_465_024, store: "disk0s2", storeType: "Apple_APFS"),
            APFSVolumeUsage(device: "disk2s5", container: "disk2", roles: ["Data"], bytesInUse: 148_991_549_440, store: "disk0s2", storeType: "Apple_APFS"),
            APFSVolumeUsage(device: "disk2s6", container: "disk2", roles: ["VM"], bytesInUse: 24_576, store: "disk0s2", storeType: "Apple_APFS"),
            APFSVolumeUsage(device: "disk3s1", container: "disk3", roles: ["Recovery"], bytesInUse: 2_617_929_728, store: "disk0s3", storeType: "Apple_APFS_Recovery"),
            APFSVolumeUsage(device: "disk3s2", container: "disk3", roles: ["Update"], bytesInUse: 1_232_896, store: "disk0s3", storeType: "Apple_APFS_Recovery"),
            APFSVolumeUsage(device: "disk5s1", container: "disk5", roles: ["Recovery"], bytesInUse: 9_000_000_000, store: "disk4s3", storeType: "Apple_APFS_Recovery"),
        ]
        XCTAssertEqual(APFSVolumeUsage.systemVolumes(volumes, dataDevice: "disk2s5"), 47_445_770_240)
        XCTAssertEqual(APFSVolumeUsage.systemVolumes(volumes, dataDevice: "disk9s9"), 0, "an unknown Data volume")
        XCTAssertEqual(APFSVolumeUsage.wholeDisk("disk0s3"), "disk0")
    }

    /// System Data is what is left of used once macOS and every category are taken off, never below zero.
    func testSystemDataIsTheRemainder() {
        let reading = SettingsStorage(capacity: 245_000_000_000, used: 191_000_000_000, macOS: 47_000_000_000,
                                      categories: [.init(id: "applications", bytes: 98_000_000_000), .init(id: "documents", bytes: 10_000_000_000)])
        XCTAssertEqual(reading.systemData, 36_000_000_000)
        XCTAssertEqual(SettingsStorage(capacity: 1, used: 1, macOS: 5, categories: []).systemData, 0)
    }

    /// Documents is the home folder outside ~/Library.
    func testDocumentsIsTheHomeFolderOutsideLibrary() {
        XCTAssertTrue(SettingsStorageMeter.isDocuments("/Users/me/.config", home: "/Users/me"))
        XCTAssertFalse(SettingsStorageMeter.isDocuments("/Users/me/Library/CloudStorage/OneDrive", home: "/Users/me"))
        XCTAssertFalse(SettingsStorageMeter.isDocuments("/Users/me/Library", home: "/Users/me"))
        XCTAssertFalse(SettingsStorageMeter.isDocuments("/opt/homebrew", home: "/Users/me"))
    }

    func testDocumentsExcludesUnindexedAppsButKeepsOrdinaryFilesAndOtherCategorySizing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root.appendingPathComponent(".cache/Unindexed.app"))
        let document = root.appendingPathComponent("document.bin")
        let namedLikeApp = root.appendingPathComponent("notes.txt")
        let applicationFile = root.appendingPathComponent("file.app")
        try Data(repeating: 1, count: 4_000_000).write(to: document)
        try Data(repeating: 2, count: 1_000_000).write(to: namedLikeApp)
        try Data(repeating: 3, count: 1_000_000).write(to: applicationFile)
        XCTAssertEqual(try app.resourceValues(forKeys: [.isApplicationKey]).isApplication, true)
        XCTAssertNotEqual(try namedLikeApp.resourceValues(forKeys: [.isApplicationKey]).isApplication, true)
        let documents = AllocatedSize.allocatedBytes(document.path, excluding: []) + AllocatedSize.allocatedBytes(namedLikeApp.path, excluding: [])
        let appBytes = AllocatedSize.allocatedBytes(app.path, excluding: []) + AllocatedSize.allocatedBytes(applicationFile.path, excluding: [])
        XCTAssertGreaterThan(appBytes, 0)
        XCTAssertEqual(AllocatedSize.allocatedBytes(root.path, excluding: [], excludingApplications: true), documents)
        XCTAssertEqual(AllocatedSize.allocatedBytes(root.path, excluding: []), documents + appBytes,
                       "Other categories must retain their existing bundle sizing")
        XCTAssertEqual(AllocatedSize.allocatedBytes([
            AllocatedSize.Job(path: root.path), AllocatedSize.Job(path: root.path, excludingApplications: true)
        ], workers: 2), [documents + appBytes, documents])
    }

    func testApplicationsUsesAppleScopesAndRejectsNestedAppsWithUnindexedParents() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Users/me")
        var meter = SettingsStorageMeter(home: home)
        meter.root = root.path
        let installed = try makeApp(root.appendingPathComponent("Applications/Installed.app"))
        let personal = try makeApp(home.appendingPathComponent("Developer/Personal.app"))
        let outside = try makeApp(root.appendingPathComponent("usr/local/share/dotnet/Helper.app"))
        let shared = try makeApp(root.appendingPathComponent("Library/Support/Helper.app"))
        let library = try makeApp(home.appendingPathComponent("Library/Support/Helper.app"))
        let trash = try makeApp(home.appendingPathComponent(".Trash/Deleted.app"))
        let parent = try makeApp(home.appendingPathComponent("Developer/Unindexed.app"))
        let nested = try makeApp(parent.appendingPathComponent("Contents/Helpers/Nested.app"))
        let inputs = [installed, personal, outside, shared, library, trash, nested].map(\.path)
        XCTAssertEqual(Set(meter.applicationPaths(inputs)), Set([installed.path, personal.path]))
        let claims = meter.claimedPlaces(apps: inputs)
        XCTAssertTrue(claims.contains(personal.path))
        XCTAssertFalse(claims.contains(outside.path))
        XCTAssertFalse(claims.contains(shared.path))
        XCTAssertFalse(claims.contains(library.path))
    }

    /// Fixed used space makes the direction observable: bytes misclassified into Apps/Documents lower the System Data remainder.
    func testCategoryCorrectionsRestoreSystemDataWithoutChangingUsedSpace() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Users/me")
        let installed = try makeApp(root.appendingPathComponent("Applications/Installed.app"))
        let personal = try makeApp(home.appendingPathComponent("Developer/Indexed.app"))
        let unindexed = try makeApp(home.appendingPathComponent(".cache/Unindexed.app"))
        let outside = try makeApp(root.appendingPathComponent("usr/local/share/dotnet/Helper.app"))
        let document = home.appendingPathComponent("document.bin")
        try Data(repeating: 3, count: 4_000_000).write(to: document)
        var meter = SettingsStorageMeter(home: home)
        meter.root = root.path
        meter.apps = { [installed.path, personal.path, outside.path] }
        meter.space = { (100_000_000, 10_000_000) }
        meter.dataDevice = { nil }
        meter.desktopAndDocumentsInICloud = { false }
        let reading = try XCTUnwrap(meter.measure())
        let appBytes = [installed, personal].map { AllocatedSize.allocatedBytes($0.path, excluding: []) }.reduce(0, +)
        let documentBytes = AllocatedSize.allocatedBytes(document.path, excluding: [])
        XCTAssertEqual(reading.bytes("applications"), appBytes)
        XCTAssertEqual(reading.bytes("documents"), documentBytes)
        XCTAssertEqual(reading.used, 90_000_000)
        XCTAssertEqual(reading.systemData, reading.used - appBytes - documentBytes)
        let previous = SettingsStorage(capacity: reading.capacity, used: reading.used, macOS: reading.macOS, categories: [
            .init(id: "applications", bytes: appBytes + AllocatedSize.allocatedBytes(outside.path, excluding: [])),
            .init(id: "documents", bytes: documentBytes + AllocatedSize.allocatedBytes(unindexed.path, excluding: []))
        ])
        XCTAssertEqual(reading.systemData - previous.systemData,
                       AllocatedSize.allocatedBytes(outside.path, excluding: []) + AllocatedSize.allocatedBytes(unindexed.path, excluding: []))
    }

    /// Settings counts the whole ~/Library/Application Support in Applications, a folder no app owns too (#35); Steam's folder inside
    /// it is counted once.
    func testApplicationsCountsAllOfApplicationSupportOnce() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Users/me")
        let support = home.appendingPathComponent("Library/Application Support")
        for folder in ["Unowned", "Steam"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data(repeating: 5, count: 4_000_000).write(to: support.appendingPathComponent("\(folder)/data.bin"))
        }
        var meter = SettingsStorageMeter(home: home)
        meter.root = root.path
        meter.apps = { [] }
        meter.space = { (100_000_000, 10_000_000) }
        meter.dataDevice = { nil }
        meter.desktopAndDocumentsInICloud = { false }
        XCTAssertTrue(meter.claimedPlaces(apps: []).contains(support.path))
        let reading = try XCTUnwrap(meter.measure())
        XCTAssertEqual(reading.bytes("applications"), AllocatedSize.allocatedBytes(support.path, excluding: []))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeApp(_ url: URL) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "local.macspace.sizing-test", "CFBundlePackageType": "APPL",
                                    "CFBundleName": "SizingTest", "CFBundleExecutable": "Control"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 7, count: 8_000_000).write(to: contents.appendingPathComponent("payload.bin"))
        return url
    }
}

final class CloneLedgerTests: XCTestCase {
    /// A file cloned into another folder takes its blocks once on disk: sized with one ledger, the second folder adds only what the
    /// clone does not share; without a ledger each folder counts it in full.
    func testAClonedFileIsCountedOnceAcrossFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clones-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 20_000_000).write(to: a.appendingPathComponent("big"))
        guard clonefile(a.appendingPathComponent("big").path, b.appendingPathComponent("big").path, 0) == 0 else {
            throw XCTSkip("the temporary folder is not on APFS")
        }
        let ledger = CloneLedger()
        let first = try XCTUnwrap(FileTreeSizer(clones: ledger).size(at: a)?.bytes)
        let second = try XCTUnwrap(FileTreeSizer(clones: ledger).size(at: b)?.bytes)
        XCTAssertGreaterThanOrEqual(first, 20_000_000)
        XCTAssertLessThan(second, 1_000_000, "the clone shares every block")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(FileTreeSizer().size(at: b)?.bytes), 20_000_000, "without a ledger, counted in full")
    }
}
