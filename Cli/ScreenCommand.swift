import Foundation
import MacSpaceApp
import MacSpacePlatform
import MacSpaceSdk

/// `MacSpaceCli screen <module-id> [--dir <folder>] [--tile] [--progress]` prints the screen (or dashboard tile) a module produces,
/// as JSON, using this Mac's real state, the helper's measurements included as the app has them (without it, the places only root
/// can read were missing and their rows with them). For development and for checking what the app would draw. `--progress` also
/// writes the reading's progress to standard error as it comes, each with the seconds since the start.
enum ScreenCommand {
    static func run(_ arguments: [String]) async -> Never {
        guard let id = arguments.first(where: { !$0.hasPrefix("--") && !$0.contains("/") }) else {
            FileHandle.standardError.write(Data("usage: MacSpaceCli screen <module-id> [--dir <folder>] [--tile]\n".utf8))
            exit(64)
        }
        let descriptor = CliModules.descriptor(id, arguments)
        do {
            let module = try ModuleLoader.load(descriptor)
            let context = ModuleContext(manifest: descriptor.manifest, options: EmptyOptions(), permissions: LivePermissionChecker(),
                                        privileged: LazyPrivilegedChannel())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let started = Date()
            let progress: LoadProgressSink = { fraction in
                FileHandle.standardError.write(Data(String(format: "%6.2f s  %3.0f%%\n", Date().timeIntervalSince(started), fraction * 100).utf8))
            }
            let reports = arguments.contains("--progress")
            let data = arguments.contains("--tile")
                ? try encoder.encode(reports ? await module.tile(context: context, progress: progress) : await module.tile(context: context))
                : try encoder.encode(reports ? await module.screen(context: context, progress: progress) : await module.screen(context: context))
            FileHandle.standardOutput.write(data)
            print()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
