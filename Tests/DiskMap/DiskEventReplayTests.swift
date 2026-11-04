import CoreServices
import Foundation
import XCTest
@testable import MacSpaceDiskMap

final class DiskEventReplayTests: XCTestCase {
    private let root = "/fixture"
    private var file: FSEventStreamEventFlags { FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) }
    private var recursive: FSEventStreamEventFlags { FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) }
    func testRootRescanAbsorbsHistoricalDetailsAndDrainRestoresPreciseTracking() {
        let events = DiskEvents(root: root, since: 0, excluded: [], startStream: false)
        events.note(root, flags: recursive)
        let started = Date()
        for n in 0..<100_000 { events.note(root + "/history-\(n)/file", flags: file) }
        let pending = events.drain()
        XCTAssertEqual(pending.recursive, [root]); XCTAssertTrue(pending.shallow.isEmpty)
        events.note(root + "/new/file", flags: file)
        XCTAssertEqual(events.drain().shallow, [root + "/new"])
        print("DISK_EVENT_REPLAY coveredEvents=100000 seconds=\(Date().timeIntervalSince(started))")
    }
    func testLargeHistoryQueueFallsBackToOneRootScanWithoutLosingCoverage() {
        let events = DiskEvents(root: root, since: 0, excluded: [], startStream: false)
        for n in 0..<(DiskEvents.maximumPendingScopes * 2) { events.note(root + "/directory-\(n)/file", flags: file) }
        let pending = events.drain()
        XCTAssertEqual(pending.recursive, [root]); XCTAssertTrue(pending.shallow.isEmpty)
    }
    func testHistoryCompletionStillSignalsAfterRootCoalescing() {
        let events = DiskEvents(root: root, since: 123, excluded: [], startStream: false)
        events.note(root, flags: recursive)
        XCTAssertTrue(events.isReplayingHistory)
        events.note("", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone))
        XCTAssertFalse(events.isReplayingHistory)
        XCTAssertEqual(events.drain().recursive, [root])
    }
    func testExcludedAndInvalidPathsCannotGrowTheQueue() {
        let events = DiskEvents(root: root, since: 0, excluded: [root + "/cache"], startStream: false)
        for n in 0..<(DiskEvents.maximumPendingScopes * 2) { events.note(root + "/cache/\(n)/file", flags: file) }
        events.note(root + "/../outside/file", flags: file)
        events.note("/elsewhere/file", flags: file)
        XCTAssertFalse(events.hasChanges)
    }
}

extension DiskEventReplayTests {
    func testRootReadWatermarkSkipsCoveredHistoryButRetainsFutureEvents() {
        let events = DiskEvents(root: root, since: 123, excluded: [], startStream: false)
        events.note(root, flags: recursive)
        events.flush()
        let boundary = events.coveredEventID
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertEqual(events.drain().recursive, [root])
        events.note(root + "/old/file", flags: file, eventID: boundary)
        XCTAssertFalse(events.hasChanges)
        events.note(root + "/future/file", flags: file, eventID: boundary + 1)
        XCTAssertEqual(events.drain().shallow, [root + "/future"])
        events.note("", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), eventID: 0)
        XCTAssertFalse(events.isReplayingHistory)
    }
    func testWrappedEventIDsResetCoverageSoNewLowIDsAreNotDiscarded() {
        let events = DiskEvents(root: root, since: 123, excluded: [], startStream: false)
        events.note(root, flags: recursive); events.flush(); _ = events.drain()
        XCTAssertGreaterThan(events.coveredEventID, 0)
        events.note("", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped), eventID: 1)
        XCTAssertEqual(events.coveredEventID, 0)
        XCTAssertEqual(events.drain().recursive, [root])
        events.note(root + "/new/file", flags: file, eventID: 2)
        XCTAssertEqual(events.drain().shallow, [root + "/new"])
    }
}

extension DiskEventReplayTests {
    func testCombinedHistoryCompletionAndWrapCannotLeaveAnOldCoverageBoundary() {
        let events = DiskEvents(root: root, since: 123, excluded: [], startStream: false)
        events.note(root, flags: recursive); events.flush(); _ = events.drain()
        events.note("", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped), eventID: 1)
        XCTAssertFalse(events.isReplayingHistory)
        XCTAssertEqual(events.coveredEventID, 0)
        XCTAssertEqual(events.drain().recursive, [root])
        events.note(root + "/new/file", flags: file, eventID: 2)
        XCTAssertEqual(events.drain().shallow, [root + "/new"])
    }
}

extension DiskEventReplayTests {
    func testMissingHistoryCompletionFallsBackWithinGraceAndRetainsFutureEvents() {
        let events = DiskEvents(root: root, since: 123, excluded: [], startStream: false)
        let started = Date(), boundary = events.flush()
        XCTAssertLessThan(Date().timeIntervalSince(started), DiskEvents.historyGrace + 1)
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertEqual(events.drain().recursive, [root])
        events.note(root + "/changed/file", flags: file, eventID: boundary + 1)
        XCTAssertEqual(events.drain().shallow, [root + "/changed"])
    }
}

extension DiskEventReplayTests {
    func testRestartedNativeStreamRetainsChangesAfterItsFullScanBoundary() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/restarted-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = DiskEvents(root: directory.path, since: FSEventsGetCurrentEventId(), excluded: [])
        events.mark([directory.path], recursive: true)
        let boundary = events.flush()
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertEqual(events.drain().recursive, [directory.path])
        let nested = directory.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data([1]).write(to: nested.appendingPathComponent("file"))
        // The kernel-to-fseventsd handoff is asynchronous too: FlushSync flushes the daemon's
        // existing buffer, so a call immediately after close() can precede that handoff.
        // Verify eventual coverage rather than treating the first empty daemon buffer as lost data.
        var covered = false
        for _ in 0..<30 {
            _ = events.flush()
            let pending = events.drain()
            covered = pending.recursive.contains(directory.path) || pending.recursive.contains(nested.path)
                || pending.shallow.contains(directory.path) || pending.shallow.contains(nested.path)
            if covered { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(covered, "A stream replacement must not lose later changes")
    }
}
