import XCTest
@testable import MacSpacePlatform

private final class SessionProbe: @unchecked Sendable {
    var time: UInt64 = 0
    var allowed = true
    var calls = 0
    func read() -> Bool { calls += 1; return allowed }
}
final class MetadataSessionGateTests: XCTestCase {
    func testBulkQueriesDoNotIssueOneSessionProbePerStatement() {
        let probe = SessionProbe(), gate = MetadataSessionGate(clock: { probe.time }, probe: { probe.read() })
        for _ in 0..<100_000 { XCTAssertTrue(gate.available()) }
        XCTAssertEqual(probe.calls, 1)
        probe.time = 100_000_000
        XCTAssertTrue(gate.available()); XCTAssertEqual(probe.calls, 2)
    }
    func testLockRefusesImmediatelyEvenInsideCachedInterval() {
        let probe = SessionProbe(), gate = MetadataSessionGate(clock: { probe.time }, probe: { probe.read() })
        XCTAssertTrue(gate.available())
        gate.setLocked(true)
        for _ in 0..<100 { XCTAssertFalse(gate.available()); XCTAssertFalse(gate.available(fresh: true)) }
        XCTAssertEqual(probe.calls, 1)
        probe.allowed = false; gate.setLocked(false)
        XCTAssertFalse(gate.available()); XCTAssertEqual(probe.calls, 2)
    }
    func testKeychainChecksBypassCacheAndFallbackDetectsMissedNotification() {
        let probe = SessionProbe(), gate = MetadataSessionGate(clock: { probe.time }, probe: { probe.read() })
        XCTAssertTrue(gate.available())
        probe.allowed = false
        XCTAssertFalse(gate.available(fresh: true)); XCTAssertEqual(probe.calls, 2)
        probe.allowed = true; probe.time = 100_000_000
        XCTAssertTrue(gate.available())
        probe.allowed = false; probe.time = 200_000_000
        XCTAssertFalse(gate.available())
    }
}
