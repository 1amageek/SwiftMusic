# SwiftMusic

SwiftMusic declares immutable `Sound` trees. Sibling declarations are parallel, and modifiers transform only the subtree on which they are written. Rhythm and note literals stay in the declaration and resolve into exact beat-domain events during compilation.

The live music-making experience and the MusicPlaygournd editor are defined in [PHILOSOPHY.md](PHILOSOPHY.md). The example below uses the declarative foundation API.

The native macOS editor is in [MusicPlaygournd](MusicPlaygournd/README.md). It hosts real Swift evaluation, bounded PCM playback, and synchronized rhythm visualization.

## Requirements

SwiftMusic requires Swift tools 6.4. The 0.1.0 preview was verified with `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a` (compiler `424cae54c1a10da`) on macOS 27.0 arm64. The package deployment target is macOS 14; runtime behavior on macOS 14 is untested. This preview makes no stable API promise.

## SwiftPM installation

Add SwiftMusic as an exact-version dependency and link its library product:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/SwiftMusic.git", exact: "0.1.0")
],

targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftMusic", package: "SwiftMusic")
        ]
    )
]
```

```swift
import SwiftMusic

struct Groove: Sound {
    var body: some Sound {
        Sample("kick")
            .rhythm("x ~ x ~")
            .gain(0.9)

        Synthesizer(.saw)
            .notes("C2 Eb2 G2 Bb2")
            .gain(0.5)
    }
}

struct Song: Music {
    var body: some Sound {
        Track("groove") {
            Groove()
        }
    }
}

var liveState = LiveMusicState()
liveState.beginUpdate(revision: 0)
liveState.receive(.prepare(revision: 0, music: Song()))

// The host calls adoption after audio resources are ready, at its musical boundary.
// This standalone example demonstrates plan adoption only; it does not play audio.
if let sound = liveState.adoptPendingAtBoundary() {
    let slow = try Tempo(beatsPerMinute: 60)
    let fast = try Tempo(beatsPerMinute: 120)
    print(try slow.seconds(for: sound.extent))
    print(try fast.seconds(for: sound.extent))
}

liveState.beginUpdate(revision: 1)
liveState.receive(.prepare(revision: 1, sound: Sample("kick").rhythm("x ?")))
assert(liveState.currentRevision == 0)
assert(liveState.pendingSound == nil)
assert(liveState.diagnostic != nil)
```

The same adopted pattern spans 4 seconds at 60 BPM or 2 seconds at 120 BPM. The invalid edit leaves that pattern intact and exposes a typed diagnostic. `beginUpdate` must run when an edit arrives, before preparation, so late results from older edits cannot be adopted.

```text
edit -> beginUpdate -> prepare -> receive -> pending -> host boundary -> current
                                  failure -> diagnostic (current preserved)
```

`RhythmPattern` accepts whitespace-separated `x` and `~`; `NotePattern` accepts scientific pitch names and `~` rests. Their default cycle is four quarter-note beats. C4 is MIDI 60. Note-pattern literals generate a timed sequence; `notes([Pitch])` assigns pitches to existing events. To validate text immediately, use `try RhythmPattern(validating: text)` or `try NotePattern(validating: text)`. Literal conversion itself does not throw.

Preparation is synchronous and returns immutable beat events and an ordered render plan. An audio host prepares backend resources before calling `receive`, delivering one final success or failure per revision, then adopts at its chosen boundary. The host owns revision allocation, state isolation, clocking, and rendering. `LiveMusicState` handles plan adoption only: no audio backend, automatic bar synchronization, Swift source evaluator, or Editor UI is implemented in this library. The separate MusicPlaygournd package provides those host responsibilities.

## License

SwiftMusic is available under the [MIT License](LICENSE).
