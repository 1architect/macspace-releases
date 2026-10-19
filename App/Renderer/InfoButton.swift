import AppKit
import MacSpaceSdk
import SwiftUI

/// A small (i) after a title. A click opens a balloon of Liquid Glass (a popover, which macOS draws in glass) that says what the item
/// is and, when it has any, the steps to follow; a click anywhere else closes it. Nothing is drawn when there is nothing to say.
///
/// Descriptions used to be tooltips, which take a second to appear and cannot be found without hovering, and steps opened under
/// their row, pushing the rows below it down.
struct InfoButton: View {
    let text: String?
    var steps: [String] = []
    /// A line under the text, quieter (a caveat, like "Menu names can differ between macOS versions.").
    var note: String?
    @State private var shown = false
    @State private var hovering = false
    @Environment(\.design) private var design

    private var paragraphs: [String] {
        (text ?? "").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var hasContent: Bool { !paragraphs.isEmpty || !steps.isEmpty || !(note ?? "").isEmpty }

    var body: some View {
        Group {
            if hasContent {
                Button { shown.toggle() } label: {
                    // A ring as tall as the folder beside it and of its line (11 and 1 points at 12 points), with the letter in SF,
                    // as the app's text: the symbol's own "i" has serifs. The letter is centered on its own outline, not on a line of
                    // text, which left it off center.
                    ZStack {
                        Circle().strokeBorder(lineWidth: 1)
                        SFLetter(letter: "i").frame(height: 6)
                    }
                    .frame(width: 11, height: 11)
                    .rowPill(active: hovering || shown)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(Theme.hover, value: hovering || shown)
                .accessibilityLabel(String(localized: "More about this"))
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    InfoBalloon(paragraphs: paragraphs, steps: steps, note: note)
                        .environment(\.colorScheme, design.colorScheme)
                        .background(PopoverAppearance(isLight: design.isLight))
                }
                .transition(PageCascade.transition(index: 0, count: 1))
            }
        }
        .animation(Theme.value, value: hasContent)
    }
}

/// Gives a popover's window the palette's appearance, not the system's: the balloon's glass is drawn by its window, so under a light
/// system appearance it stayed light on the night palettes, whatever its text was told.
private struct PopoverAppearance: NSViewRepresentable {
    let isLight: Bool

    final class Marker: NSView {
        var name: NSAppearance.Name = .darkAqua { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private func apply() {
            guard let window, window.appearance?.name != name else { return }
            window.appearance = NSAppearance(named: name)
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) { view.name = isLight ? .aqua : .darkAqua }
}

/// A letter of the system font as a shape, scaled to the height it is given and centered on its own outline.
struct SFLetter: Shape {
    let letter: Character
    var weight: NSFont.Weight = .regular

    /// The letter's outline, made once per letter and weight: every (i) of a page drew it again from the font at each layout.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outlines: [String: CGPath] = [:]

    private var outline: CGPath? {
        let key = "\(letter)\(weight.rawValue)"
        if let cached = Self.lock.withLock({ Self.outlines[key] }) { return cached }
        let font = NSFont.systemFont(ofSize: 100, weight: weight) as CTFont
        var characters = Array(String(letter).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
              let outline = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { return nil }
        Self.lock.withLock { Self.outlines[key] = outline }
        return outline
    }

    func path(in rect: CGRect) -> Path {
        guard let outline else { return Path() }
        let box = outline.boundingBoxOfPath
        guard box.height > 0 else { return Path() }
        let scale = rect.height / box.height
        // The font's y runs up, the view's down.
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: scale, y: -scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(outline.copy(using: [transform]) ?? outline)
    }
}

/// The small buttons beside a row's title (its (i), its folder): a glyph in a soft capsule, all the same size, that darkens while the
/// pointer is on it or what it opens is open.
private struct RowPill: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 18)
            .background(.primary.opacity(active ? 0.1 : 0.05), in: Capsule())
            .contentShape(Capsule())
    }
}

extension View {
    func rowPill(active: Bool) -> some View { modifier(RowPill(active: active)) }
}

/// What the balloon holds: the description, paragraph by paragraph, then numbered steps, then the note.
private struct InfoBalloon: View {
    let paragraphs: [String]
    let steps: [String]
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A description, never a report: no more than `InfoText.maximumLines` lines, whatever a module sends (`InfoText`).
            if !paragraphs.isEmpty {
                Text(paragraphs.joined(separator: "\n"))
                    .lineLimit(InfoText.maximumLines)
                    .truncationMode(.tail)
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 12, alignment: .trailing)
                            Text(step)
                        }
                    }
                }
            }
            if let note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(width: 290, alignment: .leading)
        .padding(14)
    }
}

/// A title with its (i) right after it, as section headers and rows show them.
struct InfoTitle: View {
    let title: String
    let info: String?
    var steps: [String] = []

    var body: some View {
        HStack(spacing: 5) {
            ChangingText(text: title)
            InfoButton(text: info, steps: steps)
        }
    }
}
