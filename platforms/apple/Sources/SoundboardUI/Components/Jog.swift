import SwiftUI
import SoundboardAudio

/// The jog wheel: a record that turns with the track (33⅓ rpm, one turn = 1.8 s).
///
/// - Top (inside the edge ring), vinyl mode on: hand on the record. It follows your finger
///   forwards and backwards (scratching) and stops if you hold still; let go and the motor takes over.
/// - Edge ring, or anywhere with vinyl mode off: turning bends the pitch for a moment, to line up
///   beats by hand. The deck keeps playing.
///
/// Gestures send angle changes as revolutions (`Δθ / 2π`); the engine smooths them, so touch events
/// at 60 or 120 Hz both sound continuous. VoiceOver: adjustable, nudges a sixteenth of a turn.
public struct JogWheel: View {
    let deck: DeckState
    let vinylMode: Bool
    let touch: (Bool) -> Void
    let scratch: (Double) -> Void
    let bend: (Double) -> Void
    @Environment(\.obsidian) private var t
    @State private var lastAngle: Double?
    @State private var mode: Mode?

    enum Mode { case scratch, bend }

    public init(deck: DeckState, vinylMode: Bool, touch: @escaping (Bool) -> Void,
                scratch: @escaping (Double) -> Void, bend: @escaping (Double) -> Void) {
        self.deck = deck
        self.vinylMode = vinylMode
        self.touch = touch
        self.scratch = scratch
        self.bend = bend
    }

    /// Edge ring width as a fraction of the radius.
    private static let edge = 0.16

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            platter(size: size)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .gesture(drag(center: CGPoint(x: size / 2, y: size / 2), radius: size / 2))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(deck.loaded ? 1 : 0.4)
        .allowsHitTesting(deck.loaded)
        .accessibilityElement()
        .accessibilityLabel("Jog wheel deck \(deck.letter)")
        .accessibilityValue(deck.touched ? "holding" : (deck.playing ? "turning" : "stopped"))
        .accessibilityAdjustableAction { dir in
            let r = dir == .increment ? 1.0 / 16 : -1.0 / 16
            if vinylMode && !deck.playing { touch(true); scratch(r); touch(false) } else { bend(r) }
        }
    }

    private func platter(size: CGFloat) -> some View {
        let turns = deck.visual.position / max(1, Track.secondsPerRevolution * deck.sampleRate)
        let angle = Angle.radians(turns.truncatingRemainder(dividingBy: 1) * 2 * .pi)
        let accent = deck.deck == .a ? t.text : t.primary
        let held = deck.touched || mode == .scratch
        return ZStack {
            // Edge ring: the part that bends pitch.
            Circle().fill(t.surface2)
            Circle().strokeBorder(mode == .bend ? t.primary : t.border, lineWidth: mode == .bend ? 2 : 1)
            // The record: grooves, label and a marker that turns with the track.
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = min(sz.width, sz.height) / 2
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(t.background))
                var grooves = Path()
                var rr = r * 0.95
                while rr > r * 0.42 {
                    grooves.addEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                    rr -= max(2, r * 0.035)
                }
                ctx.stroke(grooves, with: .color(t.surface2), lineWidth: 1)
                let label = r * 0.36
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - label, y: c.y - label, width: label * 2, height: label * 2)),
                         with: .color(held ? t.primary.opacity(0.25) : t.surface3))
                var marker = Path()
                marker.move(to: CGPoint(x: c.x, y: c.y - label * 0.95))
                marker.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.93))
                ctx.stroke(marker, with: .color(accent), style: StrokeStyle(lineWidth: max(2, r * 0.025), lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(t.textMuted))
            }
            .padding(size * Self.edge / 2)
            .rotationEffect(angle)
            // Static labels on top of the turning record.
            VStack(spacing: 2) {
                Text(deck.letter).font(t.mono(max(10, size * 0.07), .semibold)).foregroundStyle(accent)
                Text(held ? "HOLD" : (vinylMode ? "VINYL" : "JOG"))
                    .font(t.mono(max(8, size * 0.035), .medium)).tracking(1)
                    .foregroundStyle(t.textMuted)
            }
            .allowsHitTesting(false)
        }
    }

    private func drag(center: CGPoint, radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                let dx = g.location.x - center.x, dy = g.location.y - center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                let a = atan2(Double(dy), Double(dx))
                if mode == nil {
                    // Decide once per touch: inside the edge ring scratches (vinyl mode), the edge bends.
                    let onEdge = distance > radius * (1 - Self.edge)
                    mode = vinylMode && !onEdge ? .scratch : .bend
                    if mode == .scratch { touch(true) }
                    lastAngle = a
                    return
                }
                // Very near the centre the angle is unstable: ignore those samples.
                guard distance > radius * 0.12, let last = lastAngle else { lastAngle = a; return }
                var delta = a - last
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                lastAngle = a
                let revolutions = delta / (2 * .pi)
                switch mode {
                case .scratch: scratch(revolutions)
                case .bend: bend(revolutions)
                case nil: break
                }
            }
            .onEnded { _ in
                if mode == .scratch { touch(false) }
                mode = nil
                lastAngle = nil
            }
    }
}

/// Pitch fader: vertical, centre detent, range from Settings › Mixing. Double-tap resets to 0 %.
/// Up is slower (as on a turntable) unless `upIsFaster`.
public struct PitchFader: View {
    let tempo: Double
    let range: Double
    var upIsFaster = false
    let set: (Double) -> Void
    @Environment(\.obsidian) private var t
    @State private var start: Double?

    public init(tempo: Double, range: Double, upIsFaster: Bool = false, set: @escaping (Double) -> Void) {
        self.tempo = tempo
        self.range = range
        self.upIsFaster = upIsFaster
        self.set = set
    }

    public var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.2f%%", (tempo - 1) * 100))
                .font(t.mono(10, .medium)).monospacedDigit()
                .foregroundStyle(abs(tempo - 1) < 0.0005 ? t.textMuted : t.text)
                .lineLimit(1).fixedSize()
            GeometryReader { geo in
                let h = geo.size.height
                let unit = max(-1, min(1, (tempo - 1) / max(0.001, range)))
                let y = h / 2 + CGFloat(upIsFaster ? -unit : unit) * (h / 2 - 10)
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(t.surface3).frame(width: 4)
                    Rectangle().fill(t.textMuted).frame(width: 14, height: 1).position(x: geo.size.width / 2, y: h / 2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(abs(tempo - 1) < 0.0005 ? t.surface2 : t.primary)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.border, lineWidth: 1))
                        .frame(width: min(geo.size.width, 34), height: 18)
                        .position(x: geo.size.width / 2, y: y)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if start == nil { start = unit }
                        let travel = Double(g.translation.height) / Double(max(1, h / 2 - 10))
                        var u = (start ?? 0) + (upIsFaster ? -travel : travel)
                        if abs(u) < 0.03 { u = 0 }   // centre detent
                        set(1 + max(-1, min(1, u)) * range)
                    }
                    .onEnded { _ in start = nil })
                .onTapGesture(count: 2) { set(1) }
            }
            Text("±\(Int(range * 100))").font(t.mono(9, .medium)).foregroundStyle(t.textMuted).fixedSize()
        }
        .frame(minWidth: 36)
        .accessibilityElement()
        .accessibilityLabel("Pitch")
        .accessibilityValue(String(format: "%+.1f percent", (tempo - 1) * 100))
        .accessibilityAdjustableAction { dir in
            let step = range / 40
            set(tempo + (dir == .increment ? step : -step))
        }
    }
}

/// Press-and-hold nudge buttons: ±3 % while held.
public struct NudgeButtons: View {
    let nudge: (Int) -> Void
    @Environment(\.obsidian) private var t
    @State private var held = 0

    public init(nudge: @escaping (Int) -> Void) { self.nudge = nudge }

    public var body: some View {
        HStack(spacing: 4) {
            button(-1, "minus", "Slow down")
            button(1, "plus", "Speed up")
        }
    }

    private func button(_ dir: Int, _ symbol: String, _ label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(held == dir ? t.onPrimary : t.text)
            .background(held == dir ? t.primary : t.surface)
            .clipShape(RoundedRectangle(cornerRadius: t.radius))
            .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if held != dir { held = dir; nudge(dir) } }
                .onEnded { _ in held = 0; nudge(0) })
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { nudge(dir); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nudge(0) } }
    }
}

public extension Track {
    /// 33⅓ rpm: one revolution of the platter is 1.8 s of audio (matches the engine).
    static let secondsPerRevolution = 1.8
}
