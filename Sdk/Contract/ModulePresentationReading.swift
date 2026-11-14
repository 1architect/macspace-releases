import Foundation

/// Optional capability for modules that can produce both surfaces from one coherent reading. The host uses this only when
/// a page is requested along with its tile; dashboard-only reads and legacy modules retain their existing tile/screen calls.
/// Keeping this separate from MacSpaceModule leaves its existing witness table and binary contract unchanged.
public protocol ModulePresentationReading: Sendable {
    func presentation(context: ModuleContext, progress: @escaping LoadProgressSink) async -> ModulePresentation
}

extension ModulePresentationReading {
    public func presentation(context: ModuleContext) async -> ModulePresentation {
        await presentation(context: context, progress: { _ in })
    }
}
