import MacSpaceSdk
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

    func testRowFlagReservesNumericVariantsWithoutReservingUnrelatedFuturePhrases() throws {
        let samples = ["Liberar", "Liberando espaço", "Liberando em segundo plano", "Removendo 111,1 MB", "Removendo 888,8 MB"]
        func label(_ text: String) -> some View {
            ReservedPillLabel(samples: PillLabelSamples.matching(text, samples: samples), reserveWidth: true) {
                ChangingText(text: text)
            }
        }
        let short = try size(label("Liberando espaço"))
        let expected = try size(Text(verbatim: "Liberando espaço").font(.system(size: 11, weight: .semibold)))
        XCTAssertEqual(short.width, expected.width + 16, accuracy: 0.5)
        XCTAssertLessThan(short.width, try size(label("Liberando em segundo plano")).width)
        XCTAssertEqual(try size(label("Removendo 111,1 MB")), try size(label("Removendo 888,8 MB")))
        XCTAssertEqual(short.height, 18)
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
    func testRowLayoutAnimatesAtWorkStartAndLabelChangesButNotFractionTicks() {
        let action = Action(id: "free", title: "Liberar", workingTitle: "Liberando espaço")
        let row = Row(id: "logs", title: "Registro do sistema", actions: [action])
        let idle = RowActivity().flagLayout(for: row)
        var activity = RowActivity(rowID: row.id, action: action)
        let started = activity.flagLayout(for: row)
        XCTAssertNotEqual(started, idle, "starting work must animate the row even before the module sends progress")
        activity.progress = ActionProgress(fraction: 0.1, message: "Liberando espaço")
        XCTAssertEqual(activity.flagLayout(for: row), started)
        activity.progress = ActionProgress(fraction: 0.9, message: "Liberando espaço")
        XCTAssertEqual(activity.flagLayout(for: row), started, "fraction updates must not restart neighbouring controls")
        activity.progress = ActionProgress(message: "Liberando em segundo plano")
        XCTAssertNotEqual(activity.flagLayout(for: row), started)
        activity.rowID = "another-row"
        XCTAssertEqual(activity.flagLayout(for: row), idle)
    }

}
