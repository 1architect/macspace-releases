import XCTest
@testable import MacSpacePlatform

final class AppNamesTests: XCTestCase {
    private func lookup(installed: [String: String] = [:], running: [(String, String)] = [], indexed: [String: String] = [:]) -> AppNames.Lookup {
        AppNames.Lookup(appURL: { installed[$0].map { URL(fileURLWithPath: "/Applications/\($0).app") } },
                        running: { running.map { (identifier: $0.0, name: $0.1) } },
                        indexedURL: { indexed[$0].map { URL(fileURLWithPath: $0) } })
    }

    func testInstalledAppNamedByItsBundleFile() {
        let found = lookup(installed: ["com.example.Writer": "Writer"])
        XCTAssertEqual(AppNames.name(for: "com.example.Writer", lookup: found), "Writer")
    }

    func testRunningAppNameWinsOverMadeUpOne() {
        let found = lookup(running: [("com.example.writer", "Writer Pro")])
        XCTAssertEqual(AppNames.name(for: "com.example.Writer", lookup: found), "Writer Pro")
    }

    func testExtensionTakesItsAppsName() {
        let found = lookup(running: [("net.whatsapp.WhatsApp", "WhatsApp")])
        XCTAssertEqual(AppNames.name(for: "net.whatsapp.WhatsApp.ServiceExtension", lookup: found), "WhatsApp")
    }

    func testShipItFolderTakesItsAppsName() {
        let found = lookup(running: [("com.example.Writer", "Writer")])
        XCTAssertEqual(AppNames.name(for: "com.example.Writer.ShipIt", lookup: found), "Writer")
    }

    func testKnownTableNamesAnUnresolvableApp() {
        XCTAssertEqual(AppNames.name(for: "com.steipete.codexbar", lookup: lookup()), "CodexBar")
    }

    func testUnresolvedIdentifierIsMadeReadableNeverShownRaw() {
        XCTAssertEqual(AppNames.name(for: "com.acme.cool-tool", lookup: lookup()), "Cool tool")
        XCTAssertEqual(AppNames.name(for: "org.example.WeatherDesk.helper", lookup: lookup()), "WeatherDesk")
        XCTAssertFalse(AppNames.name(for: "com.acme.unknownthing", lookup: lookup()).contains("."))
    }

    func testPlainNamesPassThrough() {
        XCTAssertEqual(AppNames.display("Sublime Text", lookup: lookup()), "Sublime Text")
        XCTAssertEqual(AppNames.display("pip", lookup: lookup()), "pip")
        XCTAssertEqual(AppNames.display("Google Chrome.app", lookup: lookup()), "Google Chrome.app")
    }

    func testIdentifierShape() {
        XCTAssertTrue(AppNames.looksLikeBundleIdentifier("com.steipete.codexbar"))
        XCTAssertFalse(AppNames.looksLikeBundleIdentifier("node.js"))
        XCTAssertFalse(AppNames.looksLikeBundleIdentifier("some folder.with.dots"))
    }
}

extension AppNamesTests {
    /// An app bundle of its own, named Notes: the Mac's own Notes is named in the Mac's language ("Notas" in Portuguese), which
    /// failed this test on a Mac not in English.
    private func notesApp() throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("AppNamesTests-\(UUID().uuidString)/Notes.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.apple.notes", "CFBundleName": "Notes", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        return app
    }

    func testGroupContainersAreNamedAfterTheirApp() throws {
        let notes = try notesApp()
        let found = AppNames.Lookup(appURL: { $0 == "com.apple.notes" ? notes : nil }, running: { [] }, indexedURL: { _ in nil })
        XCTAssertEqual(AppNames.display("group.com.apple.notes", lookup: found), "Notes")
        XCTAssertEqual(AppNames.display("group.com.apple.replicatord", lookup: found), "Replicatord")
        XCTAssertEqual(AppNames.display("com.apple.wallpaper.agent", lookup: found), "Wallpaper")
        XCTAssertEqual(AppNames.display("UBF8T346G9.com.microsoft.Office", lookup: found), "Office")
    }
}
