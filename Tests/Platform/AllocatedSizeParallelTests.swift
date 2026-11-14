import Darwin
import Foundation
import XCTest
@testable import MacSpacePlatform

final class AllocatedSizeParallelTests: XCTestCase {
    func testIdleWorkersHelpOneLargeTreeWithoutChangingExclusionsHardLinksOrApplicationBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["empty-a", "empty-b", "large/excluded", "large/Example.app/Contents"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for directory in 0..<48 {
            let path = root.appendingPathComponent("large/tree-\(directory)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            for file in 0..<8 { try Data(repeating: UInt8(file), count: 8192).write(to: path.appendingPathComponent("\(file).txt")) }
        }
        let original = root.appendingPathComponent("large/tree-0/0.txt")
        XCTAssertEqual(link(original.path, root.appendingPathComponent("large/tree-47/linked.txt").path), 0)
        try Data(repeating: 7, count: 16384).write(to: root.appendingPathComponent("large/excluded/data"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.fixture.app"], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("large/Example.app/Contents/Info.plist"))
        let excluded: Set<String> = [root.appendingPathComponent("large/excluded").path]
        for skipsApps in [false, true] {
            let jobs = [AllocatedSize.Job(path: root.appendingPathComponent("empty-a").path),
                        AllocatedSize.Job(path: root.appendingPathComponent("empty-b").path),
                        AllocatedSize.Job(path: root.appendingPathComponent("large").path, excluding: excluded, excludingApplications: skipsApps)]
            let serial = AllocatedSize.allocatedBytes(jobs, workers: 1, clones: CloneLedger())
            let parallel = AllocatedSize.allocatedBytes(jobs, workers: 3, clones: CloneLedger())
            let borrowed = AllocatedSize.allocatedBytes(jobs, workers: 3, clones: CloneLedger(), pool: ScanPool(free: 2))
            XCTAssertEqual(serial, parallel)
            XCTAssertEqual(serial, borrowed)
            XCTAssertEqual(serial.prefix(2), [0, 0])
            XCTAssertGreaterThan(serial[2], 0)
        }
    }
}
