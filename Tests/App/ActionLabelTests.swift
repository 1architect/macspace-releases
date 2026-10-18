import SwiftUI
import XCTest
@testable import MacSpaceApp

/// Offscreen layout assertions; no app windows or GUI automation.
@MainActor
final class ActionLabelTests: XCTestCase {
    private func size<V: View>(_ view: V, width: CGFloat? = nil) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var measured: CGSize?
        renderer.render { value, _ in measured = value }
        return try XCTUnwrap(measured)
    }

    func testRowFlagKeepsItsWidthAndItsNeighboursAcrossProgressAndResult() throws {
        let phases = ["Liberar", "Liberando espaço", "Removendo downloads", "Removendo Zero KB", "Removendo 116,6 MB", "Concluído"]
        let expected = try size(ReservedPillLabel(samples: phases, reserveWidth: true) { ChangingText(text: phases[0]) })
        for text in phases + ["An unexpectedly long error message that must truncate without moving the controls"] {
            let flag = ReservedPillLabel(samples: phases, reserveWidth: true) { ChangingText(text: text) }
            XCTAssertEqual(try size(flag), expected)
            XCTAssertEqual(try size(HStack(spacing: 6) { flag; Color.clear.frame(width: 28, height: 18) }).width, expected.width + 34)
            XCTAssertEqual(expected.height, 18)
        }
    }

    func testIdleFreeFlagDoesNotDrawTheEmptyProgressReservation() throws {
        for (title, working) in [("Free", "Freeing space"), ("Liberar", "Liberando espaço"), ("解放", "選択した項目を解放しています")] {
            let samples = [title, working]
            let idle = try size(ReservedPillLabel(samples: samples, reserveWidth: false) { ChangingText(text: title) })
            let active = try size(ReservedPillLabel(samples: samples, reserveWidth: true) { ChangingText(text: working) })
            let titleSize = try size(Text(verbatim: title).font(.system(size: 11, weight: .semibold)))
            XCTAssertEqual(idle.width, titleSize.width + 16, accuracy: 0.5, "idle capsule fits its title and normal padding")
            XCTAssertLessThan(idle.width, active.width)
            XCTAssertEqual(idle.height, 18)
            XCTAssertEqual(active.height, 18)
        }
    }

    func testOrangeButtonIsAlwaysOneLineAndNeverGetsTallerEvenUnderNarrowProposals() throws {
        for text in ["Carregando", "Liberar selecionados 2,1 GB", "A very long warning that is wider than this module page", "正在释放空间", "選択した項目 2.1 GB を解放"] {
            for available in [100.0, 220.0, 560.0] {
                let label = SingleLineActionLabel(text: text, maximumWidth: available)
                for proposal in [30.0, 90.0, available] {
                    let measured = try size(label, width: proposal)
                    XCTAssertEqual(measured.height, 31)
                    XCTAssertLessThanOrEqual(measured.width, available)
                }
            }
        }
    }

    func testTransientMorphWidthCannotMakeLoadingOrSelectedTextWrap() throws {
        for text in ["Carregando", "Liberar selecionados 2,1 GB"] {
            let expected = try size(SingleLineActionLabel(text: text, maximumWidth: 600))
            XCTAssertGreaterThan(expected.width, 70)
            for width in [30.0, 70.0, 95.0] {
                let label = SingleLineActionLabel(text: text, maximumWidth: 600)
                XCTAssertEqual(try size(label, width: width), expected, "measure the destination width independently of the morph's current width")
            }
        }
    }
}
