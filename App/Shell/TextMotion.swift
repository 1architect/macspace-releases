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

/// The original native text/number transition, shared by captions, buttons and the All done counter.
/// Parent layout animation cannot move the drawing. Progress percentages use natural width with tabular digits;
/// other labels inherit their font spacing. Explicit counting templates can reserve numeric width for All done.
struct ChangingText: View {
    let text: String
    var alignment: Alignment = .leading
    var maximumText: String? = nil
    @Environment(\.font) private var inheritedFont
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textChangeDelay) private var cascadeDelay

    var body: some View {
        Group {
            if lineLimit == 1 {
                HStack(spacing: 0) {
                    ForEach(fields) { field in
                        let value = field.text.replacingOccurrences(of: " ", with: "\u{00A0}")
                        if let reservation = TextFields.reservation(for: field, maximumText: maximumText) {
                            Text(verbatim: reservation).hidden()
                                .overlay(alignment: .trailing) { animated(value) }
                        } else {
                            Text(verbatim: value).hidden()
                                .overlay(alignment: alignment) { animated(value) }
                        }
                    }
                }
                // Each field has its own measured space. Inheriting a trailing paragraph alignment shifts the word's ink
                // into that space, visually joining it to the next number even though the string still contains a space.
                .multilineTextAlignment(.leading)
            } else {
                // Multiline descriptions retain Text's native wrapping and shaping.
                Text(verbatim: text).hidden()
                    .overlay(alignment: alignment) { animated(text) }
            }
        }
        .font(isProgressPercentage ? (inheritedFont ?? .body).monospacedDigit() : inheritedFont)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var fields: [TextFields.Field] {
        let split = TextFields.split(text)
        // Keep ordinary labels shaped as one Text, including kerning across word/number boundaries.
        guard split.contains(where: { TextFields.reservation(for: $0, maximumText: maximumText) != nil }) else {
            return [TextFields.Field(id: 0, text: text, numeric: false)]
        }
        return split
    }

    private var isProgressPercentage: Bool {
        guard maximumText == nil else { return false }
        let fields = TextFields.split(text)
        return fields.count >= 2 && fields[fields.count - 2].numeric
            && (fields.last?.text == "%" || fields.last?.text == "٪")
    }

    private func animated(_ value: String) -> some View {
        Text(verbatim: value)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.value.delay(cascadeDelay), value: value)
    }
}
