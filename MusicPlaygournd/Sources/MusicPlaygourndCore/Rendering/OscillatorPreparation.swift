import Foundation
import SwiftMusic

/// Immutable source preparation; the retained render session owns all tables and kernels.
internal struct OscillatorPreparation: Sendable {
    let waveform: Waveform
    let cents: [Double]
    let wavetable: WavetablePreparation?
    let pinkKernel: [Double]

    static func prepare(_ sound: CompiledSound) throws -> [Int: Self] {
        var result: [Int: Self] = [:]
        var tableSamples = 0
        for source in sound.sources {
            guard case .synthesizer(let waveform) = source.kind else {
                guard source.unison == nil else {
                    throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "unison requires pitched synthesis")
                }
                continue
            }
            let advanced: Bool
            switch waveform {
            case .sine, .square, .saw, .triangle, .noise: advanced = false
            default: advanced = true
            }
            if case .noise = waveform, source.unison != nil {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "noise has no unison pitch")
            }
            if !advanced && (source.unison?.voices ?? 1) == 1 { continue }
            if case .wavetable(let table) = waveform {
                let levels = table.samples.count.trailingZeroBitCount
                let required = table.samples.count * levels
                guard required <= 262_144 - tableSamples else {
                    throw LoopRenderingError.invalidSound("wavetable source storage exceeds limit")
                }
                tableSamples += required
            }
            result[source.id] = try Self(source: source, waveform: waveform)
        }
        var lanes = 0
        for event in sound.events {
            lanes += result[event.sourceID]?.cents.count ?? 0
            guard lanes <= 4096 else { throw LoopRenderingError.invalidSound("oscillator lane budget exceeded") }
        }
        return result
    }

    init(source: CompiledSource, waveform: Waveform) throws {
        self.waveform = waveform
        switch waveform {
        case .noise, .coloredNoise:
            guard source.unison == nil, source.portamento == nil, source.tuning == nil,
                  source.pitchEnvelope == nil, source.pitchAutomation == nil else {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "noise has no pitched oscillator")
            }
        default: break
        }
        let count = source.unison?.voices ?? 1
        let detune = source.unison?.detuneCents ?? 0
        cents = count == 1 ? [0] : (0..<count).map { -detune + 2 * detune * Double($0) / Double(count - 1) }
        if case .wavetable(let table) = waveform { wavetable = try WavetablePreparation(table) }
        else { wavetable = nil }
        if case .coloredNoise(let noise) = waveform, noise.color == .pink {
            var coefficients = [Double](repeating: 1, count: 256)
            for index in 1..<coefficients.count {
                coefficients[index] = coefficients[index - 1] * (Double(index) - 0.5) / Double(index)
            }
            let sum = coefficients.reduce(0, +)
            pinkKernel = coefficients.map { $0 / sum }
        } else { pinkKernel = [] }
    }

    func validate(frequency: Double) throws {
        for cents in cents {
            let carrier = frequency * pow(2, cents / 1200)
            var maximum = carrier
            if case .frequencyModulation(let fm) = waveform {
                maximum = max(carrier * fm.ratio, carrier * (1 + fm.ratio * fm.index))
            }
            guard carrier.isFinite, carrier > 0, maximum.isFinite,
                  maximum < PreparedLoop.requiredSampleRate / 2 else {
                throw LoopRenderingError.invalidSound("oscillator frequency exceeds native Nyquist")
            }
        }
    }
}
