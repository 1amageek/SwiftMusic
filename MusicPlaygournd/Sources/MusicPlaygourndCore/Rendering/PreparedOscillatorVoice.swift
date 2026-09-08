import Foundation
import SwiftMusic

/// Per-voice state is copied only at scheduler template and boundary snapshots.
internal struct PreparedOscillatorVoice: Equatable {
    var phases: [Double]
    var modulatorPhases: [Double]
    var noiseHistory: [Double]
    var noiseCursor = 0
    var brown = 0.0
    private static let brownPole = exp(-2 * Double.pi * 20 / PreparedLoop.requiredSampleRate)
    var tableLevel = 0
    var previousTableLevel = 0
    var tableFade = 0

    init(_ preparation: OscillatorPreparation) {
        phases = [Double](repeating: 0, count: preparation.cents.count)
        if case .frequencyModulation = preparation.waveform { modulatorPhases = phases }
        else { modulatorPhases = [] }
        noiseHistory = [Double](repeating: 0, count: preparation.pinkKernel.count)
    }

    mutating func next(_ preparation: OscillatorPreparation, frequency: Double,
                       sourceID: Int, eventIndex: Int, offset: Int) throws -> Double {
        if case .coloredNoise(let noise) = preparation.waveform {
            let white = Self.noise(seed: noise.seed, sourceID: sourceID, eventIndex: eventIndex, frame: offset)
            switch noise.color {
            case .white: return white
            case .pink:
                noiseHistory[noiseCursor] = white
                var output = 0.0
                for index in preparation.pinkKernel.indices {
                    let position = (noiseCursor - index + noiseHistory.count) % noiseHistory.count
                    output += noiseHistory[position] * preparation.pinkKernel[index]
                }
                noiseCursor = (noiseCursor + 1) % noiseHistory.count
                return output
            case .brown:
                brown = Self.brownPole * brown + (1 - Self.brownPole) * white
                return brown
            }
        }
        try preparation.validate(frequency: frequency)
        let table = preparation.wavetable
        if let table {
            let highest = frequency * pow(2, preparation.cents.last! / 1200)
            let selected = table.level(frequency: highest)
            if offset == 0 {
                tableLevel = selected
                previousTableLevel = selected
            } else if selected != tableLevel {
                previousTableLevel = tableLevel
                tableLevel = selected
                tableFade = 32
            }
        }
        var output = 0.0
        for lane in phases.indices {
            let carrier = frequency * pow(2, preparation.cents[lane] / 1200)
            let increment = carrier / PreparedLoop.requiredSampleRate
            let phase = phases[lane]
            let value: Double
            switch preparation.waveform {
            case .sine: value = sin(2 * .pi * phase)
            case .square: value = phase < 0.5 ? 1 : -1
            case .saw: value = 2 * phase - 1
            case .triangle: value = 1 - 4 * abs((phase - 0.5).rounded() - (phase - 0.5))
            case .bandLimitedSaw: value = 2 * phase - 1 - Self.blep(phase, increment)
            case .pulse(let pulse):
                let falling = (phase - pulse.width + 1).truncatingRemainder(dividingBy: 1)
                value = (phase < pulse.width ? 1 : -1) + Self.blep(phase, increment) - Self.blep(falling, increment)
            case .frequencyModulation(let fm):
                value = sin(2 * .pi * phase + fm.index * sin(2 * .pi * modulatorPhases[lane]))
                modulatorPhases[lane] = (modulatorPhases[lane] + increment * fm.ratio).truncatingRemainder(dividingBy: 1)
            case .wavetable:
                guard let table else { throw LoopRenderingError.invalidSound("wavetable preparation missing") }
                let current = table.levels[tableLevel].value(phase: phase)
                if tableFade > 0 {
                    let prior = table.levels[previousTableLevel].value(phase: phase)
                    value = current + (prior - current) * Double(tableFade) / 32
                } else { value = current }
            case .noise, .coloredNoise:
                throw LoopRenderingError.invalidSound("noise reached pitched oscillator dispatch")
            }
            output += value
            phases[lane] = (phase + increment).truncatingRemainder(dividingBy: 1)
        }
        if tableFade > 0 { tableFade -= 1 }
        output /= Double(phases.count)
        guard output.isFinite else { throw LoopRenderingError.invalidSound("non-finite oscillator output") }
        return output
    }

    private static func blep(_ phase: Double, _ increment: Double) -> Double {
        if phase < increment {
            let t = phase / increment
            return t + t - t * t - 1
        }
        if phase > 1 - increment {
            let t = (phase - 1) / increment
            return t * t + t + t + 1
        }
        return 0
    }

    private static func noise(seed: UInt64, sourceID: Int, eventIndex: Int, frame: Int) -> Double {
        // Stable SplitMix64 counter identity; wrapping arithmetic is intentional.
        var value = seed &+ 0x9E3779B97F4A7C15 &* (UInt64(frame) &+ 1)
            &+ 0xD1B54A32D192ED03 &* UInt64(sourceID)
            &+ 0x94D049BB133111EB &* UInt64(eventIndex)
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992 * 2 - 1
    }
}
