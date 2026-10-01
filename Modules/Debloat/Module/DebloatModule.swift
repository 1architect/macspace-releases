import Foundation
import MacSpaceSdk

@objc(MacSpaceDebloatEntry)
public final class DebloatEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { DebloatModule() }
}

/// Placeholder until the real Debloat module is moved in.
public struct DebloatModule: MacSpaceModule {
    public init() {}

    public func summary(context: ModuleContext) async -> ScreenWidget {
        .banner(Banner(id: "placeholder", severity: .info, title: "Debloat", message: "Not built yet."))
    }

    public func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Debloat", widgets: [.text(TextWidget(id: "todo", text: "Coming soon."))])
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        .failed("Nothing to do yet.")
    }
}
