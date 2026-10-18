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

    static func reservation(for field: Field, maximumText: String?) -> String? {
        guard field.numeric, let maximumText,
              let maximum = split(maximumText).first(where: { $0.id == field.id && $0.numeric }) else { return nil }
        return maximum.text.map { $0.isNumber ? "8" : String($0) }.joined()
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
                ForEach(fields) { field in
                    Text(verbatim: TextFields.reservation(for: field, maximumText: maximumText) ?? field.text.replacingOccurrences(of: " ", with: "\u{00A0}"))
                }
            }
            .multilineTextAlignment(.leading)
        } else { Text(verbatim: text) }
    }

    @ViewBuilder private var numericLabel: some View {
        if lineLimit == 1 {
            HStack(spacing: 0) {
                ForEach(fields) { field in
                    let value = field.text.replacingOccurrences(of: " ", with: "\u{00A0}")
                    Text(verbatim: TextFields.reservation(for: field, maximumText: maximumText) ?? value).hidden()
                        .overlay(alignment: TextFields.reservation(for: field, maximumText: maximumText) == nil ? alignment : .trailing) {
                            numeric(value)
                        }
                }
            }
            .multilineTextAlignment(.leading)
        } else { numeric(text) }
    }

    private var fields: [TextFields.Field] {
        let split = TextFields.split(text)
        guard split.contains(where: { TextFields.reservation(for: $0, maximumText: maximumText) != nil }) else {
            return [TextFields.Field(id: 0, text: text, numeric: false)]
        }
        return split
    }

    private func numeric(_ value: String) -> some View {
        Text(verbatim: value)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.value.delay(cascadeDelay), value: value)
    }
}
