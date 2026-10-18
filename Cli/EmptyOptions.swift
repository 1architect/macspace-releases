import Foundation
import MacSpaceApp
import MacSpaceSdk

/// Options for CLI runs: no saved choices, so every toggle and background task reads as off.
struct EmptyOptions: OptionStore {
    func bool(_ id: String) -> Bool { false }
    func string(_ id: String) -> String { "" }
    func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
}

/// The modules a command works on: those of `--dir`, or of the app the CLI ships in.
enum CliModules {
    static func directory(_ arguments: [String]) -> URL {
        arguments.firstIndex(of: "--dir").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            ?? ModuleHost.defaultModulesDirectoryForCli()
    }

    /// The module with this id; exits when there is none.
    static func descriptor(_ id: String, _ arguments: [String]) -> ModuleDescriptor {
        let directory = directory(arguments)
        guard let descriptor = ModuleScanner.scan(directory: directory).modules.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("No module \(id) in \(directory.path)\n".utf8))
            exit(1)
        }
        return descriptor
    }
}
