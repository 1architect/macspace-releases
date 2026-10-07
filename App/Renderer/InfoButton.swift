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

    private var paragraphs: [String] {
        (text ?? "").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var hasContent: Bool { !paragraphs.isEmpty || !steps.isEmpty || !(note ?? "").isEmpty }

    var body: some View {
        if hasContent {
            Button { shown.toggle() } label: {
                Image(systemName: shown ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(hovering || shown ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("More about this")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                InfoBalloon(paragraphs: paragraphs, steps: steps, note: note)
            }
        }
    }
}

/// What the balloon holds: the description, paragraph by paragraph, then numbered steps, then the note.
private struct InfoBalloon: View {
    let paragraphs: [String]
    let steps: [String]
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
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
            Text(title)
            InfoButton(text: info, steps: steps)
        }
    }
}
