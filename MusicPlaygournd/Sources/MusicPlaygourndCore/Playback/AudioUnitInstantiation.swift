import AVFoundation

/// A single native request; completion, timeout and cancellation share MainActor ownership.
@MainActor
internal final class AudioUnitInstantiation {
    typealias Completion = @Sendable (AVAudioUnit?, (any Error)?) -> Void
    typealias Start = @MainActor (AudioComponentDescription, @escaping Completion) -> Void

    private var continuation: CheckedContinuation<AVAudioUnit, any Error>?
    private var deadline: Task<Void, Never>?

    static func nativeStart(_ description: AudioComponentDescription, completion: @escaping Completion) {
        AVAudioUnit.instantiate(with: description, options: [], completionHandler: completion)
    }

    func value(for description: AudioComponentDescription, timeout: Duration = .seconds(10),
               start: Start = AudioUnitInstantiation.nativeStart) async throws -> AVAudioUnit {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.cancel(HostedAudioUnitError.timedOut)
                }
                start(description) { @Sendable [weak self] unit, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.cancel(HostedAudioUnitError.instantiationFailed(error.localizedDescription)) }
                        else if let unit { self.finish(.success(unit)) }
                        else { self.cancel(HostedAudioUnitError.instantiationFailed("The native callback returned no unit.")) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(CancellationError()) }
        }
    }

    func cancel(_ error: any Error = HostedAudioUnitError.superseded) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<AVAudioUnit, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        continuation.resume(with: result)
    }
}
