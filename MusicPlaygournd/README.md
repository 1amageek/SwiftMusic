# MusicPlaygournd

A native macOS editor for making music with SwiftMusic. Write a `Session: Music`, press Play, and keep editing while the last valid loop plays. Swift is compiled automatically after a short typing pause. The right-hand rhythm view displays the same prepared loop that supplies audio.

```text
Swift editor -> prepare -> next bar -> audio + rhythm
                  error -> diagnostic; current loop continues
```

## Run

Requires macOS 15+, Swift 6.4 and Xcode command-line tools. The initial dependency fetch requires network access. This app evaluates trusted local Swift code with your user account's permissions; it is not a code sandbox.

```sh
./Scripts/build-app.sh
open .build/MusicPlaygournd.app
```

The app bundle includes its evaluation package sources. It retains the installed Swift toolchain path used to build it; that toolchain must remain installed. The build is locally ad-hoc signed, not notarized or submitted to the App Store.

## Use

- Play/Pause: Command–Return. Apply immediately: Command–R. Otherwise edits apply automatically after 650 ms without typing.
- Change BPM (40–240) and quarter-note meter (2/4–7/4) independently of source. Prepared changes switch at a bar boundary.
- Open/Save UTF-8 Swift sessions: Command–O / Command–S. Keep the entry type named `Session` and conform it to `Music`.
- Click the diagnostic heading to select a reported Swift source line. Click a rhythm label to find a matching literal `Track` declaration.
- Use the lower-right layout button to put the rhythm view below the code.

## Playback support

| Supported | Behavior |
|---|---|
| `Sample("kick")`, `Sample("snare")`, `Sample("closedHat")` | Original built-in percussion sounds |
| `Synthesizer(.sine/.square/.saw/.triangle/.noise)` | Basic oscillator voices |
| Rhythm, notes, transpose, chords, velocity, gate | Compiled by SwiftMusic, rendered as events |
| Gain, pan, mute | Applied in render-plan order |
| Other source settings, effects, buses | Explicit unsupported-feature diagnostic; current audio survives |

This first version prepares finite PCM loops offline. Loops are padded to whole bars, bounded to 32 beats and 16 seconds. Source, event and graph limits bound preparation work. Synth voices use short edge fades; sustained effect tails and arbitrary sample files are not implemented. The callback is synchronized and bounded, without a hard real-time latency guarantee. Code-location navigation is not a general Swift source map.

See [DESIGN.md](DESIGN.md) for ownership and failure contracts. SwiftMusic remains pinned to its published 0.1.0 release.

## Verification

On macOS 27.0 arm64 with Swift 6.4 snapshot 2026-08-14, eight tests passed, including native AVAudioEngine playback while real Swift evaluations fail, time out, are cancelled, exceed diagnostic limits, and recover. PCM callback tests verify stale-update rejection and bar-boundary adoption. This does not claim tested macOS 15 runtime behavior or hard real-time scheduling.
