import SwiftUI

/// Three-band waveform for one track, normalised 0…1 per band.
public struct WaveformData: Equatable, Sendable {
    public var low: [Float]
    public var mid: [Float]
    public var high: [Float]
    public var framesPerBin: Int
    public var sampleRate: Double

    public init(low: [Float], mid: [Float], high: [Float], framesPerBin: Int, sampleRate: Double) {
        self.low = low
        self.mid = mid
        self.high = high
        self.framesPerBin = max(1, framesPerBin)
        self.sampleRate = sampleRate
    }

    public static let empty = WaveformData(low: [], mid: [], high: [], framesPerBin: 1, sampleRate: 44_100)
    public var count: Int { low.count }
    public var totalFrames: Double { Double(count * framesPerBin) }

    /// Max of each band over a frame range (used to downsample for overviews and rings).
    func peak(from f0: Double, to f1: Double) -> (Float, Float, Float) {
        guard count > 0 else { return (0, 0, 0) }
        let b0 = max(0, min(count - 1, Int(f0) / framesPerBin))
        let b1 = max(b0, min(count - 1, Int(f1) / framesPerBin))
        var l: Float = 0, m: Float = 0, h: Float = 0
        for i in b0...b1 {
            l = max(l, low[i])
            m = max(m, mid[i])
            h = max(h, high[i])
        }
        return (l, m, h)
    }
}

/// What a deck view needs to draw: waveform, grid, play head, cues, loop.
public struct DeckVisual: Equatable {
    public var waveform: WaveformData = .empty
    public var bpm: Double = 0
    public var firstBeatFrame: Double = 0
    public var position: Double = 0
    public var cues: [(index: Int, frame: Double)] = []
    public var loop: ClosedRange<Double>?

    public init() {}

    public static func == (a: DeckVisual, b: DeckVisual) -> Bool {
        a.waveform == b.waveform && a.bpm == b.bpm && a.firstBeatFrame == b.firstBeatFrame && a.position == b.position
            && a.cues.map(\.frame) == b.cues.map(\.frame) && a.loop == b.loop
    }

    var beatLength: Double { bpm > 0 ? 60 / bpm * waveform.sampleRate : 0 }
    var progress: Double { waveform.totalFrames > 0 ? min(1, max(0, position / waveform.totalFrames)) : 0 }
}

/// Scrolling waveform centred on the play head. Horizontal (Linear) or vertical (Lanes).
public struct ScrollingWaveform: View {
    public enum Axis { case horizontal, vertical }
    var visual: DeckVisual
    var deck: SemanticPalette.Deck
    var secondsVisible: Double
    var axis: Axis
    @Environment(\.obsidian) private var t

    public init(_ visual: DeckVisual, deck: SemanticPalette.Deck, secondsVisible: Double = 8, axis: Axis = .horizontal) {
        self.visual = visual
        self.deck = deck
        self.secondsVisible = secondsVisible
        self.axis = axis
    }

    public var body: some View {
        let bands = t.palette.wave(deck)
        let lowC = Color(bands.low), midC = Color(bands.mid), highC = Color(bands.high)
        let grid = t.surface3, head = t.text
        let cueColors = (0..<4).map { t.cue($0) }
        Canvas { ctx, size in
            let horizontal = axis == .horizontal
            let length = horizontal ? size.width : size.height
            let thickness = horizontal ? size.height : size.width
            let wf = visual.waveform
            guard wf.count > 0, length > 0 else { return }
            let visibleFrames = secondsVisible * wf.sampleRate
            let fpp = visibleFrames / Double(length)
            let centre = length / 2
            func rect(along a: CGFloat, length l: CGFloat, across c: CGFloat, thickness th: CGFloat) -> CGRect {
                horizontal ? CGRect(x: a, y: c, width: l, height: th) : CGRect(x: c, y: a, width: th, height: l)
            }
            // Beat grid (behind the bars). Every 4th beat is a bar line; every 16th a phrase line.
            if visual.beatLength > 0 {
                let startFrame = visual.position - Double(centre) * fpp
                let endFrame = visual.position + Double(centre) * fpp
                var beat = ceil((startFrame - visual.firstBeatFrame) / visual.beatLength)
                while visual.firstBeatFrame + beat * visual.beatLength <= endFrame {
                    let f = visual.firstBeatFrame + beat * visual.beatLength
                    let a = centre + CGFloat((f - visual.position) / fpp)
                    let isBar = Int(beat) % 4 == 0, isPhrase = Int(beat) % 16 == 0
                    ctx.fill(Path(rect(along: a, length: isPhrase ? 2 : 1, across: 0, thickness: thickness)),
                             with: .color(grid.opacity(isPhrase ? 1 : (isBar ? 0.8 : 0.45))))
                    beat += 1
                }
            }
            if let loop = visual.loop {
                let a0 = centre + CGFloat((loop.lowerBound - visual.position) / fpp)
                let a1 = centre + CGFloat((loop.upperBound - visual.position) / fpp)
                ctx.fill(Path(rect(along: a0, length: max(1, a1 - a0), across: 0, thickness: thickness)),
                         with: .color(t.primary.opacity(0.14)))
            }
            // Bars: 2 px wide, 1 px gap; three bands overlaid, mirrored around the centre line.
            let step: CGFloat = 3
            var a: CGFloat = 0
            while a < length {
                let f0 = visual.position + Double(a - centre) * fpp
                let f1 = f0 + Double(step) * fpp
                if f1 > 0 && f0 < wf.totalFrames {
                    let (l, m, h) = wf.peak(from: max(0, f0), to: f1)
                    let played = a + step <= centre
                    let alpha = played ? 0.32 : 1.0
                    for (v, c, scale) in [(l, lowC, 0.96), (m, midC, 0.78), (h, highC, 0.5)] {
                        let th = max(1, CGFloat(v) * thickness * CGFloat(scale))
                        ctx.fill(Path(roundedRect: rect(along: a, length: 2, across: (thickness - th) / 2, thickness: th), cornerRadius: 1),
                                 with: .color(c.opacity(alpha)))
                    }
                }
                a += step
            }
            // Cue ticks at the edge.
            for cue in visual.cues {
                let a = centre + CGFloat((cue.frame - visual.position) / fpp)
                guard a >= 0, a <= length else { continue }
                ctx.fill(Path(rect(along: a - 1, length: 3, across: 0, thickness: 8)), with: .color(cueColors[cue.index % 4]))
            }
            // Play head.
            ctx.fill(Path(rect(along: centre - 1, length: 2, across: 0, thickness: thickness)), with: .color(head))
        }
        .accessibilityHidden(true)
    }
}

/// Whole-track overview: miniature waveform, play position, cue ticks.
public struct OverviewStrip: View {
    var visual: DeckVisual
    var deck: SemanticPalette.Deck
    var onSeek: ((Double) -> Void)?
    @Environment(\.obsidian) private var t

    public init(_ visual: DeckVisual, deck: SemanticPalette.Deck, onSeek: ((Double) -> Void)? = nil) {
        self.visual = visual
        self.deck = deck
        self.onSeek = onSeek
    }

    public var body: some View {
        let bands = t.palette.wave(deck)
        let lowC = Color(bands.low), midC = Color(bands.mid), head = t.text
        let cueColors = (0..<4).map { t.cue($0) }
        Canvas { ctx, size in
            let wf = visual.waveform
            guard wf.count > 0 else { return }
            let total = wf.totalFrames
            let cols = Int(size.width)
            for x in stride(from: 0, to: cols, by: 1) {
                let f0 = Double(x) / Double(cols) * total, f1 = Double(x + 1) / Double(cols) * total
                let (l, m, _) = wf.peak(from: f0, to: f1)
                let played = f1 < visual.position
                for (v, c) in [(l, lowC), (m, midC)] {
                    let h = max(1, CGFloat(v) * size.height)
                    ctx.fill(Path(CGRect(x: CGFloat(x), y: (size.height - h) / 2, width: 1, height: h)),
                             with: .color(c.opacity(played ? 0.35 : 1)))
                }
            }
            for cue in visual.cues {
                let x = CGFloat(cue.frame / total) * size.width
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: 6)), with: .color(cueColors[cue.index % 4]))
            }
            let px = CGFloat(visual.progress) * size.width
            ctx.fill(Path(CGRect(x: px, y: 0, width: 1, height: size.height)), with: .color(head))
        }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                        guard let onSeek, visual.waveform.totalFrames > 0, geo.size.width > 0 else { return }
                        onSeek(Double(min(1, max(0, g.location.x / geo.size.width))) * visual.waveform.totalFrames)
                    })
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Track overview")
        .accessibilityValue("\(Int(visual.progress * 100)) percent played")
    }
}

/// The Radial deck view: the whole track as a ring that turns with playback. The play head
/// sits at twelve o'clock; played audio is dimmed; cue points tick the rim. Text in the centre
/// (BPM, time, phrase) is supplied by the caller so the ring never carries meaning alone.
public struct RadialDeck<Center: View>: View {
    var visual: DeckVisual
    var deck: SemanticPalette.Deck
    var segments: Int
    var center: Center
    @Environment(\.obsidian) private var t

    public init(_ visual: DeckVisual, deck: SemanticPalette.Deck, segments: Int = 150, @ViewBuilder center: () -> Center) {
        self.visual = visual
        self.deck = deck
        self.segments = segments
        self.center = center()
    }

    public var body: some View {
        let bands = t.palette.wave(deck)
        let lowC = Color(bands.low), midC = Color(bands.mid), highC = Color(bands.high)
        let head = t.text
        let cueColors = (0..<4).map { t.cue($0) }
        ZStack {
            Canvas { ctx, size in
                let wf = visual.waveform
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2
                let inner = outer * 0.70
                let maxLen = outer - inner - 4
                guard wf.count > 0 else {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)),
                               with: .color(t.surface3), lineWidth: 1)
                    return
                }
                let total = wf.totalFrames
                let progress = visual.progress
                for i in 0..<segments {
                    let frac = Double(i) / Double(segments)
                    let (l, m, h) = wf.peak(from: frac * total, to: (frac + 1 / Double(segments)) * total)
                    let ang = (frac - progress) * 2 * .pi - .pi / 2
                    let dir = CGPoint(x: cos(ang), y: sin(ang))
                    let played = frac < progress
                    let alpha = played ? 0.3 : 1.0
                    let lo = CGFloat(l) * maxLen * 0.62, mi = CGFloat(m) * maxLen * 0.38, hi = CGFloat(h) * maxLen * 0.22
                    var r0 = inner + 2
                    for (len, col) in [(lo, lowC), (mi, midC), (hi, highC)] where len > 0.5 {
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + dir.x * r0, y: c.y + dir.y * r0))
                        p.addLine(to: CGPoint(x: c.x + dir.x * (r0 + len), y: c.y + dir.y * (r0 + len)))
                        ctx.stroke(p, with: .color(col.opacity(alpha)), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                        r0 += len
                    }
                }
                for cue in visual.cues {
                    let frac = cue.frame / total
                    let ang = (frac - progress) * 2 * .pi - .pi / 2
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(ang) * (inner - 6), y: c.y + sin(ang) * (inner - 6)))
                    p.addLine(to: CGPoint(x: c.x + cos(ang) * (inner + 1), y: c.y + sin(ang) * (inner + 1)))
                    ctx.stroke(p, with: .color(cueColors[cue.index % 4]), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                var headPath = Path()
                headPath.move(to: CGPoint(x: c.x, y: c.y - outer))
                headPath.addLine(to: CGPoint(x: c.x, y: c.y - inner + 6))
                ctx.stroke(headPath, with: .color(head), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height) * 0.70 - 16
                Circle().fill(t.surface).overlay(Circle().stroke(t.border, lineWidth: 1))
                    .frame(width: d, height: d)
                    .overlay(center)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
