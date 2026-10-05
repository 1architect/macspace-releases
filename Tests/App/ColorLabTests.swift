import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

final class ColorLabTests: XCTestCase {
    func testATileTakesItsOwnFillElseTheOneForEveryTile() {
        var lab = LabOverrides()
        XCTAssertNil(lab.fill(.tile(.blue)))
        lab.fills[FillTarget.tiles.key] = FillSpec(kind: .radial)
        XCTAssertEqual(lab.fill(.tile(.blue))?.kind, .radial)
        lab.fills[FillTarget.tile(.blue).key] = FillSpec(kind: .angular)
        XCTAssertEqual(lab.fill(.tile(.blue))?.kind, .angular)
        XCTAssertEqual(lab.fill(.tile(.teal))?.kind, .radial)
        XCTAssertNil(lab.fill(.chartElements), "the tiles' fill is not the chart elements'")
    }

    func testColorOverridesReplaceOnlyTheirRole() {
        let original = PaletteScheme.deep.palette(.violet)
        var lab = LabOverrides()
        let red = LabColor(red: 1, green: 0, blue: 0)
        lab.colors[ColorRole.step(.violet, 2).key] = red
        let changed = original.applying(lab, tint: .violet)
        XCTAssertEqual(LabColor(changed.step(2)), red)
        XCTAssertEqual(LabColor(changed.step(1)), LabColor(original.step(1)))
        XCTAssertEqual(LabColor(changed.base), LabColor(original.base))
        XCTAssertEqual(LabColor(PaletteScheme.deep.palette(.blue).applying(lab, tint: .blue).step(2)), LabColor(PaletteScheme.deep.palette(.blue).step(2)),
                       "another tile color keeps its own")
    }

    func testAStopShadesTheElementColor() {
        let stop = FillStop(location: 0, shade: 1, opacity: 1)
        XCTAssertEqual(LabColor(stop.resolved(element: .red)).green, 1, accuracy: 0.01, "fully shaded toward white")
        let own = FillStop(location: 0, usesElementColor: false, color: LabColor(red: 0, green: 0, blue: 1), shade: 0, opacity: 0.5)
        XCTAssertEqual(LabColor(own.resolved(element: .red)).blue, 1, accuracy: 0.01)
        XCTAssertEqual(LabColor(own.resolved(element: .red)).alpha, 0.5, accuracy: 0.01)
    }

    func testOverridesSurviveAJSONRoundTrip() throws {
        var lab = LabOverrides()
        lab.fills["window"] = FillSpec(kind: .linear, angle: 45)
        lab.colors["ink"] = LabColor(red: 0.2, green: 0.3, blue: 0.4)
        let decoded = try JSONDecoder().decode(LabOverrides.self, from: JSONEncoder().encode(lab))
        XCTAssertEqual(decoded, lab)
    }
}

final class BackgroundAppearanceTests: XCTestCase {
    func testTheBackgroundFollowsWhatWasChosen() {
        var design = Design(scheme: .deep, systemIsDark: false)
        XCTAssertFalse(design.backgroundIsLight, "the palette's: a deep palette is dark")
        design.backgroundAppearance = .system
        XCTAssertTrue(design.backgroundIsLight, "the system is light")
        design.systemIsDark = true
        XCTAssertFalse(design.backgroundIsLight, "the system turned dark")
        design.backgroundAppearance = .light
        XCTAssertTrue(design.backgroundIsLight, "light whatever the system says")
        design.scheme = .paper
        design.backgroundAppearance = .dark
        XCTAssertFalse(design.backgroundIsLight, "dark under a light palette")
        XCTAssertTrue(design.isLight, "the tiles keep the palette's")
    }
}
