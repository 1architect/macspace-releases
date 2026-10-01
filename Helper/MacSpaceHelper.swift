import Foundation
import MacSpaceDebloatPrivileged
import MacSpacePlatform
import MacSpaceSiriPrivileged
import MacSpaceSystemDataPrivileged

/// The MacSpace privileged helper: a launch daemon the app registers with `SMAppService`. It serves `com.macspace.helper`
/// and runs only the named operations contributed by the modules' Privileged libraries, for clients that satisfy the
/// code-signing requirement in its launchd plist (which the app's signature covers).
@main
struct MacSpaceHelper {
    static func main() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--client-requirement"), arguments.indices.contains(index + 1),
              !arguments[index + 1].trimmingCharacters(in: .whitespaces).isEmpty else {
            FileHandle.standardError.write(Data("MacSpaceHelper: refusing to start without --client-requirement <code signing requirement>\n".utf8))
            exit(78) // EX_CONFIG
        }
        let service = PrivilegedHelperService(handlers: [SiriPrivilegedOperations(), DebloatPrivilegedOperations(), SystemDataPrivilegedOperations()])
        let delegate = PrivilegedHelperListenerDelegate(service: service, clientRequirement: arguments[index + 1])
        let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
    }
}
