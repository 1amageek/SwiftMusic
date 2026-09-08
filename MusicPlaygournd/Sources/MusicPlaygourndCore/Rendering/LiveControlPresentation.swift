import Foundation

public enum LiveControlUnit: String, Codable, Sendable {
    case amplitude, pan, semitones, hertz, beatsPerMinute, ratio, normalized
}

/// A presentation viewport; the parameter owner still validates applied values.
public struct LiveControlPresentation: Codable, Sendable, Hashable {
    public enum Scale: String, Codable, Sendable { case linear, logarithmic }
    public let unit: LiveControlUnit
    public let minimum: Double
    public let maximum: Double
    public let scale: Scale

    public init(unit: LiveControlUnit, minimum: Double, maximum: Double, scale: Scale = .linear) throws {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum,
              scale != .logarithmic || minimum > 0 else {
            throw LiveControlError.invalidCatalog("Invalid presentation range")
        }
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.scale = scale
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(unit: values.decode(LiveControlUnit.self, forKey: .unit),
                      minimum: values.decode(Double.self, forKey: .minimum),
                      maximum: values.decode(Double.self, forKey: .maximum),
                      scale: values.decode(Scale.self, forKey: .scale))
    }

    public static func suggested(for parameter: LiveControlParameter, including values: [Double] = []) throws -> Self {
        let unit: LiveControlUnit
        var range: ClosedRange<Double>
        var scale = Scale.linear
        switch parameter {
        case .gain, .trackLevel: unit = .amplitude; range = 0...2
        case .pan, .trackPan: unit = .pan; range = -1...1
        case .pitchOffsetSemitones: unit = .semitones; range = -12...12
        case .cutoffHz, .lowPassCutoff: unit = .hertz; range = 20...20_000; scale = .logarithmic
        case .playbackRate: unit = .ratio; range = (40.0 / 120)...(240.0 / 120)
        case .delayMix, .reverbMix, .trackMute: unit = .normalized; range = 0...1
        }
        for value in values {
            guard value.isFinite else { throw LiveControlError.invalidCatalog("Nonfinite presentation endpoint") }
            range = min(range.lowerBound, value)...max(range.upperBound, value)
        }
        return try Self(unit: unit, minimum: range.lowerBound, maximum: range.upperBound, scale: scale)
    }

    public func value(at fraction: Double) throws -> Double {
        guard fraction.isFinite, (0...1).contains(fraction) else {
            throw LiveControlError.invalidCatalog("Control position must lie within 0...1")
        }
        let result = scale == .linear ? minimum + fraction * (maximum - minimum)
            : exp(log(minimum) + fraction * (log(maximum) - log(minimum)))
        guard result.isFinite else { throw LiveControlError.invalidCatalog("Control mapping overflow") }
        return result
    }
}
