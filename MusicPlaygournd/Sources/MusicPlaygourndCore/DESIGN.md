# MusicPlaygourndCore

## Purpose and Scope
Runtime module. Parent: [Package](../../DESIGN.md). Children: [Rendering](Rendering/DESIGN.md), [Playback](Playback/DESIGN.md), [Evaluation](Evaluation/DESIGN.md).

## Responsibilities and Boundaries
Owns immutable prepared PCM, resource validation, evaluation lifetime, synchronized playback, live master processing, and bounded post-FX sample snapshots. SwiftMusic owns musical event transformation. App owns UI and documents.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
SwiftMusic.CompiledSound -> LoopRenderer -> PreparedLoop -> AudioLoopEngine -> master FX -> post-FX samples
```

## Contracts and Invariants
PreparedLoop is Codable and Sendable, stereo interleaved Float PCM at 44100 Hz. It retains events plus one `LoopRow` per compiled source. A row owns sourceID, label, optional file/line/column anchor, and a bounded pre-mix peak envelope derived from that source's actual PCM; all-rest rows remain present with zero peaks. Events join rows by sourceID. Validate decoded data before playback. `SourceLineMap` owns bounded pure UTF-16 edit transforms. Playback owns actual post-FX capture; `SpectrumAnalyzer` consumes its bounded stereo snapshot off the audio callback.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Core tests own PCM behavior, limits, revision handoff and cancellation. Parent integration owns actual UI/device behavior.
