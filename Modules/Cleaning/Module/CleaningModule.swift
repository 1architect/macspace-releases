import Foundation
import MacSpaceSdk

@objc(MacSpaceCleaningEntry)
public final class CleaningEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { CleaningModule() }
}

/// Placeholder until the real Cleaning module is moved in.
public struct CleaningModule: MacSpaceModule {
    public init() {}

    public func summary(context: ModuleContext) async -> ScreenWidget {
        .banner(Banner(id: "placeholder", severity: .info, title: "Cleaning", message: "Not built yet."))
    }

    public func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Cleaning", widgets: [.text(TextWidget(id: "todo", text: "Coming soon."))])
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        .failed("Nothing to do yet.")
    }
}
