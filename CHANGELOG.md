# Changelog

## 0.5.1 — Preview

- Reuse bounded pattern syntax within each compilation while preserving exact UTF-8 diagnostic offsets.
- Correct reducible overflow in musical-time addition.
- Organize implementation sources by responsibility without changing the public API.
- Verify the library with 208 Debug and Release tests on macOS.

## 0.5.0 — Preview

- Preserve builder structure with `TupleSound`, `EmptySound`, `ConditionalSound`, optional sounds and `ArraySound`.
- Add explicit generic `SoundGroup` and `AnySound`; compile structural children without flattening them into `[any Sound]`.
- Keep Track call syntax, parallel timing, modifier scope, bounded preparation and live event compilation.
- Source migration: explicitly annotated builder results now use generic structural types or `some Sound`.

## 0.4.0 — Preview

- Add nonthrowing scalar overloads for `envelope`, `filterEnvelope`, `pitchEnvelope`, `unison` and `duck`. Musical parameters can be declared directly inside `body` without `try!`.
- Validate these declarations during finite/live compilation and report invalid parameters with source locations.
- Preserve existing typed value initializers and successful compiled event semantics.
- SwiftMusic remains independent of SwiftUI and audio rendering.

## 0.3.0 — Preview

- Add SwiftUI-independent `@State` for declaration-local, main-actor observable music state.
- Preserve state identity when copying a music value; initialize independent state for new instances.
- Rewrite the README around composition, patterns, state, and the compiler/renderer boundary.
- Move MusicPlaygournd development to its own public repository.


## 0.2.0 (Prerelease) — 2026-09-08

- Extended the immutable `Sound`/`Music` compiler with bounded rhythm, note, gain, pan, pitch, cutoff, envelope and sample-selection patterns. Patterns support bracket subdivisions, cycle alternatives, leaf repetition and ordered `fast`, `slow`, `phase`, `reversed` and `repeated` transforms with checked rational rates and typed UTF-8 diagnostics.
- Added typed musical time, tempo, pitch, frequency, decibel, scale, key, chord, voicing, arpeggio, legato, portamento, unison, automation, envelope, probability, humanization, Euclidean rhythm, swing, ratchet and periodic-rhythm values.
- Added sample descriptors for named, absolute-file and validated sample-bank sources, plus source traversal for regions, selection, slicing, chopping, granular playback, stretching, reversal and playback-rate changes.
- Added oscillator descriptors for band-limited saw, pulse, frequency modulation, deterministic colored noise and wavetable sources while retaining the existing basic waveforms.
- Added ordered source, expression, filter, modulation, effect, mix and routing modifiers, including typed filter/chorus/flanger/phaser factories, tremolo, vibrato, ducking, sends, outputs, mute, voice policy and choke groups.
- Added MainActor performance-model injection with `@Performance(Model.self)`, `.performance(model)`, optional `PerformanceEntry` factories and `PerformanceObservationSession`. `PerformanceObservationSession.prepareDetailed` preserves located compiler diagnostics after one tracked body evaluation.
- Added optional typed performance controls for finite numbers, one BPM role and normalized `SpatialPosition` XY/depth values. Complete control-set validation rejects malformed IDs, domains, values, duplicate key paths and multiple BPM roles before mutation.
- Kept revision-safe live preparation explicit through `LiveMusicUpdate` and `LiveMusicState`: stale completions are rejected, failures retain the adopted plan, and adoption remains a host-selected boundary operation.


### Compatibility and verification

- `Music.body` and Music compiler entry points are MainActor-isolated; `Sound` and compiled values remain Sendable. SwiftMusic has no SwiftUI dependency.
- Requires Swift tools 6.4; package deployment target macOS 14. All 198 library tests passed on macOS 27 arm64 with Swift 6.4.2-dev (2026-09-04, compiler `d2e983b81b18217`). Runtime compatibility on macOS 14, Embedded Swift and WASM is not claimed.
- This release covers the SwiftMusic library product. MusicPlaygournd is a separate native host under development; remaining editor layout and full UI acceptance are not represented as complete. Audio rendering and hardware I/O remain host responsibilities.
- Prerelease APIs may change.

## 0.1.0 (Preview) — 2026-09-07

- Preview release of the declarative `Sound` and `Music` DSL with immutable beat events and render plans.
- Includes six modifier categories (rhythm, pitch and harmony, expression, source settings, audio effects, and mix and routing), rhythm and note patterns, and revision-safe live plan preparation and adoption through `LiveMusicState`.
- Verified by the native Swift 6.4 Debug and Release suites (30 tests) and an external client using the README flow.
- This preview makes no claims for DSP, audio playback, the MusicPlaygournd Editor, or WASM support.
