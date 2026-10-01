import Foundation

public enum ToolLocator {
    /// The command-line tool that ships inside the app (`Contents/MacOS/MacSpaceCli`). Modules run risky private-API calls in it so a
    /// crash cannot take the app down. nil when not running from an app bundle (a development build uses `MACSPACE_CLI`).
    public static func cli(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        if let override = environment["MACSPACE_CLI"] { return URL(fileURLWithPath: override) }
        let url = bundle.bundleURL.appendingPathComponent("Contents/MacOS/MacSpaceCli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
