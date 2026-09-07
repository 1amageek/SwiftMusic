import Foundation

/// Owns the short, independent ramps used by the native master controls.
@MainActor
internal final class MasterParameterSmoother {
    internal enum Parameter: CaseIterable, Hashable, Sendable {
        case rate
        case lowPass
        case delay
        case reverb
    }

    internal typealias Sleep = @MainActor @Sendable (Duration) async throws(CancellationError) -> Void

    private let sleep: Sleep
    private var generation: UInt64 = 0

    private struct Ramp {
        let generation: UInt64
        let target: Float
        let apply: @MainActor (Float, Bool) -> Void
        var task: Task<Void, Never>?
    }

    private var ramps: [Parameter: Ramp] = [:]

    internal init(
        sleep: @escaping Sleep = { duration in
            do {
                try await ContinuousClock().sleep(for: duration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                preconditionFailure("ContinuousClock failed during a master parameter transition: \(error)")
            }
        }
    ) {
        self.sleep = sleep
    }

    internal func set(
        _ parameter: Parameter,
        from: Float,
        to: Float,
        immediate: Bool,
        apply: @escaping @MainActor (Float, Bool) -> Void
    ) {
        generation &+= 1
        let currentGeneration = generation
        ramps[parameter]?.task?.cancel()
        ramps[parameter] = Ramp(generation: currentGeneration, target: to, apply: apply, task: nil)

        guard !immediate, from != to else {
            apply(to, true)
            clear(parameter, generation: currentGeneration)
            return
        }

        let sleep = self.sleep
        let task = Task { @MainActor [weak self] in
            for step in 1...3 {
                do {
                    try await sleep(.milliseconds(10))
                    try Task.checkCancellation()
                } catch {
                    return
                }

                guard let owner = self,
                      owner.ramps[parameter]?.generation == currentGeneration else {
                    return
                }
                let fraction = Float(step) / 3
                apply(step == 3 ? to : from + (to - from) * fraction, step == 3)
                if step == 3 {
                    owner.clear(parameter, generation: currentGeneration)
                }
            }
        }
        ramps[parameter]?.task = task
    }

    /// Cancels ramps and synchronously applies each active target as its final value.
    internal func finishAll() {
        for parameter in Parameter.allCases {
            guard let ramp = ramps.removeValue(forKey: parameter) else { continue }
            ramp.task?.cancel()
            ramp.apply(ramp.target, true)
        }
    }

    /// Cancels ramps without writing a native value.
    internal func cancelAll() {
        for ramp in ramps.values {
            ramp.task?.cancel()
        }
        ramps.removeAll(keepingCapacity: true)
    }

    deinit {
        for ramp in ramps.values {
            ramp.task?.cancel()
        }
    }

    private func clear(_ parameter: Parameter, generation: UInt64) {
        guard ramps[parameter]?.generation == generation else { return }
        ramps.removeValue(forKey: parameter)
    }
}
