import Foundation
import Testing
@testable import MusicPlaygourndCore

@MainActor
struct MasterParameterSmootherTests {
    /// A deterministic injected clock shared by the focused and native smoother tests.
    @MainActor
    final class StepClock {
        private(set) var durations: [Duration] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var pendingCount: Int { waiters.count }

        func sleep(_ duration: Duration) async throws(CancellationError) {
            durations.append(duration)
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func advance() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }

        func finish() {
            while !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func playingUsesThreeMonotonicTenMillisecondSteps() async {
        let clock = StepClock()
        let smoother = MasterParameterSmoother(sleep: clock.sleep)
        defer {
            smoother.cancelAll()
            clock.finish()
        }
        var values: [(Float, Bool)] = []

        smoother.set(.rate, from: 0, to: 9, immediate: false) { value, final in
            values.append((value, final))
        }

        for expectedCount in 1...3 {
            await waitForPending(clock)
            clock.advance()
            await waitForValueCount(expectedCount) { values.count }
        }

        #expect(values.map(\.0) == [3, 6, 9])
        #expect(values.map(\.1) == [false, false, true])
        #expect(clock.durations == [.milliseconds(10), .milliseconds(10), .milliseconds(10)])
    }

    @Test(.timeLimit(.minutes(3)))
    func finalStepUsesTheExactRequestedFloat() async {
        let clock = StepClock()
        let smoother = MasterParameterSmoother(sleep: clock.sleep)
        defer { smoother.cancelAll(); clock.finish() }
        var values: [Float] = []
        let target: Float = 0.1
        smoother.set(.delay, from: 1, to: target, immediate: false) { value, _ in values.append(value) }
        for count in 1...3 {
            await waitForPending(clock)
            clock.advance()
            await waitForValueCount(count) { values.count }
        }
        #expect(values.last == target)
    }

    @Test(.timeLimit(.minutes(3)))
    func stoppedAndEqualTargetsApplyImmediately() async {
        let clock = StepClock()
        let smoother = MasterParameterSmoother(sleep: clock.sleep)
        defer {
            smoother.cancelAll()
            clock.finish()
        }
        var values: [(Float, Bool)] = []

        smoother.set(.delay, from: 0, to: 0.75, immediate: true) { value, final in
            values.append((value, final))
        }
        smoother.set(.reverb, from: 0.25, to: 0.25, immediate: false) { value, final in
            values.append((value, final))
        }

        #expect(values.map(\.0) == [0.75, 0.25])
        #expect(values.map(\.1) == [true, true])
        #expect(clock.pendingCount == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func replacementDoesNotAllowTheCanceledRampToClearTheNewOne() async {
        let clock = StepClock()
        let smoother = MasterParameterSmoother(sleep: clock.sleep)
        defer {
            smoother.cancelAll()
            clock.finish()
        }
        var values: [Float] = []

        smoother.set(.rate, from: 0, to: 9, immediate: false) { value, _ in
            values.append(value)
        }
        await waitForPending(clock)
        clock.advance()
        await waitForValueCount(1) { values.count }

        smoother.set(.rate, from: 3, to: 12, immediate: false) { value, _ in
            values.append(value)
        }
        await advanceUntilValueCount(clock, 2) { values.count }
        await advanceUntilValueCount(clock, 3) { values.count }
        await advanceUntilValueCount(clock, 4) { values.count }

        #expect(values == [3, 6, 9, 12])
    }

    @Test(.timeLimit(.minutes(3)))
    func parametersRunIndependentlyAndFinishAllSnapsTargets() async {
        let clock = StepClock()
        let smoother = MasterParameterSmoother(sleep: clock.sleep)
        defer {
            smoother.cancelAll()
            clock.finish()
        }
        var values: [MasterParameterSmoother.Parameter: [Float]] = [:]

        smoother.set(.rate, from: 1, to: 4, immediate: false) { value, _ in
            values[.rate, default: []].append(value)
        }
        smoother.set(.delay, from: 0, to: 1, immediate: false) { value, _ in
            values[.delay, default: []].append(value)
        }
        await waitForPending(clock, atLeast: 2)
        smoother.finishAll()
        clock.finish()
        await waitForValueCount(1) { values[.rate]?.count ?? 0 }
        await waitForValueCount(1) { values[.delay]?.count ?? 0 }

        #expect(values[.rate] == [4])
        #expect(values[.delay] == [1])
    }

    @Test(.timeLimit(.minutes(3)))
    func cancelAndDeinitializationProduceNoLaterWrites() async {
        let clock = StepClock()
        defer { clock.finish() }
        var values: [Float] = []
        var smoother: MasterParameterSmoother? = MasterParameterSmoother(sleep: clock.sleep)
        smoother?.set(.lowPass, from: 20, to: 1_000, immediate: false) { value, _ in
            values.append(value)
        }
        await waitForPending(clock)
        smoother?.cancelAll()
        clock.finish()
        await Task.yield()
        #expect(values.isEmpty)

        smoother = MasterParameterSmoother(sleep: clock.sleep)
        smoother?.set(.lowPass, from: 20, to: 1_000, immediate: false) { value, _ in
            values.append(value)
        }
        await waitForPending(clock)
        smoother = nil
        clock.finish()
        await Task.yield()
        #expect(values.isEmpty)
    }

    private func waitForPending(_ clock: StepClock, atLeast count: Int = 1) async {
        for _ in 0..<100 where clock.pendingCount < count {
            await Task.yield()
        }
        let ready = clock.pendingCount >= count
        #expect(ready)
    }

    private func waitForValueCount(
        _ count: Int,
        _ valueCount: @escaping @MainActor () -> Int
    ) async {
        for _ in 0..<100 where valueCount() < count {
            await Task.yield()
        }
        let ready = valueCount() >= count
        #expect(ready)
    }

    private func advanceUntilValueCount(
        _ clock: StepClock,
        _ count: Int,
        _ valueCount: @escaping @MainActor () -> Int
    ) async {
        for _ in 0..<8 {
            await waitForPending(clock)
            clock.advance()
            await Task.yield()
            if valueCount() >= count { return }
        }
        let ready = valueCount() >= count
        #expect(ready)
    }
}
