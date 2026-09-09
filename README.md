# SwiftMusic

**Compose music with Swift.** Declare sounds, patterns, and musical transformations using a SwiftUI-inspired API—without importing or depending on SwiftUI.

```swift
import SwiftMusic

struct Session: Music {
    var body: some Sound {
        Track("Kick") {
            Sample("kick")
                .rhythm("x ~ x ~")
                .gain("1 0.7")
        }

        Track("Hi-hat") {
            Sample("closedHat")
                .rhythm("x [x x] x [x x]")
                .gain("0.5 [0.2 0.4] 0.5 [0.2 0.3]")
                .pan(0.2)
        }

        Track("Bass") {
            Synthesizer(.saw)
                .notes("C2 ~ [Eb2 G2] G2")
                .gain(0.3)
        }
    }
}
```

Declare envelopes and unison directly in `body`, without `try!`:

```swift
Synthesizer(.bandLimitedSaw)
    .notes("C2 Eb2 G2 Bb2")
    .envelope(
        attack: .milliseconds(2), decay: .milliseconds(95),
        sustainLevel: 0.35, release: .milliseconds(30)
    )
    .unison(voices: 5, detuneCents: 32)
```

Scalar `envelope`, `filterEnvelope`, `pitchEnvelope`, `unison` and `duck` modifiers validate during compilation. Invalid values produce located compilation errors; the host can retain the previously adopted music. Existing throwing value initializers remain available for explicit validation.

Sibling sounds play in parallel. `Track` groups and names sounds; it is optional. A modifier applies to the sound subtree above it, so placement and order matter.

To hear your code, use **[MusicPlaygournd](https://github.com/1amageek/MusicPlaygournd)**, the native macOS live editor with inline rhythms, pattern highlighting, waveform/spectrum monitoring, and interactive controls.

## Install

SwiftMusic **0.5.0 Preview** requires Swift 6.4 and declares macOS 14 as its minimum deployment target. Verified on macOS 27 with Apple silicon; older macOS runtime behavior is not verified. Preview APIs may change.

```swift
.package(url: "https://github.com/1amageek/SwiftMusic.git", exact: "0.5.0")
```

Add `.product(name: "SwiftMusic", package: "SwiftMusic")` to your target dependencies.

## Music, Sound, and state

| API | Responsibility |
|---|---|
| `Music` | The composition entry point, with `@MainActor body: some Sound` |
| `Sound` / `SoundBuilder` | Composable declarations and ordinary Swift control flow |
| `Track`, `SoundGroup` | Grouping and modifier scope |
| `@State` | Declaration-local observable state retained with your music value |
| `@Performance(Model.self)` | An explicitly injected, observable performance model |
| `SoundCompiler` | Validated beat-domain events and an ordered render plan |
| `Tempo`, `LiveMusicState` | Time conversion and revision-aware plan adoption |

`@State` is supplied by SwiftMusic. Its value is read and changed on the main actor. Copies of a music value share its state; creating a new instance creates fresh state. The host retains the instance for the session lifetime.

```swift
import SwiftMusic

enum Beat: Sendable { case steady, fill }

struct SwitchSession: Music {
    @State var beat: Beat = .steady

    var body: some Sound {
        Track("Drums") {
            switch beat {
            case .steady:
                Sample("kick").rhythm("x ~ x ~")
            case .fill:
                Sample("kick").rhythm("x x [x x] x")
            }
        }
    }
}

@MainActor
func prepareSession() throws {
    let session = SwitchSession()
    let compiler = SoundCompiler()
    let steady = try compiler.compile(session)
    session.beat = .fill
    let fill = try compiler.compile(session)
    print(steady.events.count, fill.events.count) // 2, 5
}
```

If the same file imports SwiftUI, use `@SwiftMusic.State` or `@SwiftUI.State` to disambiguate. SwiftMusic does not create UI buttons or automatically recompile on mutation; the host owns that connection. MusicPlaygournd supports preprepared switch variants for live selection.

## Typed composition

`SoundBuilder` preserves the types of declarations instead of collecting every expression into `[any Sound]`.

| Swift declaration | Result |
| --- | --- |
| Empty body | `EmptySound` |
| One sound | The original sound type |
| Multiple sounds | `TupleSound<(A, B, ...)>` |
| `if` / `else`, `switch` | `ConditionalSound<First, Second>` |
| `if` without `else`, `if let` | Optional sound content |
| Finite `for` loop | `ArraySound<Content>` |
| `if #available` | `AnySound` at the availability boundary |

```swift
struct Layer: Sound {
    let includeBass: Bool

    var body: some Sound {
        SoundGroup {
            Sample("kick").rhythm("x ~ x ~")
            if includeBass {
                Synthesizer(.sine).notes("C2 ~ Eb2 ~")
            }
        }
        .gain(0.4)
    }
}
```

`SoundGroup` groups parallel sounds and scopes shared modifiers without introducing track metadata. `EmptySound` contributes neither events nor duration; it is not a timed rest. `AnySound` explicitly erases one sound's type when needed. Ordinary declarations should use `body: some Sound` and let the builder infer their structure.

Existing `Track` and `ModifiedSound` types remain type-erasure boundaries. The compiler visits typed children directly without constructing an existential child array, then produces the same public event and render-plan model. This does not introduce persistent identity or state reconciliation for repeated children.

**Source compatibility:** Explicit `SoundGroup` result annotations must become `SoundGroup<Content>` or `some Sound`. Builder-taking APIs should accept generic `Content: Sound` rather than requiring the former concrete `SoundGroup`. These structural types are available starting in 0.5.0.

## Patterns

Pattern arguments accept context-inferred string literals. Invalid literals produce typed errors during compilation; use a pattern's throwing validating initializer when immediate validation is needed.

| Notation | Meaning |
|---|---|
| `x ~ x ~` | Hits and rests in evenly divided slots |
| `x [x x] ~ x` | Brackets subdivide a parent slot |
| `x*8` | Repeat a leaf eight times |
| `<C4 D4>` | Alternate across cycles |
| `C4,E4,G4` | Simultaneous pitches in a note pattern |
| `.gain("1 [0.3 0.6] 0.8")` | Gain sampled at each event onset |
| `.pan("-1 1")` | Per-event stereo position |

The default cycle is four quarter-note beats. C4 is MIDI 60. Rhythm, note, gain, and pan patterns support ordered speed, phase, reversal, and repetition transformations. Exact rational musical time avoids accumulating floating-point timing error. Expansion and live-loop windows are bounded and fail explicitly instead of truncating.

## Musical vocabulary

| Category | Selected APIs |
|---|---|
| Rhythm and arrangement | `rhythm`, `fast`, `slow`, `offset`, `repeated`, `oneShot`, `swing`, `euclidean`, `ratchet`, `probability` |
| Pitch and harmony | `notes`, `transpose`, `chord`, `voicing`, `inverted`, `arpeggiated`, `portamento` |
| Expression | `dynamic`, `velocity`, `gate`, `humanize` |
| Sources | Samples, oscillators, envelopes, filters, sample regions/slices, granular playback, unison and voice policies |
| Effects and mixing | `effect`, `tremolo`, `vibrato`, `gain`, `pan`, `muted`, `duck`, buses, sends and outputs |
| Automation | Typed gain, pan, pitch and cutoff automation; observable performance controls |

These declarations describe musical events and rendering work. Actual audio support is the responsibility of the chosen renderer. See the [source API](Sources/SwiftMusic/SoundComposition) and [design contracts](Sources/SwiftMusic/SoundComposition/DESIGN.md) for supported values and failure semantics.

## Library and player are separate

```text
Music / Sound → SoundCompiler → beat events + ordered render plan
                                          ↓
                                  host renderer → audio
```

SwiftMusic does not open an audio device, evaluate Swift source, or draw an editor. A host chooses its clock, prepares audio resources, and adopts successful changes at its chosen boundary. BPM is separate from the musical pattern: the same compiled beat-domain events can be interpreted at different tempos.

`LiveMusicState` tracks revisions and preserves the last adopted plan when preparation fails or a stale result arrives. Audio continuity additionally requires the host to retain its last valid audio resources. [MusicPlaygournd](https://github.com/1amageek/MusicPlaygournd) implements the live editing experience.

## Development

```sh
swift test
```

Tests use Swift Testing. See [PHILOSOPHY.md](PHILOSOPHY.md) for product direction, [DESIGN.md](DESIGN.md) for ownership and invariants, and [CHANGELOG.md](CHANGELOG.md) for release changes.

## License

[MIT](LICENSE) · Copyright 2026 1amageek.
