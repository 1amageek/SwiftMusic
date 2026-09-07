# SwiftMusic

SwiftMusic is a small Swift package for declaring a score as immutable values. Sibling score expressions play in parallel, while a `Track` adds optional grouping metadata without changing timing.

```swift
import SwiftMusic

struct Groove: Score {
    let kick: Pitch
    let bass: Pitch

    init(kick: Pitch, bass: Pitch) {
        self.kick = kick
        self.bass = bass
    }

    var body: some Score {
        Track("drums") {
            Note(
                pitch: kick,
                start: .zero,
                duration: .quarter
            )

            Rest(start: .quarter, duration: .quarter)
        }

        Note(
            pitch: bass,
            start: .half,
            duration: .quarter
        )
    }
}

struct Song: Music {
    let groove: Groove

    init() throws {
        groove = Groove(
            kick: try Pitch(midiNote: 36),
            bass: try Pitch(midiNote: 43)
        )
    }

    var score: some Score {
        groove
    }
}

let song = try Song()
let score = try ScoreCompiler().compile(song)
let slow = try Tempo(beatsPerMinute: 60)
let fast = try Tempo(beatsPerMinute: 120)

print(score.events)
print(try slow.seconds(for: score.extent))
print(try fast.seconds(for: score.extent))
```

`CompiledScore` contains exact beat-domain events and track metadata. `Tempo` maps those values to seconds without recompiling the score. Audio scheduling, rhythm text parsing, and editor views are outside this package foundation.
