import XCTest
@testable import MacSpaceApp

@MainActor
final class ReadProgressDeliveryTests: XCTestCase {
    func testBurstsPreserveInitialAndLatestValuesWithoutFloodingTheMainActor() async throws {
        var values: [Double] = [], times: [UInt64] = []
        let first = expectation(description: "Initial progress")
        let delivery = ReadProgressDelivery {
            values.append($0); times.append(DispatchTime.now().uptimeNanoseconds)
            if $0 == 0 { first.fulfill() }
        }
        defer { delivery.cancel() }
        delivery.report(0)
        await fulfillment(of: [first], timeout: 2)
        await Task.detached {
            for n in 1...10_000 { delivery.report(Double(n) / 10_000) }
            delivery.report(.nan); delivery.report(.infinity); delivery.report(0.2)
        }.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertLessThan(values.count, 10)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 33_000_000 })
    }

    func testCancellationRejectsBothQueuedAndLateReports() async throws {
        var values: [Double] = []
        let first = expectation(description: "Initial progress")
        let delivery = ReadProgressDelivery { values.append($0); first.fulfill() }
        delivery.report(0)
        await fulfillment(of: [first], timeout: 2)
        delivery.report(0.8)
        delivery.cancel()
        delivery.report(1)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(values, [0])
    }
}
