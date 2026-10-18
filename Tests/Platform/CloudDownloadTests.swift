import Darwin
import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpacePlatform

final class CloudDownloadTests: XCTestCase {
    func testParallelMetadataScanPreservesTotalsAndInheritedPinsAndReportsProgress() throws {
        final class Reads: @unchecked Sendable {
            let lock = NSLock()
            var active = 0, peak = 0
            func inspect() -> PurgeableDocuments.CloudState {
                lock.withLock { active += 1; peak = max(peak, active) }
                Thread.sleep(forTimeInterval: 0.002)
                lock.withLock { active -= 1 }
                return .init(ubiquitous: true, uploaded: true, uploading: false, conflicted: false)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Pinned", "A", "B"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<40 { try Data(repeating: 1, count: 8192).write(to: directory.appendingPathComponent("file\(index)")) }
        }
        var marker: UInt8 = 49
        XCTAssertEqual(setxattr(root.appendingPathComponent("Pinned").path, "com.apple.fileprovider.pinned#PX", &marker, 1, 0, 0), 0)
        let reads = Reads(), progress = LoadProgressRelay()
        let source = try XCTUnwrap(PurgeableDocuments.scan(root, name: "Test", progress: progress.report, state: { _ in reads.inspect() }))
        XCTAssertEqual(source.files, 80)
        XCTAssertEqual(Set(source.folders.map(\.name)), ["A", "B"])
        XCTAssertTrue(source.folders.allSatisfy { $0.files == 40 })
        XCTAssertEqual(source.bytes, AllocatedSize.allocatedBytes(root.appendingPathComponent("A").path, excluding: [])
                       + AllocatedSize.allocatedBytes(root.appendingPathComponent("B").path, excluding: []))
        XCTAssertGreaterThan(reads.peak, 1, "metadata waits overlap")
        XCTAssertLessThanOrEqual(reads.peak, 4, "the provider is never flooded with unbounded work")
        XCTAssertEqual(progress.fraction, 1)
    }

    func testUploadedCopiesDoNotNeedAPFSPurgeableFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["uploaded", "uploading", "conflicted", "unknown", "localOnly"] {
            try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent(name))
        }
        let source = try XCTUnwrap(PurgeableDocuments.scan(root, name: "Test", state: { url in
            switch url.lastPathComponent {
            case "uploaded": return .init(ubiquitous: true, uploaded: true, uploading: false, conflicted: false)
            case "uploading": return .init(ubiquitous: true, uploaded: true, uploading: true, conflicted: false)
            case "conflicted": return .init(ubiquitous: true, uploaded: true, uploading: false, conflicted: true)
            case "unknown": return .init(ubiquitous: true, uploaded: true, uploading: nil, conflicted: nil)
            default: return .init(ubiquitous: false, uploaded: false, uploading: false, conflicted: false)
            }
        }))
        XCTAssertEqual(source.files, 1)
        XCTAssertGreaterThan(source.bytes, 0)
    }

    func testKeepDownloadedOnAParentPreventsOfferingItsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("Pinned/child")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: child)
        var marker: UInt8 = 49
        XCTAssertEqual(setxattr(child.deletingLastPathComponent().path, "com.apple.fileprovider.pinned#PX", &marker, 1, 0, 0), 0)
        let source = try XCTUnwrap(PurgeableDocuments.scan(root, name: "Test", state: { _ in
            .init(ubiquitous: true, uploaded: true, uploading: false, conflicted: false)
        }))
        XCTAssertEqual(source.files, 0)
    }
}
