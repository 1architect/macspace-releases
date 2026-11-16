import XCTest
@testable import MacSpaceSiri

final class SiriPurgeableAssetReadingTests: XCTestCase {
    func testHeldAssetsSkipEstimateAndEligibilityChangesAreRechecked() async {
        let first = SiriPurgeableAssetReading.read(held: { true }) {
            XCTFail("A held asset estimate would be discarded")
            return 1
        }
        let stillHeld = await first.resolve(held: { true }) {
            XCTFail("The held reading should still skip the estimate")
            return 2
        }
        XCTAssertNil(stillHeld)
        let released = await first.resolve(held: { false }) { 4096 }
        XCTAssertEqual(released, 4096)

        var held = false
        let heldDuringEstimate = await first.resolve(held: { held }) {
            held = true
            return 8192
        }
        XCTAssertNil(heldDuringEstimate)
    }

    func testMissingEstimateKeepsTheOriginalFailureWithoutRetrying() async {
        let reading = SiriPurgeableAssetReading.read(held: { false }, estimate: { nil })
        let result = await reading.resolve(held: { false }) {
            XCTFail("An attempted estimate already answered")
            return 3
        }
        XCTAssertNil(result)
        let hidden = await SiriPurgeableAssetReading.estimated(4096).resolve(held: { true }) {
            XCTFail("A completed estimate should not be repeated")
            return 3
        }
        XCTAssertNil(hidden)
    }
}
