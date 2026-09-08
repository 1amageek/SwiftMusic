import AVFoundation
import Synchronization

/// Fixed planar blocks stay mutex-owned; native buffer borrows never escape.
internal final class MasterRecordingCapture: Sendable {
    static let blockFrames = 2048
    static let blockCount = 64
    struct Snapshot: Sendable {
        let frames: Int64
        let inputRate: Double
        let largestBuffer: Int
        let finished: Bool
    }
    private struct State: Sendable {
        let format: AVAudioFormat
        var buffers: [[Float]]
        var lengths = [Int](repeating: 0, count: MasterRecordingCapture.blockCount)
        let maximumFrames: Int64
        var free = Array(0..<MasterRecordingCapture.blockCount)
        var ready = [Int](repeating: 0, count: MasterRecordingCapture.blockCount)
        var head = 0
        var tail = 0
        var count = 0
        var frames: Int64 = 0
        var nextSampleTime: Int64?
        var largestBuffer = 0
        var finished = false
    }
    private let state = Mutex<State?>(nil)
    private let active = Atomic(false)
    private let failureCode = Atomic<Int>(0)

    func begin(format: AVAudioFormat, maximumFrames: Int64) throws {
        guard format.commonFormat == .pcmFormatFloat32, (1...2).contains(format.channelCount),
              format.sampleRate.isFinite, format.sampleRate > 0,
              let normalized = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                            channels: format.channelCount) else {
            throw MasterRecordingError.unsupportedFormat
        }
        let buffers = (0..<Self.blockCount).map { _ in
            [Float](repeating: 0, count: Self.blockFrames * Int(normalized.channelCount))
        }
        let prepared = State(format: format, buffers: buffers, maximumFrames: maximumFrames)
        state.withLock { $0 = prepared }
        failureCode.store(0, ordering: .releasing)
        active.store(true, ordering: .releasing)
    }

    func capture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard active.load(ordering: .acquiring), failureCode.load(ordering: .acquiring) == 0 else { return }
        let locked = state.withLockIfAvailable { value -> Bool in
            guard active.load(ordering: .acquiring), value != nil else { return true }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return true }
            guard buffer.format == value!.format, let source = buffer.floatChannelData else { fail(1); return true }
            guard time.isSampleTimeValid, time.sampleRate == buffer.format.sampleRate else { fail(2); return true }
            if let next = value!.nextSampleTime, next != time.sampleTime { fail(2); return true }
            let next = time.sampleTime.addingReportingOverflow(Int64(frames))
            let total = value!.frames.addingReportingOverflow(Int64(frames))
            guard !next.overflow, !total.overflow else { fail(2); return true }
            let outputFrames = (Double(total.partialValue) * PreparedLoop.requiredSampleRate / buffer.format.sampleRate).rounded(.up)
            guard outputFrames.isFinite, outputFrames <= Double(value!.maximumFrames) else { fail(4); return true }
            let blocks = (frames + Self.blockFrames - 1) / Self.blockFrames
            guard blocks <= value!.free.count else { fail(3); return true }
            let channels = Int(buffer.format.channelCount)
            for offset in stride(from: 0, to: frames, by: Self.blockFrames) {
                let slot = value!.free.removeLast()
                let count = min(Self.blockFrames, frames - offset)
                value!.buffers[slot].withUnsafeMutableBufferPointer { destination in
                    for channel in 0..<channels {
                        let target = destination.baseAddress! + channel * Self.blockFrames
                        if buffer.format.isInterleaved {
                            for frame in 0..<count { target[frame] = source[0][(offset + frame) * channels + channel] }
                        } else { target.update(from: source[channel] + offset, count: count) }
                    }
                }
                value!.lengths[slot] = count
                value!.ready[value!.tail] = slot
                value!.tail = (value!.tail + 1) % Self.blockCount
                value!.count += 1
            }
            value!.frames = total.partialValue
            value!.nextSampleTime = next.partialValue
            value!.largestBuffer = max(value!.largestBuffer, frames)
            return true
        }
        if locked == nil, active.load(ordering: .acquiring) { fail(3) }
    }

    private func fail(_ code: Int) {
        _ = failureCode.compareExchange(expected: 0, desired: code, ordering: .acquiringAndReleasing)
    }

    var failure: MasterRecordingError? {
        switch failureCode.load(ordering: .acquiring) {
        case 1: .unsupportedFormat
        case 2: .discontinuousTime
        case 3: .captureOverrun
        case 4: .durationExceeded
        default: nil
        }
    }

    func finish() {
        active.store(false, ordering: .releasing)
        state.withLock { $0?.finished = true }
    }

    /// One bounded copy gives the writer exclusive native-buffer ownership before file I/O.
    func read(into buffer: AVAudioPCMBuffer) -> Bool {
        state.withLock { value in
            guard value != nil, value!.count > 0 else { return false }
            let index = value!.ready[value!.head]
            let count = value!.lengths[index]
            precondition(buffer.frameCapacity >= count)
            value!.buffers[index].withUnsafeBufferPointer { source in
                for channel in 0..<Int(buffer.format.channelCount) {
                    buffer.floatChannelData![channel].update(from: source.baseAddress! + channel * Self.blockFrames, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            value!.head = (value!.head + 1) % Self.blockCount
            value!.count -= 1
            value!.free.append(index)
            return true
        }
    }

    func snapshot() -> Snapshot? {
        state.withLock { value in
            value.map { Snapshot(frames: $0.frames, inputRate: $0.format.sampleRate,
                                 largestBuffer: $0.largestBuffer, finished: $0.finished && $0.count == 0) }
        }
    }
}
