import CoreGraphics
import Foundation
import SwiftUI

/// How a chart's blocks move while its figures are read and freed (`BlocksView`).
///
/// Reading: the blocks are found top to bottom, then left to right, each over its own stretch of the reading, and open from their
/// left side at their full height. A block opens most of the way as soon as its part is found, keeps opening slowly while the next
/// part is being found, and is done a little after the next block has started: something is always growing. The reading drawn is
/// smoothed and, while it says nothing new, still creeps on a little, so the blocks never stand still. The figures drawn meanwhile
/// are the ones the chart had; the new ones come in once every block is open, as the chart's usual glide. Refresh first closes the
/// blocks onto their left sides, last first.
///
/// Freeing: when less can be freed than before, the amber block first drains onto its left side by the share that went, its place
/// kept, and only then do the other blocks take its room.
///
/// Only a chart whose figures are being read anew moves this way (last session's figures, the first ones, Refresh). A chart drawn
/// with its figures read comes in as it always did, and a reading in the background changes nothing until its figures are in.
enum ChartMotion {
    /// What the motion is set to: the defaults below, or in a development build what the Chart Motion window (Design menu) left.
    nonisolated(unsafe) static var tuning = MotionTuning.load()

    /// How much faster the whole motion runs than set: the reading drawn, the blocks' springs, the closing and the draining.
    static var speed: Double { max(tuning.speed, 0.05) }
    /// How a block opens over its stretch: most of it at once, the rest slowly (a cubic Bézier, as in CSS)...
    static var curve: (x1: Double, y1: Double, x2: Double, y2: Double) { (tuning.curveX1, tuning.curveY1, tuning.curveX2, tuning.curveY2) }
    /// ...its width following that as SwiftUI's `.spring(duration:bounce:)`, overshooting a little.
    static var growBounce: Double { tuning.growBounce }
    static var growSpring: Double { tuning.growSpring }
    /// How far into the next block's stretch a block is still opening.
    static var overlap: Double { tuning.overlap }
    /// The reading drawn runs ahead of the real one: `1 - (1 - reading)^ahead`, so the first blocks come at once and the reading
    /// feels quick; it still ends where the real one does.
    static var ahead: Double { tuning.ahead }
    /// The reading drawn follows that this closely, in seconds: its steps are smoothed out.
    static var smoothing: Double { tuning.smoothing }
    /// While the reading says nothing new, the reading drawn creeps on, by at most this much, slower and slower.
    static var creep: Double { tuning.creep }
    static var creepTime: Double { tuning.creepTime }
    /// Refresh: each block closes in this many seconds, the next one this much later.
    static var closing: Double { tuning.closing }
    static var closeStagger: Double { tuning.closeStagger }
    /// The amber block draining by the share freed.
    static var draining: Double { tuning.draining }
    /// The finish: while the blocks open, the chart keeps this share of its width empty at its right; once every block is open it
    /// springs into it, quick and bouncy, so the end of the reading is felt.
    static var finishRoom: Double { tuning.finishRoom }
    static var finishBounce: Double { tuning.finishBounce }
    static var finishSpring: Double { tuning.finishSpring }
    /// Once the load is over, the reading drawn catches up with it this quickly, in seconds, whatever its usual smoothing.
    static let ending = 0.12
    /// How long the finish takes to come to rest, at the speed set.
    static var finishTotal: Double { max(finishSpring, 0.05) * 1.6 / speed }
    /// The chart's glide to new figures (`Theme.layout` unless the Chart Motion window changes it).
    static var glide: Animation { .spring(duration: tuning.glideDuration, bounce: tuning.glideBounce) }

    /// Posted by the Chart Motion window to play the reading again on the charts on screen, its `object` the seconds the pretend
    /// reading takes. Never posted in a release.
    static let replay = Notification.Name("com.macspace.chartMotion.replay")

    /// The time Refresh's closing takes, at the speed set.
    static func closingTotal(count: Int) -> Double { (closing + 0.05 + Double(max(count - 1, 0)) * closeStagger) / speed }

    /// How much of its width a block still has, `t` seconds (at the speed set) after it started closing (Refresh).
    static func closed(after t: Double) -> CGFloat { CGFloat(1 - easeIn(t / max(closing, 0.01))) }

    /// The curve at `u`, 0...1 for both.
    static func fill(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        func x(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * curve.x1 + 3 * (1 - s) * s * s * curve.x2 + s * s * s }
        var low = 0.0, high = 1.0, s = u
        for _ in 0..<28 {
            s = (low + high) / 2
            if x(s) < u { low = s } else { high = s }
        }
        let y = 3 * (1 - s) * (1 - s) * s * curve.y1 + 3 * (1 - s) * s * s * curve.y2 + s * s * s
        return min(max(y, 0), 1)
    }

    /// SwiftUI's `.spring(duration:bounce:)` from rest, 0 to 1, `t` seconds in.
    static func spring(_ t: Double, bounce: Double, duration: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / max(duration, 0.01), z = 1 - bounce
        if z >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
    static func easeIn(_ t: Double) -> Double { pow(min(max(t, 0), 1), 3) }
    static func easeInOut(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The reading as drawn, `dt` seconds after `drawn`: running ahead of `reading` (`ahead`), smoothed, and creeping on by up to
    /// `creep` the longer (`stalled` seconds) it has said nothing new. Never back.
    static func drawnReading(_ drawn: Double, reading: Double, stalled: Double, over dt: Double) -> Double {
        let early = 1 - pow(1 - min(max(reading, 0), 1), ahead)
        let target = min(1, early + creep * (1 - exp(-max(stalled, 0) / max(creepTime, 0.05))))
        return max(drawn, drawn + (target - drawn) * (1 - exp(-max(dt, 0) / max(smoothing, 0.005))))
    }

    /// One step of a block's width following `target` as the spring.
    static func follow(_ value: inout (x: Double, v: Double), to target: Double, over dt: Double) {
        let omega = 2 * Double.pi / max(growSpring, 0.05), damping = 1 - growBounce
        let h = min(max(dt, 0), 0.05) / 4
        for _ in 0..<4 {
            value.v += (-omega * omega * (value.x - target) - 2 * damping * omega * value.v) * h
            value.x += value.v * h
        }
    }
}

/// The order a chart's blocks are found in, and the stretch of the reading each one opens over, for the rectangles they are drawn in.
struct GrowPlan {
    /// The blocks top to bottom, then left to right.
    let sequence: [Int]
    /// Each block's stretch, 0...1: from when its part is found to a little after the next one's is. By the square root of the
    /// blocks' sizes, so the largest is not most of it.
    let windows: [(start: Double, end: Double)]

    init(rects: [CGRect], weights: [Double]) {
        let sequence = Self.sequence(rects)
        self.sequence = sequence
        let shares = sequence.map { max(weights[$0], 0).squareRoot() }
        let total = max(shares.reduce(0, +), .leastNonzeroMagnitude)
        var windows = [(start: Double, end: Double)](repeating: (0, 1), count: rects.count)
        var used = 0.0
        for (position, index) in sequence.enumerated() {
            let start = used / total
            used += shares[position]
            windows[index] = (start, position == sequence.count - 1 ? 1 : min(1, used / total + ChartMotion.overlap))
        }
        self.windows = windows
    }

    static func sequence(_ rects: [CGRect]) -> [Int] {
        rects.indices.sorted { a, b in
            let ya = (rects[a].minY * 2).rounded(), yb = (rects[b].minY * 2).rounded()
            if ya != yb { return ya < yb }
            let xa = (rects[a].minX * 2).rounded(), xb = (rects[b].minX * 2).rounded()
            if xa != xb { return xa < xb }
            return a < b
        }
    }

    /// How open block `index` should be when the reading drawn is at `reading`: the curve over its stretch.
    func target(_ index: Int, at reading: Double) -> Double {
        let window = windows[index]
        return ChartMotion.easeOut(ChartMotion.fill((reading - window.start) / max(window.end - window.start, .leastNonzeroMagnitude)))
    }

    /// Where a block is drawn: `rect` is its whole rectangle, opened to `open` of its width from its left side.
    static func drawn(_ rect: CGRect, open: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: max(rect.width * open, 0), height: rect.height)
    }
}

/// What a chart's motion has come to, kept from frame to frame: the reading as drawn, each block's width and how fast it moves, and
/// how far the amber block has drained. Set only while the frames are drawn, and read only to draw them.
final class BlockMotion {
    /// The reading as drawn, 0...1, and the last frame it was worked out for.
    var reading = 0.0
    var frame: Date?
    /// The real reading last seen, and when it last moved.
    var lastReal = 0.0
    var lastMoved: Date?
    /// Each block's width and speed, by part.
    var widths: [String: (x: Double, v: Double)] = [:]
    /// Every block is open and at rest, and since when; the finish runs from then, and the growth is over once it has.
    var settled = false
    var openedAt: Date?
    /// When the load was seen to be over.
    var endedAt: Date?
    /// How much of the amber block has drained, and the drain under way: from and to how much.
    var drain = 0.0
    var swap: (start: Date, from: Double, to: Double)?

    func restartGrowth() {
        reading = 0
        frame = nil
        lastReal = 0
        lastMoved = nil
        widths = [:]
        settled = false
        openedAt = nil
        endedAt = nil
    }

    func endDrain() {
        swap = nil
        drain = 0
    }
}

/// The chart motion's settings (`ChartMotion`), with their defaults. Changed in a development build's Chart Motion window (Design
/// menu, ⌥⌘G) and kept in the defaults there; a release always draws the defaults.
struct MotionTuning: Codable, Equatable, Sendable {
    var speed = 2.5
    var ahead = 4.0
    var smoothing = 1.0
    var creep = 0.25
    var creepTime = 8.0
    var overlap = 0.5
    var curveX1 = 0.01
    var curveY1 = 0.86
    var curveX2 = 0.79
    var curveY2 = 0.37
    var growBounce = 0.30
    var growSpring = 0.42
    var glideBounce = 0.18
    var glideDuration = 0.55
    var closing = 0.25
    var closeStagger = 0.03
    var draining = 0.45
    var finishRoom = 0.06
    var finishBounce = 0.5
    var finishSpring = 0.35

    static let key = "design.chartMotion"

    /// What the Chart Motion window left in the defaults, in a development build; a release always draws the defaults.
    static func load(_ defaults: UserDefaults = .standard) -> MotionTuning {
        #if MACSPACE_DEV
        ScreenshotLaunch.isRequested ? MotionTuning() : defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MotionTuning.self, from: $0) } ?? MotionTuning()
        #else
        MotionTuning()
        #endif
    }

    init() {}

    /// Keys missing from a saved value (one saved before they existed) keep their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = MotionTuning()
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double { try container.decodeIfPresent(Double.self, forKey: key) ?? fallback }
        speed = try value(.speed, base.speed)
        ahead = try value(.ahead, base.ahead)
        smoothing = try value(.smoothing, base.smoothing)
        creep = try value(.creep, base.creep)
        creepTime = try value(.creepTime, base.creepTime)
        overlap = try value(.overlap, base.overlap)
        curveX1 = try value(.curveX1, base.curveX1)
        curveY1 = try value(.curveY1, base.curveY1)
        curveX2 = try value(.curveX2, base.curveX2)
        curveY2 = try value(.curveY2, base.curveY2)
        growBounce = try value(.growBounce, base.growBounce)
        growSpring = try value(.growSpring, base.growSpring)
        glideBounce = try value(.glideBounce, base.glideBounce)
        glideDuration = try value(.glideDuration, base.glideDuration)
        closing = try value(.closing, base.closing)
        closeStagger = try value(.closeStagger, base.closeStagger)
        draining = try value(.draining, base.draining)
        finishRoom = try value(.finishRoom, base.finishRoom)
        finishBounce = try value(.finishBounce, base.finishBounce)
        finishSpring = try value(.finishSpring, base.finishSpring)
    }
}
