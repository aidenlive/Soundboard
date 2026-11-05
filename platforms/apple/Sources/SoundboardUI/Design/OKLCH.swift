import Foundation

/// A colour in OKLCH: perceptual lightness (0–1), chroma and hue in degrees.
/// The only colour representation used in tokens; converted to Display P3 for drawing.
public struct OKLCH: Hashable, Sendable, Codable {
    public var l: Double
    public var c: Double
    public var h: Double
    public var alpha: Double

    public init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    public func opacity(_ a: Double) -> OKLCH { OKLCH(l, c, h, alpha: a) }

    /// Linear sRGB via OKLab (Björn Ottosson's reference matrices).
    public var linearSRGB: (r: Double, g: Double, b: Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr), b = c * sin(hr)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }

    /// Gamma-encoded Display P3 components (0–1), gamut-clipped. P3 holds the saturated
    /// accents (Volt lime) that sRGB would clip.
    public var displayP3: (r: Double, g: Double, b: Double) {
        let s = linearSRGB
        let r = 0.8224621 * s.r + 0.1775380 * s.g + 0.0000000 * s.b
        let g = 0.0331941 * s.r + 0.9668058 * s.g + 0.0000000 * s.b
        let b = 0.0170827 * s.r + 0.0723974 * s.g + 0.9105199 * s.b
        return (Self.encode(r), Self.encode(g), Self.encode(b))
    }

    /// Gamma-encoded sRGB components (0–1), gamut-clipped.
    public var sRGB: (r: Double, g: Double, b: Double) {
        let s = linearSRGB
        return (Self.encode(s.r), Self.encode(s.g), Self.encode(s.b))
    }

    static func encode(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// WCAG relative luminance (from sRGB), for contrast checks in tests and guardrails.
    public var relativeLuminance: Double {
        let s = linearSRGB
        return 0.2126 * min(1, max(0, s.r)) + 0.7152 * min(1, max(0, s.g)) + 0.0722 * min(1, max(0, s.b))
    }

    public static func contrast(_ a: OKLCH, _ b: OKLCH) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
