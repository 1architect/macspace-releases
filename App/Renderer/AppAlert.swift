import AppKit

/// The native macOS alert, with one leading edge for its icon, heading and full message.
/// Enforce the shared alignment after native layout and again immediately before drawing.
@MainActor
public final class AppAlert: NSAlert {
    public override init() {
        super.init()
        icon = NSApp.applicationIconImage
    }

    private var alignmentPass: AlertAlignmentPass?

    public override func runModal() -> NSApplication.ModalResponse {
        layout()
        return super.runModal()
    }

    public override func layout() {
        super.layout()
        guard let content = window.contentView else { return }
        // NSAlert can run another native layout while entering its modal session, after this override has returned.
        // Keep the correction in the view's drawing lifecycle too, so that later layout cannot be painted centered.
        if alignmentPass?.superview !== content {
            alignmentPass?.removeFromSuperview()
            let pass = AlertAlignmentPass(frame: content.bounds)
            pass.autoresizingMask = [.width, .height]
            pass.align = { [weak self] in self?.alignContent() }
            pass.setAccessibilityElement(false)
            content.addSubview(pass, positioned: .below, relativeTo: nil)
            alignmentPass = pass
        }
        alignContent()
    }

    private func alignContent() {
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
                let aligned = parent.convert(frame, from: content)
                if label.frame != aligned { label.frame = aligned }
            }
            if label.alignment != .left { label.alignment = .left }
            if label.maximumNumberOfLines != 0 { label.maximumNumberOfLines = 0 }
            if label.lineBreakMode != .byWordWrapping { label.lineBreakMode = .byWordWrapping }
            if label.cell?.truncatesLastVisibleLine == true { label.cell?.truncatesLastVisibleLine = false }
            // Native alerts also carry paragraph alignment in their attributed strings. The control's .alignment alone
            // does not override those runs, even when its frame and cell both report left alignment.
            let attributed = NSMutableAttributedString(attributedString: label.attributedStringValue)
            var changed = false
            attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let style = value as? NSParagraphStyle,
                      style.alignment != .left || style.lineBreakMode != .byWordWrapping,
                      let leading = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                leading.alignment = .left
                leading.lineBreakMode = .byWordWrapping
                attributed.addAttribute(.paragraphStyle, value: leading, range: range)
                changed = true
            }
            if changed { label.attributedStringValue = attributed }
        }
        for case let image as NSImageView in views where image.frame.width >= 24 && image.frame.height >= 24 {
            guard let parent = image.superview else { continue }
            var frame = image.convert(image.bounds, to: content)
            frame.origin.x = inset
            let aligned = parent.convert(frame, from: content)
            if image.frame != aligned { image.frame = aligned }
            if image.imageAlignment != .alignLeft { image.imageAlignment = .alignLeft }
        }
    }
}

/// A transparent, noninteractive participant in the native alert's final drawing pass.
@MainActor
private final class AlertAlignmentPass: NSView {
    var align: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillDraw() {
        super.viewWillDraw()
        align?()
    }
}
