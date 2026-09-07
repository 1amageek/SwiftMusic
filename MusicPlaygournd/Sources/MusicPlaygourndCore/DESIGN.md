# MusicPlaygourndCore

## Purpose and Scope
Runtime module. Parent: [Package](../../DESIGN.md). Children: [Rendering](Rendering/DESIGN.md), [Playback](Playback/DESIGN.md), [Evaluation](Evaluation/DESIGN.md).

## Responsibilities and Boundaries
Owns immutable prepared PCM, resource validation, evaluation lifetime and synchronized playback. SwiftMusic owns musical event transformation. App owns UI and documents.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
SwiftMusic.CompiledSound -> LoopRenderer -> PreparedLoop -> AudioLoopEngine
```

## Contracts and Invariants
PreparedLoop is Codable and Sendable, stereo interleaved Float PCM at 44100 Hz. Fields: sampleRate Double, bpm Double, beatsPerBar Int, beatCount Double, samples [Float], events [LoopEvent]. LoopEvent fields: sourceID Int, label String, startBeat Double, durationBeats Double, midiNote Int?, velocity Int. Validate decoded data before playback.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Core tests own PCM behavior, limits, revision handoff and cancellation. Parent integration owns actual UI/device behavior.
