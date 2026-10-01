import Foundation
import MacSpaceSdk

@objc(MacSpaceSiriEntry)
public final class SiriEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { SiriModule() }
}

/// Placeholder until the real Siri module is moved in.
public struct SiriModule: MacSpaceModule {
    public init() {}

    public func summary(context: ModuleContext) async -> ScreenWidget {
        .banner(Banner(id: "placeholder", severity: .info, title: "Siri & Apple Intelligence", message: "Not built yet."))
    }

    public func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Siri & Apple Intelligence", widgets: [.text(TextWidget(id: "todo", text: "Coming soon."))])
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        .failed("Nothing to do yet.")
    }
}
