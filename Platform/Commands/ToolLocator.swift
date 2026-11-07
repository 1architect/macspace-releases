import Foundation

public enum ToolLocator {
    public static let metadataWorkerPath = "Contents/Helpers/MacSpaceCli.app/Contents/MacOS/MacSpaceCli"

    /// Both the GUI and its provisioned CLI worker locate resources in the containing app.
    public static func appBundle(containing bundle: Bundle = .main) -> Bundle? {
        var candidate = bundle.bundleURL
        for _ in 0..<8 {
            if candidate.pathExtension == "app", let app = Bundle(url: candidate), app.bundleIdentifier == "com.macspace.app" { return app }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    /// Restricted Keychain entitlements belong to the profile-bearing worker bundle.
    /// The legacy plain CLI remains available for helper registration and forwards other commands.
    public static func cli(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        #if DEBUG
        if let override = environment["MACSPACE_CLI"] { return URL(fileURLWithPath: override) }
        #endif
        guard let app = appBundle(containing: bundle) else { return nil }
        let url = app.bundleURL.appendingPathComponent(metadataWorkerPath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
