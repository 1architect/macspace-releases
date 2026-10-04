import Foundation
import MacSpaceApp
import MacSpacePlatform
import MacSpaceSdk

/// `MacSpaceCli action <module-id> <action-id> [key=value ...] [--dir <folder>]` runs a module action as the app does (the
/// helper included) and prints its result as JSON, with no confirmation: for scripts that test the app end to end
/// (`Scripts/SelfTest.sh`). Exits 0 when the action succeeded or needs the user, 1 when it failed.
enum ActionCommand {
    static func run(_ arguments: [String]) async -> Never {
        let positional = arguments.enumerated().filter { index, argument in
            !argument.hasPrefix("--") && !argument.contains("=") && (index == 0 || arguments[index - 1] != "--dir")
        }.map(\.element)
        guard positional.count >= 2 else {
            FileHandle.standardError.write(Data("usage: MacSpaceCli action <module-id> <action-id> [key=value ...]\n".utf8))
            exit(64)
        }
        let parameters = Dictionary(arguments.filter { $0.contains("=") && !$0.hasPrefix("--") }.map { argument -> (String, String) in
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { _, last in last })
        let directory = arguments.firstIndex(of: "--dir").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            ?? ModuleHost.defaultModulesDirectoryForCli()
        guard let descriptor = ModuleScanner.scan(directory: directory).modules.first(where: { $0.id == positional[0] }) else {
            FileHandle.standardError.write(Data("No module \(positional[0]) in \(directory.path)\n".utf8))
            exit(1)
        }
        do {
            let module = try ModuleLoader.load(descriptor)
            let context = ModuleContext(manifest: descriptor.manifest, options: EmptyOptions(), permissions: LivePermissionChecker(),
                                        privileged: LazyPrivilegedChannel())
            let result = await module.perform(ActionRequest(actionID: positional[1], parameters: parameters), context: context) { update in
                FileHandle.standardError.write(Data("… \(update.message)\n".utf8))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(result))
            print()
            exit(result.outcome == .failed ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
