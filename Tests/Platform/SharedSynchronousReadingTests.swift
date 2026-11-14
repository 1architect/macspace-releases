import XCTest
import MacSpaceSdk
@testable import MacSpacePlatform

private final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let gate = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { reads } }
    func next() -> Int { lock.withLock { reads += 1; return reads } }
}

final class SharedSynchronousReadingTests: XCTestCase {
    func testConcurrentScansShareWorkAndProgressAndKeepCacheExpiry() {
        let control = ScanControl(), joined = DispatchSemaphore(value: 0), done = DispatchGroup()
        let epoch = Date(timeIntervalSince1970: 100)
        let reading = SharedSynchronousReading<Int> { progress in
            let value = control.next()
            progress(0.25)
            if value == 1 { _ = control.gate.wait(timeout: .now() + 5) }
            return value
        }
        let results = (0..<12).map { _ in LoadProgressRelay() }
        for relay in results {
            done.enter()
            DispatchQueue.global().async {
                let value = reading.value(maxAge: 60, now: epoch) {
                    relay.report($0)
                    if $0 == 0.25 { joined.signal() }
                }
                XCTAssertEqual(value, 1)
                done.leave()
            }
        }
        for _ in results { XCTAssertEqual(joined.wait(timeout: .now() + 3), .success) }
        XCTAssertEqual(control.count, 1, "two modules must not walk the same cloud files together")
        control.gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(results.allSatisfy { $0.fraction == 1 })
        XCTAssertEqual(reading.value(maxAge: 60, now: epoch.addingTimeInterval(59), progress: { _ in }), 1)
        XCTAssertEqual(reading.value(maxAge: 60, now: epoch.addingTimeInterval(60), progress: { _ in }), 2)
    }

    func testInvalidationPreventsOldScanFromReturningOrOverwritingNewData() {
        let control = ScanControl(), started = DispatchSemaphore(value: 0), done = DispatchGroup()
        let reading = SharedSynchronousReading<Int> { _ in
            let value = control.next()
            if value == 1 {
                started.signal()
                _ = control.gate.wait(timeout: .now() + 5)
            }
            return value
        }
        done.enter()
        DispatchQueue.global().async {
            XCTAssertEqual(reading.value(maxAge: 60, progress: { _ in }), 2)
            done.leave()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        reading.invalidate()
        XCTAssertEqual(reading.value(maxAge: 60, progress: { _ in }), 2)
        control.gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(reading.current, 2)
        XCTAssertEqual(control.count, 2)
    }

    func testReconciliationKeepsOriginalCacheAge() {
        let control = ScanControl(), epoch = Date(timeIntervalSince1970: 100)
        let reading = SharedSynchronousReading<Int> { _ in control.next() }
        XCTAssertEqual(reading.value(maxAge: 60, now: epoch, progress: { _ in }), 1)
        reading.reconcile { $0.map { $0 + 10 } }
        XCTAssertEqual(reading.value(maxAge: 60, now: epoch.addingTimeInterval(59), progress: { _ in }), 11)
        XCTAssertEqual(reading.value(maxAge: 60, now: epoch.addingTimeInterval(60), progress: { _ in }), 2)
    }

    func testReconciliationRetiresScanStartedBeforeCloudEviction() {
        let control = ScanControl(), started = DispatchSemaphore(value: 0), done = DispatchGroup()
        let epoch = Date(timeIntervalSince1970: 100)
        let reading = SharedSynchronousReading<Int> { _ in
            let value = control.next()
            if value == 2 {
                started.signal()
                _ = control.gate.wait(timeout: .now() + 5)
            }
            return value
        }
        XCTAssertEqual(reading.value(maxAge: 60, now: epoch, progress: { _ in }), 1)
        done.enter()
        DispatchQueue.global().async {
            XCTAssertEqual(reading.value(maxAge: 1, now: epoch.addingTimeInterval(2), progress: { _ in }), 3)
            done.leave()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        reading.reconcile { $0.map { $0 + 10 } }
        XCTAssertEqual(reading.current, 11)
        control.gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(reading.current, 3, "the old scan is discarded; an expired cache still requires a fresh scan")
    }
}
