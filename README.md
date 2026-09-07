# SwiftMusic

SwiftMusic declares immutable `Sound` trees. Sibling declarations are parallel; modifiers transform only the subtree on which they are written.

The live music-making experience and the planned MusicPlaygournd editor are defined in [PHILOSOPHY.md](PHILOSOPHY.md). The example below uses the currently implemented foundation API.

```swift
import SwiftMusic

struct Groove: Sound {
    let kickPattern: RhythmPattern
    let bassPitch: Pitch

    init() throws {
        kickPattern = try RhythmPattern("x ~ x ~")
        bassPitch = try Pitch(midiNote: 43)
    }

    var body: some Sound {
        Sample("kick")
            .rhythm(kickPattern, cycle: .whole)
            .gain(0.9)

        Synthesizer(.saw)
            .notes([bassPitch])
            .slow(2)
            .effect(.filter(kind: .lowPass, cutoffHz: 800, resonance: 0.2))
    }
}

struct Song: Music {
    let groove: Groove

    init() throws {
        groove = try Groove()
    }

    var body: some Sound {
        Track("groove") {
            groove
        }
    }
}

let song = try Song()
let compiled = try SoundCompiler().compile(song)
let slow = try Tempo(beatsPerMinute: 60)
let fast = try Tempo(beatsPerMinute: 120)

print(compiled.events)
print(try slow.seconds(for: compiled.extent))
print(try fast.seconds(for: compiled.extent))
```

`CompiledSound` contains exact beat-domain events, source settings, track metadata, and an ordered render plan. `Tempo` maps one compiled result to different real-time durations. Audio scheduling, synthesis, and editor views belong to client modules.
