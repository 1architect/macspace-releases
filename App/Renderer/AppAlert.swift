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
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(content)
        let labels = views.compactMap { $0 as? NSTextField }
        guard labels.contains(where: { $0.stringValue == messageText }) else { return }
        // Align the fields' frames too. A short heading's native frame is centered; changing its text alignment alone keeps
        // the icon and short cache-confirmation title centered as a group.
        let inset: CGFloat = 20
        let width = max(content.bounds.width - inset * 2, 0)
        for label in labels where label.stringValue == messageText || label.stringValue == informativeText {
            if let parent = label.superview {
                var frame = label.convert(label.bounds, to: content)
                frame.origin.x = inset
                frame.size.width = width
                label.frame = parent.convert(frame, from: content)
            }
            label.alignment = .left
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = false
        }
        for case let image as NSImageView in views where image.frame.width >= 24 && image.frame.height >= 24 {
            guard let parent = image.superview else { continue }
            var frame = image.convert(image.bounds, to: content)
            frame.origin.x = inset
            image.frame = parent.convert(frame, from: content)
        }
    }
}
