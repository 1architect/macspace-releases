import SwiftUI

extension EnvironmentValues {
    /// Changed values retain the page's cascade order.
    @Entry var textChangeDelay: Double = 0
}

/// Numeric fields retain their identity as their digit count changes. Decimal/group separators stay inside the field,
/// so the native transition can align the number rather than treating each digit as an independently moving view.
struct TextFields {
    struct Field: Identifiable, Equatable {
        let id: Int
        let text: String
        let numeric: Bool
    }

    static func split(_ text: String) -> [Field] {
        let characters = Array(text)
        var fields: [Field] = []
        var run = ""
        var numeric = false
        for (index, character) in characters.enumerated() {
            let separator = ".,٫٬\u{202F}\u{00A0}".contains(character)
                && index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            let isNumber = character.isNumber || separator
            if !run.isEmpty, isNumber != numeric {
                fields.append(Field(id: fields.count, text: run, numeric: numeric))
                run = ""
            }
            numeric = isNumber
            run.append(character)
        }
        if !run.isEmpty { fields.append(Field(id: fields.count, text: run, numeric: numeric)) }
        return fields
    }

    static func reservation(for field: Field, in maximum: [Field]) -> String? {
        guard field.numeric, maximum.indices.contains(field.id), maximum[field.id].numeric else { return nil }
        return maximum[field.id].text.map { $0.isNumber ? "8" : String($0) }.joined()
    }
}

/// Numeric-only changes retain the native transition. Phrase changes replace it with independently anchored word snapshots.
struct ChangingText: View {
    let text: String
    var alignment: Alignment = .leading
    var maximumText: String? = nil
    @Environment(\.font) private var inheritedFont
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textChangeDelay) private var cascadeDelay
    @State private var motion = TextMotionState()
    @State private var measuredSize: CGSize?

    private var snapshot: TextMotionSnapshot { TextMotionSnapshot(text, font: inheritedFont ?? .body, size: measuredSize) }
    // Resolve before drawing as well as in onChange: a new phrase must never enter the numeric renderer for one frame first.
    private var presentation: TextMotionState { motion.updating(to: snapshot) }

    var body: some View {
        measuredLabel.hidden()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
            .overlay(alignment: alignment) {
                if let change = presentation.change {
                    WordChangePlayback(change: change, alignment: alignment, singleLine: lineLimit == 1,
                                       reduceMotion: reduceMotion, delay: cascadeDelay) { id in
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { motion.complete(id) }
                    }
                    .id(change.id)
                    .transition(.identity)
                } else {
                    numericLabel.transition(.identity)
                }
            }
            .font(snapshot.font)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: snapshot, initial: true) { _, _ in
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { motion = presentation }
            }
            .onDisappear { motion = TextMotionState() }
    }

    @ViewBuilder private var measuredLabel: some View {
        if lineLimit == 1 {
            HStack(spacing: 0) {
                ForEach(cells) { cell in Text(verbatim: cell.reserved ?? cell.value) }
            }
            .multilineTextAlignment(.leading)
        } else { Text(verbatim: text) }
    }

    @ViewBuilder private var numericLabel: some View {
        if lineLimit == 1 {
            HStack(spacing: 0) {
                ForEach(cells) { cell in
                    Text(verbatim: cell.reserved ?? cell.value).hidden()
                        .overlay(alignment: cell.reserved == nil ? alignment : .trailing) { numeric(cell.value) }
                }
            }
            .multilineTextAlignment(.leading)
        } else { numeric(text) }
    }

    private struct Cell: Identifiable {
        let id: Int
        /// The text, with spaces that never break.
        let value: String
        /// The widest figure this field reaches, while it is a number `maximumText` reserves room for.
        let reserved: String?
    }

    /// The text and `maximumText` are split once a drawing: each field read the maximum again, three times a field.
    private var cells: [Cell] {
        guard let maximumText else { return [Cell(id: 0, value: text.replacingOccurrences(of: " ", with: "\u{00A0}"), reserved: nil)] }
        let maximum = TextFields.split(maximumText)
        let cells = TextFields.split(text).map {
            Cell(id: $0.id, value: $0.text.replacingOccurrences(of: " ", with: "\u{00A0}"), reserved: TextFields.reservation(for: $0, in: maximum))
        }
        guard cells.contains(where: { $0.reserved != nil }) else {
            return [Cell(id: 0, value: text.replacingOccurrences(of: " ", with: "\u{00A0}"), reserved: nil)]
        }
        return cells
    }

    private func numeric(_ value: String) -> some View {
        Text(verbatim: value)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.value.delay(cascadeDelay), value: value)
    }
}
