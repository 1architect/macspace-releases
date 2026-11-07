import XCTest
import MacSpaceSdk
final class SelectionEncodingSecurityTests: XCTestCase {
    func testOpaqueNamesRoundTripExactly() throws {
        let ids = ["cache:new\ncache:other", "a,b", "\u{1F512}日本語", "é", "combining:e\u{301}"]
        XCTAssertEqual(try Selection.decodeIDs(Selection.parameter(ids)), ids)
    }
    func testLegacyMalformedDuplicateAndOversizedParametersRefuse() {
        for input in ["a\nb", "a,b", "ids:v1:invalid", "ids:v1:" + Data("[\"a\",\"a\"]".utf8).base64EncodedString(), String(repeating: "x", count: Selection.maximumParameterBytes * 2)] {
            XCTAssertThrowsError(try Selection.decodeIDs(input))
        }
        XCTAssertThrowsError(try Selection.decodeIDs(Selection.parameter(["a", "a"])))
    }
}
