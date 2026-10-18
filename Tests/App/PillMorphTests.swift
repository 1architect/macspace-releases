import SwiftUI
import XCTest
@testable import MacSpaceApp

/// Offscreen layout only: no application windows or screenshots.
@MainActor
final class PillMorphTests: XCTestCase {
    private final class Placement: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGRect?
        var bounds: CGRect? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private struct LabelProbe: Layout {
        let natural: CGSize
        let placement: Placement
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { natural }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            placement.bounds = bounds
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(natural))
        }
    }

    func testShellInterpolatesWithoutScalingOrRecenteringItsLabel() throws {
        for natural in [CGSize(width: 180, height: 18), CGSize(width: 65, height: 31), CGSize(width: 330, height: 62)] {
            for width in stride(from: 50.0, through: 220.0, by: 34) {
                let placement = Placement()
                let shell = CGSize(width: width, height: natural.height)
                let view = PillMorphLayout(size: shell) {
                    LabelProbe(natural: natural, placement: placement) { Color.clear }
                }
                let renderer = ImageRenderer(content: view)
                var rendered: CGSize?
                renderer.render { size, _ in rendered = size }
                XCTAssertEqual(try XCTUnwrap(rendered), shell)
                let label = try XCTUnwrap(placement.bounds)
                XCTAssertEqual(label.origin, .zero, "the label stays pinned while the shell grows or shrinks")
                XCTAssertEqual(label.size, natural, "the shell cannot compress or scale the glyph layout")
            }
        }
    }

    func testFirstLayoutUsesNaturalSizeWithoutAZeroSizeFrame() throws {
        let natural = CGSize(width: 116, height: 31)
        let view = PillMorphLayout(size: nil) {
            LabelProbe(natural: natural, placement: Placement()) { Color.clear }
        }
        let renderer = ImageRenderer(content: view)
        var rendered: CGSize?
        renderer.render { size, _ in rendered = size }
        XCTAssertEqual(try XCTUnwrap(rendered), natural)
    }
}
