import AVFoundation
import Foundation
import Synchronization

/// Owns the fixed-size post-effects monitor buffer shared with the audio callback.
final class OutputMeterStore: Sendable {
    static let frameCapacity = 2_048
    static let sampleCapacity = frameCapacity * 2

    private struct State: Sendable {
        var samples = [Float](repeating: 0, count: OutputMeterStore.sampleCapacity)
        var sampleRate = PreparedLoop.requiredSampleRate
        var frameCount = 0
        var active = false
        var callbackLoad: Double?
        var dropoutCount: UInt64 = 0
        var peak: Float?
        var clipped = false
        var nextSampleTime: AVAudioFramePosition?
    }

    private let state = Mutex(State())

    func clear() {
        state.withLock { state in
            state.active = false
            state.nextSampleTime = nil
            for index in state.samples.indices {
                state.samples[index] = 0
            }
            state.frameCount = 0
            state.sampleRate = PreparedLoop.requiredSampleRate
        }
    }

    func activate() {
        state.withLock { state in
            state.active = true
            state.nextSampleTime = nil
            for index in state.samples.indices {
                state.samples[index] = 0
            }
            state.frameCount = 0
            state.sampleRate = PreparedLoop.requiredSampleRate
        }
    }

    func capture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime? = nil) {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else {
            clearSamplesPreservingActivity()
            return
        }
        let availableFrames = Int(buffer.frameLength)
        let frameCount = min(availableFrames, Self.frameCapacity)
        let channels = Int(buffer.format.channelCount)
        let sourceOffset = max(0, availableFrames - Self.frameCapacity)
        let requiredFrames = sourceOffset + frameCount
        guard frameCount > 0, (1...2).contains(channels),
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else {
            clearSamplesPreservingActivity()
            return
        }

        // AVAudioPCMBuffer exposes a read-only list pointer for inspection; the mutable view
        // is scoped to this callback and only reads the owned buffer descriptors and samples.
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        if buffer.format.isInterleaved {
            guard audioBuffers.count == 1,
                  let data = audioBuffers[0].mData,
                  Int(audioBuffers[0].mDataByteSize) >= requiredFrames * channels * MemoryLayout<Float>.stride else {
                clearSamplesPreservingActivity()
                return
            }
            _ = data
        } else {
            guard audioBuffers.count >= channels,
                  audioBuffers.prefix(channels).allSatisfy({
                      $0.mData != nil && Int($0.mDataByteSize) >= requiredFrames * MemoryLayout<Float>.stride
                  }) else {
                clearSamplesPreservingActivity()
                return
            }
        }

        var peak: Float? = 0
        for frame in 0..<availableFrames {
            let left: Float
            let right: Float
            if buffer.format.isInterleaved {
                let values = audioBuffers[0].mData!.assumingMemoryBound(to: Float.self)
                left = values[frame * channels]; right = values[frame * channels + min(1, channels - 1)]
            } else {
                left = buffer.floatChannelData![0][frame]; right = buffer.floatChannelData![min(1, channels - 1)][frame]
            }
            guard left.isFinite, right.isFinite else { peak = nil; break }
            peak = max(peak ?? 0, abs(left), abs(right))
        }
        let sampleTime = time.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil }

        state.withLock { state in
            guard state.active else { return }
            state.peak = peak
            state.clipped = state.clipped || (peak.map { $0 >= 1 } ?? false)
            if let sampleTime {
                if let expected = state.nextSampleTime, expected != sampleTime, state.dropoutCount < .max {
                    state.dropoutCount += 1
                }
                let (next, overflow) = sampleTime.addingReportingOverflow(AVAudioFramePosition(availableFrames))
                state.nextSampleTime = overflow ? nil : next
            } else { state.nextSampleTime = nil }
            let retainedFrames = min(state.frameCount, Self.frameCapacity - frameCount)
            if retainedFrames > 0 {
                let retainedStart = state.frameCount - retainedFrames
                for index in 0..<(retainedFrames * 2) {
                    state.samples[index] = state.samples[retainedStart * 2 + index]
                }
            }
            state.sampleRate = buffer.format.sampleRate

            if buffer.format.isInterleaved {
                let data = audioBuffers[0].mData!
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    let sourceFrame = frame + sourceOffset
                    let destinationFrame = retainedFrames + frame
                    state.samples[destinationFrame * 2] = samples[sourceFrame * channels]
                    state.samples[destinationFrame * 2 + 1] = samples[sourceFrame * channels + min(1, channels - 1)]
                }
            } else {
                let channelData = buffer.floatChannelData!
                let left = channelData[0]
                let right = channelData[min(1, channels - 1)]
                for frame in 0..<frameCount {
                    let sourceFrame = frame + sourceOffset
                    let destinationFrame = retainedFrames + frame
                    state.samples[destinationFrame * 2] = left[sourceFrame]
                    state.samples[destinationFrame * 2 + 1] = right[sourceFrame]
                }
            }
            state.frameCount = retainedFrames + frameCount
            for index in (state.frameCount * 2)..<state.samples.count {
                state.samples[index] = 0
            }
        }
    }

    func snapshot() -> OutputMeterSnapshot {
        state.withLock { state in
            let samples = state.samples.withUnsafeBufferPointer { Array($0) }
            return OutputMeterSnapshot(interleavedSamples: samples, sampleRate: state.sampleRate,
                performance: PlaybackPerformanceSnapshot(callbackLoad: state.callbackLoad,
                    dropoutCount: state.dropoutCount, peak: state.peak, clipped: state.clipped))
        }
    }

    func recordCallback(elapsed: Double, duration: Double, failed: Bool) {
        state.withLock { state in
            guard state.active else { return }
            state.callbackLoad = elapsed.isFinite && elapsed >= 0 && duration.isFinite && duration > 0
                ? elapsed / duration : nil
            if state.callbackLoad?.isFinite == false { state.callbackLoad = nil }
            if failed || (state.callbackLoad.map { $0 > 1 } ?? false), state.dropoutCount < .max {
                state.dropoutCount += 1
            }
        }
    }

    func resetDiagnostics() {
        state.withLock { state in
            state.callbackLoad = nil
            state.dropoutCount = 0
            state.peak = nil
            state.clipped = false
            state.nextSampleTime = nil
        }
    }

    private func clearSamplesPreservingActivity() {
        state.withLock { state in
            guard state.active else { return }
            state.peak = nil
            state.nextSampleTime = nil
            for index in state.samples.indices {
                state.samples[index] = 0
            }
            state.frameCount = 0
            state.sampleRate = PreparedLoop.requiredSampleRate
        }
    }
}
