import Foundation
import Observation
import SwiftMusic

/// Type-erased retained preparation for one generated PerformanceEntry model.
@MainActor
public final class PerformanceWorkerAdapter<Base: Music, Model: AnyObject & Observable & Sendable>:
    RenderWorkerPerformanceAdapter, Sendable {
    private let model: Model
    private let observation: PerformanceObservationSession<Base>

    public init(
        base: Base,
        model: Model,
        compiler: SoundCompiler = .init()
    ) {
        self.model = model
        let resolvedMusic = base.performance(model)
        self.observation = PerformanceObservationSession(
            resolvedMusic,
            compiler: compiler,
            // The worker only prepares an explicit complete-set request. An
            // autonomous Observation callback never schedules audio work.
            onChange: {}
        )
    }

    public var controls: [PerformanceControlMetadata] {
        get throws {
            guard let controllable = model as? any PerformanceControllable else { return [] }
            return try controllable.performanceControlMetadata()
        }
    }

    public func currentValues() throws -> [String: PerformanceControlValue] {
        Dictionary(uniqueKeysWithValues: try controls.map { ($0.controlID, $0.value) })
    }

    public func validate(values: [String: PerformanceControlValue]) throws {
        guard let controllable = model as? any PerformanceControllable else {
            guard values.isEmpty else {
                throw PerformanceControlError.invalidMapping("The performance model declares no controls.")
            }
            return
        }
        try controllable.validatePerformanceControls(values)
    }

    public func apply(values: [String: PerformanceControlValue]) throws {
        guard let controllable = model as? any PerformanceControllable else {
            guard values.isEmpty else {
                throw PerformanceControlError.invalidMapping("The performance model declares no controls.")
            }
            return
        }
        try controllable.applyPerformanceControls(values)
    }

    public func prepare(
        revision: UInt64,
        source: String,
        fallbackBPM: Double,
        beatsPerBar: Int
    ) throws -> RenderWorkerPreparation {
        let metadata = try controls
        let bpm = try Self.renderBPM(from: metadata, fallback: fallbackBPM)
        let maximumLiveBeats = Int(min(
            PreparedLoop.maximumBeatCount,
            (PreparedLoop.maximumDurationSeconds * bpm / 60).rounded(.down)
        ))
        guard maximumLiveBeats > 0 else {
            throw SoundCompilationError.invalidPerformance("Performance BPM leaves no renderable horizon.")
        }
        let policy = try LiveLoopPolicy(
            beatsPerBar: beatsPerBar,
            maximumBeats: MusicalTime(numerator: UInt64(maximumLiveBeats), denominator: 1)
        )
        let sound = try observation.prepareDetailed(liveLoop: policy)
        let semanticMetadata = try EditorSemanticMetadata(
            sound: sound,
            source: source,
            revision: revision
        )
        let session = try LoopRenderSession(
            sound: sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            revision: revision
        )
        return RenderWorkerPreparation(
            session: session,
            metadata: semanticMetadata,
            source: source,
            performanceControls: metadata,
            performanceAdapter: self
        )
    }

    private static func renderBPM(
        from metadata: [PerformanceControlMetadata],
        fallback: Double
    ) throws -> Double {
        guard fallback.isFinite, (40...240).contains(fallback) else {
            throw SoundCompilationError.invalidPerformance("Fallback BPM is outside the render range.")
        }
        var bpm = fallback
        for control in metadata {
            guard case .double(let value) = control.value else { continue }
            guard case .double(_, let role) = control.domain else { continue }
            if role == .beatsPerMinute {
                bpm = value
                break
            }
        }
        guard bpm.isFinite, (40...240).contains(bpm) else {
            throw SoundCompilationError.invalidPerformance("Performance BPM is outside the render range.")
        }
        return bpm
    }
}
