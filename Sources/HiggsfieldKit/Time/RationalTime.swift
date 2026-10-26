import Foundation

/// A time value as FCPXML expresses it: a rational number of seconds such as
/// `1001/30000s` or `5s` (64-bit numerator, 32-bit denominator per the DTD).
public struct RationalTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let value: Int64
    public let timescale: Int64

    public static let zero = RationalTime(value: 0, timescale: 1)

    public init(value: Int64, timescale: Int64) {
        precondition(timescale != 0, "timescale must be non-zero")
        let sign: Int64 = timescale < 0 ? -1 : 1
        let g = Self.gcd(abs(value), abs(timescale))
        self.value = sign * value / max(g, 1)
        self.timescale = sign * timescale / max(g, 1)
    }

    public init(seconds: Double, preferredTimescale: Int64 = 600) {
        self.init(value: Int64((seconds * Double(preferredTimescale)).rounded()), timescale: preferredTimescale)
    }

    public var seconds: Double { Double(value) / Double(timescale) }

    /// Parses `"1001/30000s"`, `"5s"`, `"0s"`, `"2.5s"`.
    public init?(fcpxml string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        guard s.hasSuffix("s") else { return nil }
        s.removeLast()
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let n = Int64(parts[0]), let d = Int64(parts[1]), d != 0 {
            self.init(value: n, timescale: d)
        } else if parts.count == 1, let n = Int64(parts[0]) {
            self.init(value: n, timescale: 1)
        } else if parts.count == 1, let d = Double(parts[0]) {
            self.init(seconds: d, preferredTimescale: 1_000_000)
        } else {
            return nil
        }
    }

    /// FCPXML attribute form.
    public var fcpxmlString: String {
        timescale == 1 ? "\(value)s" : "\(value)/\(timescale)s"
    }

    public var description: String { fcpxmlString }

    /// Rounds down to a whole number of frames so FCP doesn't flag values as
    /// "not on an edit frame boundary".
    public func conformed(toFrameDuration frame: RationalTime, rounding: FloatingPointRoundingRule = .down) -> RationalTime {
        guard frame.value > 0 else { return self }
        let frames = (self / frame).rounded(rounding)
        return RationalTime(value: Int64(frames) * frame.value, timescale: frame.timescale)
    }

    public static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        RationalTime(value: a.value * b.timescale + b.value * a.timescale, timescale: a.timescale * b.timescale)
    }

    public static func - (a: RationalTime, b: RationalTime) -> RationalTime {
        RationalTime(value: a.value * b.timescale - b.value * a.timescale, timescale: a.timescale * b.timescale)
    }

    /// Ratio of two times (e.g. a duration divided by a frame duration).
    public static func / (a: RationalTime, b: RationalTime) -> Double {
        Double(a.value * b.timescale) / Double(a.timescale * b.value)
    }

    public static func < (a: RationalTime, b: RationalTime) -> Bool {
        a.value * b.timescale < b.value * a.timescale
    }

    public static func == (a: RationalTime, b: RationalTime) -> Bool {
        a.value * b.timescale == b.value * a.timescale
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
        hasher.combine(timescale)
    }

    /// Frame duration for a nominal frame rate, using the NTSC rationals FCP uses.
    public static func frameDuration(forFrameRate fps: Double) -> RationalTime {
        let ntsc: [(Double, RationalTime)] = [
            (23.976, RationalTime(value: 1001, timescale: 24000)),
            (29.97, RationalTime(value: 1001, timescale: 30000)),
            (59.94, RationalTime(value: 1001, timescale: 60000)),
        ]
        for (rate, duration) in ntsc where abs(fps - rate) < 0.01 { return duration }
        let whole = fps.rounded()
        if whole > 0 && abs(fps - whole) < 0.01 { return RationalTime(value: 100, timescale: Int64(whole) * 100) }
        return RationalTime(value: 1000, timescale: Int64((fps * 1000).rounded()))
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

/// Formats seconds as `MM:SS.s` for compact UI labels.
public func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    let m = Int(seconds) / 60
    let s = seconds - Double(m * 60)
    return String(format: "%d:%04.1f", m, s)
}
