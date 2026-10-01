import Foundation
import MacSpaceApp
import MacSpacePlatform
import MacSpaceSdk

/// `macspace modules` lists the modules the app would load. More commands arrive with the modules.
@main
struct MacSpaceCli {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "purge-assets" { PurgeCommand.run(Array(arguments.dropFirst())) }
        if arguments.first == "orphan-subscriptions" { OrphanCommand.run(Array(arguments.dropFirst())) }
        if arguments.first == "screen" { await ScreenCommand.run(Array(arguments.dropFirst())) }
        guard arguments.first == "modules" else {
            print("""
            usage: MacSpaceCli modules [--dir <folder>] [--load]
                   MacSpaceCli orphan-subscriptions [--execute] [--json]   (root to execute)
                   MacSpaceCli screen <module-id> [--dir <folder>] [--summary]
                   MacSpaceCli purge-assets [--execute] [--self-test] [--allow-unverified] [--json]
            """)
            exit(arguments.isEmpty ? 0 : 64)
        }
        let directory = arguments.firstIndex(of: "--dir").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            ?? ModuleHost.defaultModulesDirectoryForCli()
        let found = ModuleScanner.scan(directory: directory)
        for module in found.modules {
            let status: String
            switch module.compatibility {
            case .compatible: status = "ok"
            case let .incompatible(reason): status = "incompatible: \(reason)"
            }
            print("\(module.manifest.id)  \(module.manifest.version)  \(module.manifest.name)  [\(status)]")
        }
        for problem in found.problems { print("\(problem.bundleName): \(problem.reason)") }
        // --load runs each module's code: a smoke test that the bundles load and answer.
        if arguments.contains("--load") {
            var failed = false
            for descriptor in found.modules where descriptor.compatibility == .compatible {
                do {
                    let module = try ModuleLoader.load(descriptor)
                    let title = await module.screen(context: ModuleContext(manifest: descriptor.manifest, options: EmptyOptions(),
                                                                            permissions: LivePermissionChecker())).title
                    print("loaded \(descriptor.id): screen \"\(title)\"")
                } catch {
                    failed = true
                    print("failed \(descriptor.id): \(error.localizedDescription)")
                }
            }
            exit(failed ? 1 : 0)
        }
    }
}
