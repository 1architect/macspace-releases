import XCTest
import MacSpacePlatform

final class ByteFormatTests: XCTestCase {
    func testFormatsDecimalUnits() {
        XCTAssertTrue(ByteFormat.string(1_500_000_000).contains("GB"))
    }
}
