import XCTest
@testable import MacSpacePlatform

final class ToolLocatorTests: XCTestCase {
    func testGuiAndWorkerResolveTheSameProfileBearingTool() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("MacSpace.app")
        let worker = app.appendingPathComponent("Contents/Helpers/MacSpaceCli.app")
        func makeBundle(_ url: URL, identifier: String, executable: String) throws -> Bundle {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            let binary = url.appendingPathComponent("Contents/MacOS/" + executable)
            try Data().write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            return try XCTUnwrap(Bundle(url: url))
        }
        let guiBundle = try makeBundle(app, identifier: "com.macspace.app", executable: "MacSpace")
        let cliBundle = try makeBundle(worker, identifier: "com.macspace.cli", executable: "MacSpaceCli")
        let expected = worker.appendingPathComponent("Contents/MacOS/MacSpaceCli")
        XCTAssertEqual(ToolLocator.cli(environment: [:], bundle: guiBundle), expected)
        XCTAssertEqual(ToolLocator.cli(environment: [:], bundle: cliBundle), expected)
        XCTAssertEqual(ToolLocator.appBundle(containing: cliBundle)?.bundleURL.path, app.path)
        try FileManager.default.removeItem(at: expected)
        XCTAssertNil(ToolLocator.cli(environment: [:], bundle: guiBundle))
    }
}
