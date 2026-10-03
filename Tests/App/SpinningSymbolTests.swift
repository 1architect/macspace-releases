import XCTest
@testable import MacSpaceApp

final class SpinningSymbolTests: XCTestCase {
    func testASpinGathersSpeedSmoothly() {
        XCTAssertEqual(SpinningSymbol.speed(after: 0), 0)
        XCTAssertEqual(SpinningSymbol.speed(after: 5), 360 / SpinningSymbol.turn, accuracy: 0.01)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let spin = SpinningSymbol.Motion.spinning(since: start, from: 0)
        XCTAssertEqual(SpinningSymbol.angle(spin, at: start), 0, accuracy: 0.0001)
        var last = 0.0
        for step in 1...100 {
            let angle = SpinningSymbol.angle(spin, at: start.addingTimeInterval(Double(step) * 0.02))
            XCTAssertGreaterThan(angle, last, "always forward")
            last = angle
        }
    }

    func testStoppingSlowsToUprightWithoutPassingIt() {
        for (angle, speed) in [(17.0, 30.0), (200.0, 400.0), (700.0, 423.5), (1075.0, 423.5), (359.0, 1.0)] {
            let end = SpinningSymbol.settle(from: angle, speed: speed)
            XCTAssertEqual(end.to.truncatingRemainder(dividingBy: 360), 0, "ends upright")
            XCTAssertGreaterThan(end.to, angle)
            XCTAssertTrue((0.35...0.8).contains(end.duration))
            let start = Date(timeIntervalSinceReferenceDate: 0)
            let settling = SpinningSymbol.Motion.settling(since: start, from: angle, speed: speed, to: end.to, duration: end.duration)
            var last = angle
            for step in 1...50 {
                let now = SpinningSymbol.angle(settling, at: start.addingTimeInterval(end.duration * Double(step) / 50))
                XCTAssertGreaterThanOrEqual(now, last - 0.0001, "never turns back")
                XCTAssertLessThanOrEqual(now, end.to + 0.0001, "never passes upright")
                last = now
            }
            XCTAssertEqual(last, end.to, accuracy: 0.0001)
            // It leaves at the speed it had.
            let early = SpinningSymbol.angle(settling, at: start.addingTimeInterval(0.001))
            XCTAssertEqual((early - angle) / 0.001, speed, accuracy: speed * 0.02 + 1)
        }
    }
}
