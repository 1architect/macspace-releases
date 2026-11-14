import Foundation
import XCTest
@testable import MacSpaceDiskMapPrivileged

final class AppCatalogLoadingTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maximum = 0
        private var visited: [String] = []
        var peak: Int { lock.withLock { maximum } }
        var paths: [String] { lock.withLock { visited } }
        func begin(_ path: String) { lock.withLock { active += 1; maximum = max(maximum, active); visited.append(path) } }
        func end() { lock.withLock { active -= 1 } }
    }
    private func owner(_ path: String) throws -> AppOwner {
        let data = try JSONSerialization.data(withJSONObject: [
            "path": path, "identifier": "org.fixture.app", "name": path, "groups": [], "helpers": [:],
            "identifiers": ["org.fixture.app"], "isBackground": false, "signatureValid": false, "metadataDigest": "fixture"
        ] as [String: Any])
        return try JSONDecoder().decode(AppOwner.self, from: data)
    }

    func testBoundedMetadataReadsPreserveOrderMissingEntriesAndKnownOwners() throws {
        let paths = (0..<25).map { "/fixture/\($0).app" }
        let owners = try Dictionary(uniqueKeysWithValues: paths.map { ($0, try owner($0)) })
        let reads = Reads(), known = [paths[0]: try XCTUnwrap(owners[paths[0]])]
        var progress: [Double] = []
        let reports = Progress()
        let actual = AppOwnership.readOwners(paths, known: known, read: { path in
            reads.begin(path); defer { reads.end() }
            Thread.sleep(forTimeInterval: 0.002)
            return path == paths[3] ? nil : owners[path]
        }, progress: reports.record)
        progress = reports.values
        XCTAssertEqual(actual.map(\.path), paths.filter { $0 != paths[3] })
        XCTAssertEqual(actual.first, known[paths[0]])
        XCTAssertFalse(reads.paths.contains(paths[0]))
        XCTAssertEqual(reads.paths.count, paths.count - known.count)
        XCTAssertGreaterThan(reads.peak, 1)
        XCTAssertLessThanOrEqual(reads.peak, 4)
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(progress.last, 1)
    }

    func testCancellationStopsBeforeTheNextMetadataBatch() async throws {
        let paths = (0..<20).map { "/fixture/\($0).app" }
        let value = try owner(paths[0]), reads = Reads(), gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "First bounded batch")
        started.expectedFulfillmentCount = 4
        let task = Task.detached {
            AppOwnership.readOwners(paths, read: { path in
                reads.begin(path); defer { reads.end() }
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                return value
            })
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        for _ in 0..<4 { gate.signal() }
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(reads.paths.count, 4)
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var heard: [Double] = []
        var values: [Double] { lock.withLock { heard } }
        func record(_ value: Double) { lock.withLock { heard.append(value) } }
    }
}
