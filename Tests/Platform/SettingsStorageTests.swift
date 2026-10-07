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
