import SwiftUI

/// A frozen drawing keeps its own font while a progress label becomes an ordinary status phrase.
struct TextMotionSnapshot: Equatable {
    let text: String
    let font: Font
    var size: CGSize?

    init(_ text: String, font: Font = .body, size: CGSize? = nil) {
        self.text = text
        self.size = size
        let fields = TextFields.split(text)
        let percentage = fields.count >= 2 && fields[fields.count - 2].numeric
            && (fields.last?.text == "%" || fields.last?.text == "٪")
        self.font = percentage ? font.monospacedDigit() : font
    }

    var phrase: [String] { TextFields.split(text).filter { !$0.numeric }.map(\.text) }
}

/// Word changes own two static snapshots. They never keep a native, unfinished numeric transition alive underneath them.
struct TextMotionState {
    private(set) var current: TextMotionSnapshot?
    private(set) var change: WordChange?
    private var generation: UInt64 = 0

    func updating(to next: TextMotionSnapshot) -> Self {
        var result = self
        result.current = next
        guard let current else { return result }
        if current.text == next.text {
            if let change { result.change = WordChange(id: change.id, outgoing: change.outgoing, incoming: next) }
            return result
        }
        if current.phrase != next.phrase {
            result.generation += 1
            result.change = WordChange(id: result.generation, outgoing: current, incoming: next)
        } else if let change {
            // New numbers during a word entrance update the incoming snapshot without replaying its cascade.
            result.change = WordChange(id: change.id, outgoing: change.outgoing, incoming: next)
        }
        return result
    }

    mutating func complete(_ id: UInt64) {
        guard change?.id == id else { return }
        change = nil
    }
}

struct WordChange: Identifiable {
    let id: UInt64
    let outgoing: TextMotionSnapshot
    let incoming: TextMotionSnapshot

    struct Piece: Equatable {
        let text: String
        let ordinal: Int
        let whitespace: Bool
    }

    static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var run = ""
        var whitespace = false
        var ordinal = 0
        func flush() {
            guard !run.isEmpty else { return }
            pieces.append(Piece(text: run, ordinal: ordinal, whitespace: whitespace))
            if !whitespace { ordinal += 1 }
            run = ""
        }
        for character in text {
            if !run.isEmpty, character.isWhitespace != whitespace { flush() }
            whitespace = character.isWhitespace
            run.append(character)
        }
        flush()
        return pieces
    }

    /// The words that stay where they are, drawn still while the others roll: the start both phrases share when the text is drawn
    /// from the leading edge, the end they share when drawn from the trailing edge, nothing when centered. A word shared further
    /// in moves sideways as the words before it change width: matched as unchanged, it jumped to its new place while the rest rolled
    /// ("MB" in a chart legend as the pointer went from block to block).
    func unchanged(alignment: HorizontalAlignment = .leading) -> (outgoing: Set<Int>, incoming: Set<Int>) {
        let old = Self.pieces(outgoing.text), new = Self.pieces(incoming.text)
        var shared = 0
        let fromEnd = alignment == .trailing
        guard fromEnd || alignment == .leading else { return ([], []) }
        while shared < min(old.count, new.count) {
            let a = old[fromEnd ? old.count - 1 - shared : shared], b = new[fromEnd ? new.count - 1 - shared : shared]
            guard a.text == b.text else { break }
            shared += 1
        }
        func words(_ pieces: [Piece]) -> Set<Int> {
            let kept = fromEnd ? pieces.suffix(shared) : pieces.prefix(shared)
            return Set(kept.filter { !$0.whitespace }.map(\.ordinal))
        }
        return (words(old), words(new))
    }

    var wordCount: Int {
        max(Self.pieces(outgoing.text).filter { !$0.whitespace }.count, Self.pieces(incoming.text).filter { !$0.whitespace }.count)
    }
}

struct WordMotionSample {
    var y: Double
    var blur: Double
    var opacity: Double

    /// Original word roll/blur timings, sampled explicitly so interrupted and intermediate frames are testable.
    static func at(_ elapsed: Double, ordinal: Int, outgoing: Bool, reduceMotion: Bool, delay: Double) -> Self {
        if reduceMotion {
            let amount = UnitCurve.easeInOut.value(at: min(1, max(0, elapsed / 0.2)))
            return Self(y: 0, blur: 0, opacity: outgoing ? 1 - amount : amount)
        }
        let time = max(0, elapsed - delay - Double(ordinal) * 0.025)
        if outgoing {
            let amount = UnitCurve.easeIn.value(at: min(1, time / 0.22))
            return Self(y: -0.9 * amount, blur: 3 * amount, opacity: 1 - amount)
        }
        let amount = time >= 0.45 ? 1 : Spring(duration: 0.45, bounce: 0.22).value(target: 1.0, time: time)
        let visible = min(1, max(0, amount))
        return Self(y: 0.9 * (1 - amount), blur: 3 * (1 - visible), opacity: visible)
    }
}

private struct WordMotionAttribute: TextAttribute {
    let ordinal: Int
    let changed: Bool
    var whitespace = false
}

/// Text remains one shaped paragraph. Attributes identify changed words without creating independently measured HStack cells.
private struct WordMotionRenderer: TextRenderer {
    var elapsed: Double
    let outgoing: Bool
    let reduceMotion: Bool
    let delay: Double

    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var displayPadding: EdgeInsets { EdgeInsets(top: 32, leading: 0, bottom: 32, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let right = layout.map { $0.typographicBounds.rect.maxX }.max() ?? 0
        // Vertical roll/blur may draw outside the line; no glyph or blur can escape its own measured trailing edge.
        context.clip(to: Path(CGRect(x: -10_000, y: -10_000, width: 10_000 + right, height: 20_000)))
        for line in layout {
            // Use the native line drawing at a fully static endpoint, including its ellipsis/hinting. While words move,
            // individual runs retain their fixed horizontal positions and their own vertical/blur samples.
            let staticLine = line.allSatisfy { run in
                let word = run[WordMotionAttribute.self] ?? WordMotionAttribute(ordinal: 0, changed: true)
                if word.whitespace { return true }
                if !word.changed { return !outgoing }
                let sample = WordMotionSample.at(elapsed, ordinal: word.ordinal, outgoing: outgoing, reduceMotion: reduceMotion, delay: delay)
                return sample.opacity == 1 && sample.y == 0 && sample.blur == 0
            }
            if staticLine { context.draw(line); continue }
            for run in line {
                let word = run[WordMotionAttribute.self] ?? WordMotionAttribute(ordinal: 0, changed: true)
                if !word.changed {
                    if !outgoing { context.draw(run) }
                    continue
                }
                let sample = WordMotionSample.at(elapsed, ordinal: word.ordinal, outgoing: outgoing, reduceMotion: reduceMotion, delay: delay)
                guard sample.opacity > 0 else { continue }
                var drawing = context
                drawing.translateBy(x: 0, y: sample.y * run.typographicBounds.rect.height)
                drawing.opacity *= sample.opacity
                if sample.blur > 0 { drawing.addFilter(.blur(radius: sample.blur)) }
                drawing.draw(run)
            }
        }
    }
}

/// A pure frame used by playback and by offscreen tests at arbitrary intermediate times.
struct WordChangeFrame: View {
    let change: WordChange
    let elapsed: Double
    var alignment: Alignment = .leading
    var singleLine = true
    var reduceMotion = false
    var delay: Double = 0

    var body: some View {
        let matched = change.unchanged(alignment: alignment.horizontal)
        ZStack(alignment: alignment) {
            layer(change.outgoing, unchanged: matched.outgoing, outgoing: true)
            layer(change.incoming, unchanged: matched.incoming, outgoing: false)
        }
        .accessibilityHidden(true)
    }

    private func layer(_ snapshot: TextMotionSnapshot, unchanged: Set<Int>, outgoing: Bool) -> some View {
        let paragraph = WordChange.pieces(snapshot.text).reduce(Text(verbatim: "")) { text, piece in
            let word = Text(verbatim: piece.text).customAttribute(WordMotionAttribute(ordinal: piece.ordinal, changed: !piece.whitespace && !unchanged.contains(piece.ordinal), whitespace: piece.whitespace))
            var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 2)
            interpolation.appendInterpolation(text)
            interpolation.appendInterpolation(word)
            return Text(LocalizedStringKey(stringInterpolation: interpolation))
        }
        return paragraph
            .font(snapshot.font)
            .textRenderer(WordMotionRenderer(elapsed: elapsed, outgoing: outgoing, reduceMotion: reduceMotion, delay: delay))
            .frame(width: snapshot.size?.width, height: snapshot.size?.height, alignment: alignment)
            .fixedSize(horizontal: singleLine, vertical: true)
    }
}

struct WordChangePlayback: View {
    let change: WordChange
    let alignment: Alignment
    let singleLine: Bool
    let reduceMotion: Bool
    let delay: Double
    let complete: @MainActor (UInt64) -> Void
    @State private var elapsed: Double = 0

    private var duration: Double { reduceMotion ? 0.2 : delay + 0.45 + Double(max(0, change.wordCount - 1)) * 0.025 }

    var body: some View {
        WordChangeFrame(change: change, elapsed: elapsed, alignment: alignment, singleLine: singleLine, reduceMotion: reduceMotion, delay: delay)
            .animation(.linear(duration: duration), value: elapsed)
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) { elapsed = duration }
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                guard !Task.isCancelled else { return }
                complete(change.id)
            }
    }
}
