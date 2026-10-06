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
        let changed = original.applying(lab, tint: .violet, light: false)
        XCTAssertEqual(LabColor(changed.step(2)), red)
        XCTAssertEqual(LabColor(changed.step(1)), LabColor(original.step(1)))
        XCTAssertEqual(LabColor(changed.base), LabColor(original.base))
        XCTAssertEqual(LabColor(PaletteScheme.deep.palette(.blue).applying(lab, tint: .blue, light: false).step(2)), LabColor(PaletteScheme.deep.palette(.blue).step(2)),
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

    func testOverridesSavedBeforeTheStudioStillLoad() throws {
        let old = #"{"colors":{"ink":{"red":1,"green":1,"blue":1,"alpha":1}},"fills":{}}"#
        let decoded = try JSONDecoder().decode(LabOverrides.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.colors.count, 1)
        XCTAssertTrue(decoded.mains.isEmpty)
        XCTAssertTrue(decoded.shadings.isEmpty)
    }

    func testATileTakesItsOwnShadingElseTheOneForEveryTile() {
        var lab = LabOverrides()
        lab.shadings[FillTarget.tiles.key] = ShadingSpec(style: .glow)
        XCTAssertEqual(lab.shading(.tile(.blue))?.style, .glow)
        lab.shadings[FillTarget.tile(.blue).key] = ShadingSpec(style: .flat)
        XCTAssertEqual(lab.shading(.tile(.blue))?.style, .flat)
        XCTAssertNil(lab.shading(.chartElements))
        XCTAssertEqual(Design(lab: LabOverrides()).shading(.tile(.teal))?.style, .lit, "tiles keep their light until changed")
        XCTAssertNil(Design(lab: LabOverrides()).shading(.mainButton))
    }

    func testTheRampRunsFromTheGroundThroughTheMainColor() {
        let main = LabColor(red: 0x7F / 255, green: 0x77 / 255, blue: 0xDD / 255)
        for light in [false, true] {
            let palette = PaletteRamp.palette(main: main, light: light)
            let levels = ([palette.base] + palette.steps).map { OKLab(LabColor($0)).l }
            for (a, b) in zip(levels, levels.dropFirst()) {
                if light { XCTAssertLessThan(b, a, "a light palette runs light to dark") } else { XCTAssertGreaterThan(b, a, "a dark one dark to light") }
            }
            XCTAssertEqual(OKLab(LabColor(palette.step(3))).hue, OKLab(main).hue, accuracy: 0.05, "the steps keep the main color's hue")
        }
        let dark = PaletteRamp.palette(main: main, light: false)
        XCTAssertEqual(LabColor(dark.step(3)).blue, main.blue, accuracy: 0.03, "the fourth step is the main color")
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
