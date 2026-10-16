import AppKit

/// The native macOS alert, with one leading edge for its icon, heading and full message.
/// Override layout so runModal's own layout pass cannot put the icon back in the center.
@MainActor
public final class AppAlert: NSAlert {
    public override init() {
        super.init()
        icon = NSApp.applicationIconImage
    }

    public override func layout() {
        super.layout()
        guard let content = window.contentView else { return }
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        guard let heading = labels.first(where: { $0.stringValue == messageText }) else { return }
        for label in labels where label.stringValue == messageText || label.stringValue == informativeText {
            label.alignment = .left
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = false
        }
        for case let image as NSImageView in content.subviews {
            image.setFrameOrigin(NSPoint(x: heading.frame.minX, y: image.frame.minY))
        }
    }
}
