import SwiftUI

/// Text whose changes roll in like an odometer: each digit that changes rolls up out of view and the new one rolls in from below, a
/// little after the one to its left, with a short blur; words that change cross over the same way, as one piece, so they keep their
/// kerning. Used for what All done counts up; SwiftUI's numeric transition moved the whole line at once and blurred it.
struct RollingText: View {
    let text: String
    /// Its own font, or the one around it.
    var font: Font? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.font) private var inherited

    /// Runs of the text: each digit on its own, everything between digits as one piece.
    struct Piece: Identifiable, Equatable {
        let id: String
        let text: String
        let isDigit: Bool
    }

    static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            pieces.append(Piece(id: "\(pieces.count):\(run)", text: run, isDigit: false))
            run = ""
        }
        for character in text {
            if character.isNumber {
                flush()
                pieces.append(Piece(id: "\(pieces.count):\(character)", text: String(character), isDigit: true))
            } else {
                run.append(character)
            }
        }
        flush()
        return pieces
    }

    var body: some View {
        let pieces = Self.pieces(text)
        HStack(spacing: 0) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                let value = piece.text.replacingOccurrences(of: " ", with: "\u{00A0}")
                Text(value).hidden()
                    .overlay(alignment: .leading) {
                        Text(value).id(value)
                            .transition(reduceMotion ? .opacity : Self.roll(delay: Double(index) * 0.025))
                            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.22), value: value)
                    }
                    .font(font ?? inherited)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// The old piece rolls up and away, the new one rolls in from below, each with a little blur.
    private static func roll(delay: Double) -> AnyTransition {
        .asymmetric(insertion: .modifier(active: Roll(offset: 0.9, blur: 3, opacity: 0), identity: Roll(offset: 0, blur: 0, opacity: 1))
                        .animation(.spring(duration: 0.45, bounce: 0.22).delay(delay)),
                    removal: .modifier(active: Roll(offset: -0.9, blur: 3, opacity: 0), identity: Roll(offset: 0, blur: 0, opacity: 1))
                        .animation(.easeIn(duration: 0.22).delay(delay)))
    }

    private struct Roll: ViewModifier {
        /// In line heights.
        let offset: CGFloat
        let blur: CGFloat
        let opacity: Double

        func body(content: Content) -> some View {
            content
                .visualEffect { effect, proxy in effect.offset(y: offset * proxy.size.height) }
                .blur(radius: blur)
                .opacity(opacity)
        }
    }
}

/// Keep the existing numeric-text roll: changing glyphs roll and blur while unchanged text stays put. The resting text alone
/// determines layout; the overlay animates its contents without animating the line's width or moving neighbouring elements.
struct ChangingText: View {
    let text: String
    var alignment: Alignment = .leading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text).hidden()
            .overlay(alignment: alignment) {
                Text(text)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.value, value: text)
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}
