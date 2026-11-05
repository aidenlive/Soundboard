import SwiftUI

/// The Split brandmark: master (white) and cue (lime), two offset halves of one circle.
/// Geometry per docs/brand.md: r = 34 in a 100-unit box, offset ±6, gap 4.
public struct SplitMark: View {
    var master: Color?
    var cue: Color?
    @Environment(\.obsidian) private var t

    public init(master: Color? = nil, cue: Color? = nil) {
        self.master = master
        self.cue = cue
    }

    public var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func half(cx: CGFloat, cy: CGFloat, left: Bool) -> Path {
                var p = Path()
                let c = CGPoint(x: ox + cx * s, y: oy + cy * s)
                p.move(to: CGPoint(x: c.x, y: c.y - 34 * s))
                p.addArc(center: c, radius: 34 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: left)
                p.closeSubpath()
                return p
            }
            ctx.fill(half(cx: 48, cy: 44, left: true), with: .color(master ?? t.text))
            ctx.fill(half(cx: 52, cy: 56, left: false), with: .color(cue ?? t.primary))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Soundboard")
    }
}

/// Pulse, the supporting brand element: "sound is happening". Never a button, never the logo.
/// Breathes in sequence (1.1 s cycle, 90 ms stagger); still when Reduce Motion is on.
public struct Pulse: View {
    var bars: Int
    var color: Color?
    var accent: Color?
    var animated: Bool
    @Environment(\.obsidian) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(bars: Int = 9, color: Color? = nil, accent: Color? = nil, animated: Bool = true) {
        self.bars = bars
        self.color = color
        self.accent = accent
        self.animated = animated
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated || reduceMotion)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let s = min(size.width, size.height) / 100
                let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
                let n = bars
                let w: CGFloat = n <= 5 ? 12 : 6.4, gap: CGFloat = n <= 5 ? 6 : 2.8
                let total = CGFloat(n) * w + CGFloat(n - 1) * gap
                let x0 = 50 - total / 2
                for i in 0..<n {
                    let tt = CGFloat(i) / CGFloat(max(1, n - 1))
                    var cy = 50 - 15 * sin(tt * 2 * .pi)
                    var h = 22 + 10 * sin(tt * .pi)
                    let mid = i == n / 2
                    if mid { h = 64; cy = 50 }
                    if animated && !reduceMotion {
                        let phase = (time - Double(i) * 0.09) / 1.1 * 2 * .pi
                        h *= 0.42 + 0.58 * CGFloat(0.5 - 0.5 * cos(phase))
                    }
                    let rect = CGRect(x: ox + (x0 + CGFloat(i) * (w + gap)) * s, y: oy + (cy - h / 2) * s, width: w * s, height: h * s)
                    g.fill(Path(roundedRect: rect, cornerRadius: w * s / 2),
                           with: .color(mid ? (accent ?? t.primary) : (color ?? t.textMuted)))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
