import Foundation
import SwiftMusic

internal struct PreparedSampleVoice {
    let sample: LoadedSample
    let rootPitch: Pitch

    func increment(event: CompiledSoundEvent, source: CompiledSource, time: Double,
                   secondsPerBeat: Double, automationSecondsPerBeat: Double? = nil) throws -> Double {
        let rootFrequency = 440 * pow(2, (Double(rootPitch.midiNote) - 69) / 12)
        var midi = Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones
        if let automation = source.pitchAutomation {
            let start = Double(event.start.numerator) / Double(event.start.denominator) * secondsPerBeat
            let frame = Int((start * sample.sampleRate).rounded(.down)) + Int((time * sample.sampleRate).rounded())
            midi += try AutomationEvaluator.mapped(automation.signal,
                from: automation.from.value, to: automation.to.value,
                frame: frame, secondsPerBeat: automationSecondsPerBeat ?? secondsPerBeat)
        }
        if let modulation = source.pitchEnvelope {
            let contour = VoiceEnvelope(modulation.envelope,
                noteDuration: Double(event.duration.numerator) / Double(event.duration.denominator) * secondsPerBeat,
                gate: event.gate)
            midi += modulation.depth.value * contour.value(at: time)
        }
        let target = (source.tuning?.frequencyHz ?? 440)
            * pow(2, (midi - Double(source.tuning?.referencePitch.midiNote ?? 69)) / 12)
        let increment = source.samplePlaybackRate * target / rootFrequency
        guard increment.isFinite, increment > 0 else {
            throw LoopRenderingError.invalidSound("sample traversal increment must be finite and positive")
        }
        return increment
    }

    func frames(event: CompiledSoundEvent, source: CompiledSource, secondsPerBeat: Double,
                limit: Int, automationSecondsPerBeat: Double? = nil) throws -> Int {
        let noteDuration = Double(event.duration.numerator) / Double(event.duration.denominator) * secondsPerBeat
        let horizon = VoiceEnvelope.amplitude(event: event, source: source, secondsPerBeat: secondsPerBeat)?.duration
            ?? noteDuration * event.gate
        guard horizon > 0, limit > 0 else { throw LoopRenderingError.invalidSound("invalid sample horizon") }
        let firstIncrement = try increment(event: event, source: source, time: 0,
            secondsPerBeat: secondsPerBeat, automationSecondsPerBeat: automationSecondsPerBeat)
        if source.pitchEnvelope == nil && source.pitchAutomation == nil {
            let count = min((Double(sample.frameCount) / firstIncrement).rounded(.up),
                            (horizon * sample.sampleRate).rounded(.up))
            guard count.isFinite, count > 0, count <= Double(limit) else {
                throw LoopRenderingError.invalidSound("sample voice exceeds render horizon")
            }
            return Int(count)
        }
        var position = 0.0
        var count = 0
        while position < Double(sample.frameCount), Double(count) / sample.sampleRate < horizon {
            guard count < limit else { throw LoopRenderingError.invalidSound("sample voice exceeds render horizon") }
            position += try increment(event: event, source: source,
                                      time: Double(count) / sample.sampleRate, secondsPerBeat: secondsPerBeat,
                                      automationSecondsPerBeat: automationSecondsPerBeat)
            count += 1
        }
        return count
    }

    func value(at progress: Double, reversed: Bool, channel: Int) -> Double {
        let position = reversed ? max(0, Double(sample.frameCount - 1) - progress)
            : min(progress, Double(sample.frameCount - 1))
        let first = Int(position.rounded(.down))
        let second = min(first + 1, sample.frameCount - 1)
        let fraction = position - Double(first)
        let channel = min(channel, sample.channelCount - 1)
        let a = Double(sample.samples[first * sample.channelCount + channel])
        let b = Double(sample.samples[second * sample.channelCount + channel])
        return a + (b - a) * fraction
    }
}
