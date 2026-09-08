# SwiftMusic

SwiftMusic is a declarative Swift library for immutable `Sound` trees, exact beat-domain events and ordered render plans. Sibling declarations play concurrently in musical time; modifiers apply to their own subtree in Swift call-chain order.

SwiftMusic does not depend on SwiftUI. A host owns audio rendering, playback, source evaluation and UI. The companion [MusicPlaygournd](MusicPlaygournd/README.md) is a separate native host under development; its unfinished editor work is not a completed deliverable of this library release. See [PHILOSOPHY.md](PHILOSOPHY.md) for the intended live-editing experience.

## Installation

```swift
.package(url: "https://github.com/1amageek/SwiftMusic.git", exact: "0.2.0")
```

Link `.product(name: "SwiftMusic", package: "SwiftMusic")` from your target.

SwiftMusic 0.2.0 is a prerelease with no stable API promise. It requires Swift tools 6.4 and declares macOS 14 as its deployment target. Library tests were verified on macOS 27 arm64 with Swift 6.4.2-dev (2026-09-04, compiler `d2e983b81b18217`). Runtime behavior on macOS 14, Embedded Swift and WASM is not claimed.

## Declare music

```swift
import SwiftMusic

struct Groove: Sound {
    var body: some Sound {
        Sample("kick")
            .rhythm("x [x x] ~ x")
            .gain("1 [0.3 0.6] 0 0.8")

        Synthesizer(.saw)
            .notes("C2 Eb2 G2 Bb2")
            .pan("-1 1")
    }
}

struct Song: Music {
    var body: some Sound {
        Track("groove") { Groove() }
    }
}

@MainActor
func prepareSong() throws -> CompiledSound {
    try SoundCompiler().compile(Song())
}
```

`Music.body` is MainActor-isolated. Reusable `Sound` declarations and compiled values remain `Sendable`. `Track` is optional grouping and mix metadata. A compiled sound contains events and a render graph, not PCM audio.

## Performance models

Use native Observation for interactive state and explicitly inject it with `.performance(...)`:

```swift
import Observation
import SwiftMusic

@MainActor @Observable
final class Stage {
    var level = 0.5
    var position = SpatialPosition(x: 0, depth: 0)
}

struct PerformanceSong: Music {
    @Performance(Stage.self) private var stage

    var body: some Sound {
        Synthesizer(.sine)
            .notes("C4 E4 G4")
            .gain(stage.level)
            .position(stage.position)
    }
}

@MainActor
func preparePerformance(stage: Stage) throws -> CompiledSound {
    try SoundCompiler().compile(PerformanceSong().performance(stage))
}
```

`PerformanceObservationSession` observes body reads and notifies the host when preparation is needed; it does not schedule audio. A missing model produces a typed error. Optional `PerformanceEntry` factories and `PerformanceControllable` mappings expose finite number controls, one BPM role and atomic XY position updates. UI bindings belong to the host.

`SpatialPosition.x` ranges from -1 to 1; `depth` ranges from 0 to 1 and applies stylized attenuation, filtering and reverb. It does not represent physical 3D distance. Beat-domain plans remain separate from tempo; `Tempo.seconds(for:)` converts the same musical time at different BPM values.

## Patterns and processing

| Area | Included declarations and behavior |
| --- | --- |
| Patterns | Rhythm, notes, gain, pan, pitch, cutoff, envelopes and sample selection; string literals with deferred validation |
| Timing | Bracket subdivisions, cycle alternatives, leaf repetition, rational fast/slow, phase, reversal, repetition, swing and Euclidean/event transforms |
| Musical expression | Typed pitch, scales, chords, voicing, arpeggio, velocity, articulation, portamento and voice policy |
| Sources | Named/file/bank sample descriptors, sample traversal and granular/stretch descriptors, oscillators, FM, noise and wavetable descriptors |
| Processing | Ordered filter, dynamics, modulation and effect descriptors; automation and envelopes |
| Mixing | Gain, pan, Track policy, ducking, sends, bus returns and output routing |

`[x x]` subdivides one step. `<a b>` alternates across cycles; `x*8` repeats a leaf. Rhythm and notes accept `~` rests. Note patterns accept simultaneous pitches such as `C4,E4,G4`. Domain patterns retain their own types and support context-inferred string literals.

Patterned gain/pan are sampled at event onsets; scalar gain/pan append ordered post-mix graph operations. They are different stages of processing. Invalid patterns fail during compilation with typed diagnostics and UTF-8 offsets; `compileDetailed` preserves source provenance for a host editor.

Finite compilation and `compile(_:liveLoop:)` are explicit alternatives. Live compilation respects independent pattern periods, retains crossing event durations and emits seamless-loop metadata. The host must implement the corresponding circular playback behavior. Expansion, graph and event limits reject oversized input rather than truncate it.

## Live adoption

```text
edit → beginUpdate → prepare → receive → pending → host boundary → current
                         failure → diagnostic; current stays unchanged
```

`LiveMusicState` is a value owned and isolated by the host. Start a revision with `beginUpdate`, prepare with `LiveMusicUpdate.prepare`, and deliver its final result with `receive`. The host prepares audio resources before adopting through `adoptPendingAtBoundary`. Failed or stale edits cannot replace the current plan. The library does not start an audio device, evaluate Swift source or choose a playback boundary.

## Development

Run `swift test` from this package root. Tests use Swift Testing and cover actual compiler output, modifier order, validation failures, limits, Observation and revision transitions. Native audio behavior belongs to the separate host package.

## License

[MIT License](LICENSE).
