import Foundation
import MacSpaceApp
import MacSpacePlatform
import MacSpaceSdk

/// `MacSpaceCli screen <module-id> [--dir <folder>] [--summary]` prints the screen (or dashboard tile) a module produces,
/// as JSON, using this Mac's real state. For development and for checking what the app would draw.
enum ScreenCommand {
    static func run(_ arguments: [String]) async -> Never {
        guard let id = arguments.first(where: { !$0.hasPrefix("--") && !$0.contains("/") }) else {
            FileHandle.standardError.write(Data("usage: MacSpaceCli screen <module-id> [--dir <folder>] [--summary]\n".utf8))
            exit(64)
        }
        let directory = arguments.firstIndex(of: "--dir").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            ?? ModuleHost.defaultModulesDirectoryForCli()
        guard let descriptor = ModuleScanner.scan(directory: directory).modules.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("No module \(id) in \(directory.path)\n".utf8))
            exit(1)
        }
        do {
            let module = try ModuleLoader.load(descriptor)
            let context = ModuleContext(manifest: descriptor.manifest, options: EmptyOptions(), permissions: LivePermissionChecker())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = arguments.contains("--summary") ? try encoder.encode(await module.summary(context: context))
                                                       : try encoder.encode(await module.screen(context: context))
            FileHandle.standardOutput.write(data)
            print()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
