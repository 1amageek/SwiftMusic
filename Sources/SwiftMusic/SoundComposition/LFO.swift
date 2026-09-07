import Foundation

/// A normalized low-frequency oscillator.
public struct LFO: Sendable, Equatable, Hashable {
    public let waveform: LFOWaveform
    public let rate: ModulationRate
    public let phase: Double

    public init(waveform: LFOWaveform, rate: ModulationRate, phase: Double = 0) throws {
        guard phase.isFinite, (0..<1).contains(phase) else {
            throw AutomationError.invalidPhase
        }
        switch rate {
        case .hertz(let frequency):
            guard frequency.hertz.isFinite, frequency.hertz > 0 else {
                throw AutomationError.invalidRate
            }
        case .synchronized(let period):
            guard period > .zero else { throw AutomationError.invalidRate }
        }
        self.waveform = waveform
        self.rate = rate
        self.phase = phase
    }

    /// Evaluates the normalized waveform at a phase in the unit interval.
    public func value(at phase: Double) throws -> Double {
        let p = try Self.normalized(phase)
        let value: Double
        switch waveform {
        case .sine:
            value = (sin(2 * Double.pi * p) + 1) / 2
        case .triangle:
            value = p < 0.5 ? p * 2 : (1 - p) * 2
        case .sawUp:
            value = p
        case .sawDown:
            value = 1 - p
        case .square:
            value = p < 0.5 ? 0 : 1
        }
        guard value.isFinite, (0...1).contains(value) else {
            throw AutomationError.nonfiniteMappedValue
        }
        return value
    }

    internal static func normalized(_ phase: Double) throws -> Double {
        guard phase.isFinite else { throw AutomationError.invalidPhase }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }
}
