import SwiftUI

/// Bipolar rotary knob drawn with an arc readout. Vertical drag adjusts; double-tap resets.
/// value is -1…1 (0 = centre). VoiceOver: adjustable, announces `valueText`.
public struct Knob: View {
    let label: String
    @Binding var value: Double
    var valueText: String
    var tint: Color?
    var size: CGFloat
    @Environment(\.obsidian) private var t
    @State private var dragStart: Double?

    public init(_ label: String, value: Binding<Double>, valueText: String, tint: Color? = nil, size: CGFloat = 52) {
        self.label = label
        _value = value
        self.valueText = valueText
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = min(sz.width, sz.height) / 2 - 3
                var trackPath = Path()
                trackPath.addArc(center: c, radius: r, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
                ctx.stroke(trackPath, with: .color(t.surface3), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                let a = -90 + value * 135
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .degrees(min(-90, a)), endAngle: .degrees(max(-90, a)), clockwise: false)
                if abs(value) > 0.005 {
                    ctx.stroke(arc, with: .color(tint ?? t.primary), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                let face = Path(ellipseIn: CGRect(x: c.x - r + 6, y: c.y - r + 6, width: (r - 6) * 2, height: (r - 6) * 2))
                ctx.fill(face, with: .color(t.surface2))
                let rad = a * .pi / 180
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + cos(rad) * (r - 18), y: c.y + sin(rad) * (r - 18)))
                tick.addLine(to: CGPoint(x: c.x + cos(rad) * (r - 9), y: c.y + sin(rad) * (r - 9)))
                ctx.stroke(tick, with: .color(t.text), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    value = min(1, max(-1, (dragStart ?? 0) - Double(g.translation.height) / 140))
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { value = 0 }
            Text(label.uppercased()).font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(1, value + 0.1)
            case .decrement: value = max(-1, value - 0.1)
            @unknown default: break
            }
        }
    }
}

/// Segmented picker in the Obsidian style (hairline-separated cells, mono caps).
public struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var mono: Bool
    @Environment(\.obsidian) private var t

    public init(_ options: [(T, String)], selection: Binding<T>, mono: Bool = true) {
        self.options = options
        _selection = selection
        self.mono = mono
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(mono ? title.uppercased() : title)
                        .font(mono ? t.mono(10, .medium) : t.ui(13, .medium))
                        .tracking(mono ? 0.8 : 0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(on ? t.text : t.textMuted)
                        .background(on ? t.surface2 : t.surface)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(t.border)
        .clipShape(RoundedRectangle(cornerRadius: t.radius))
        .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
    }
}

/// Horizontal fader (crossfader, volume) with a drawn track and a flat thumb.
public struct Fader: View {
    let label: String
    @Binding var value: Double   // range given by `range`
    var range: ClosedRange<Double>
    var leading: String?
    var trailing: String?
    @Environment(\.obsidian) private var t

    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double> = -1...1,
                leading: String? = nil, trailing: String? = nil) {
        self.label = label
        _value = value
        self.range = range
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let leading { Text(leading).font(t.mono(10)).foregroundStyle(t.textMuted) }
            GeometryReader { geo in
                let w = geo.size.width
                let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(t.surface3).frame(height: 4)
                    RoundedRectangle(cornerRadius: 4).fill(t.text)
                        .frame(width: 30, height: 20)
                        .offset(x: CGFloat(f) * (w - 30))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let nf = min(1, max(0, (g.location.x - 15) / max(1, w - 30)))
                    value = range.lowerBound + Double(nf) * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 44)
            if let trailing { Text(trailing).font(t.mono(10)).foregroundStyle(t.textMuted) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100)) percent")
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            switch dir {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// Segmented stereo level meter.
public struct LevelMeter: View {
    var left: Float
    var right: Float
    var segments = 28
    @Environment(\.obsidian) private var t

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }

    public var body: some View {
        VStack(spacing: 3) {
            row(left)
            row(right)
        }
        .accessibilityElement()
        .accessibilityLabel("Master level")
        .accessibilityValue("\(Int(20 * log10(max(Double(max(left, right)), 1e-4)))) dB")
    }

    private func row(_ v: Float) -> some View {
        // Map −48…0 dBFS onto the segments.
        let db = 20 * log10(max(Double(v), 1e-4))
        let lit = Int(((db + 48) / 48) * Double(segments))
        return HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i >= lit ? t.surface2 : (i > segments - 4 ? t.error : (i > segments - 8 ? t.warning : t.textSecondary)))
                    .frame(height: 5)
            }
        }
    }
}

/// Square-ish Obsidian button. `prominent` uses the accent (reserved for "go" actions).
public struct ObsidianButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.obsidian) private var t
    public init(prominent: Bool = false) { self.prominent = prominent }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(t.mono(11, .semibold))
            .tracking(0.8)
            .foregroundStyle(prominent ? t.onPrimary : t.text)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .background(prominent ? (configuration.isPressed ? Color(t.palette.primaryActive) : t.primary)
                                  : (configuration.isPressed ? t.surface2 : t.surface))
            .clipShape(RoundedRectangle(cornerRadius: t.radius))
            .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(prominent ? Color.clear : t.border, lineWidth: 1))
    }
}
