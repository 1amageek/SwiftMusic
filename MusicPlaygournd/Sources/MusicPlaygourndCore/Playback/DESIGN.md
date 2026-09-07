# Playback

## Purpose and Scope
Component. Parent: [Core](../DESIGN.md). Children: none.

## Responsibilities and Boundaries
AudioLoopEngine owns AVAudioEngine, revision-safe sample transport, live master processing, and bounded post-FX capture. Shared state is Mutex-protected on every access. App changes playback only through MainActor control APIs.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
prepared loop -> SourceNode -> TimePitch -> low-pass EQ -> Delay -> Reverb -> mainMixer
                    |                                               |
revision/bar adoption + live rate                         bounded stereo tap -> snapshot
```

## Contracts and Invariants
Public @MainActor engine: init() throws; beginUpdate(revision: UInt64); submit(loop: PreparedLoop, revision: UInt64) throws; play() throws; stop(); snapshot() -> PlaybackSnapshot. Snapshot fields loop: PreparedLoop?, revision: UInt64?, beatPosition: Double, isPlaying: Bool. New edit clears pending but preserves current. Reject stale/duplicate completions. First loop adopts while stopped. Existing playing loop adopts at next current-meter bar boundary without resetting the accumulated transport clock. Snapshot reports actual adopted PCM. Callback copies bounded PCM, no await/UI/I/O. Immutable buffers retain an off-callback owner to prevent deallocation on callback.

Live MainActor controls are `setPlaybackRate(_ rate: Float) throws`, `setLowPass(cutoff: Float?) throws`, `setDelay(mix: Float) throws`, `setReverb(mix: Float) throws`, and `outputMeter() -> OutputMeterSnapshot`. The generic engine defaults to rate 1; SessionModel supplies `liveBPM / 120` because its loops use a fixed 120 BPM preparation base. A nil cutoff bypasses EQ; a cutoff must be finite within 20...20,000 Hz. Delay and reverb mixes are normalized finite 0...1 values converted to native wet percentages. Neutral defaults are rate 1, bypassed EQ, and zero wet mix. Invalid controls fail explicitly and retain the last valid settings.

One main-mixer tap copies at most the latest 2,048 stereo Float frames and actual sample rate into preallocated Mutex-protected storage. `OutputMeterSnapshot` exposes `interleavedSamples: [Float]` and `sampleRate: Double`; the owned array has exactly 4,096 values when active and zeros while stopped. The callback performs bounded copy only. Snapshot/FFT work occurs off callback. This signal is after the owned effects and before hardware volume or room acoustics. Display beat position compensates valid engine output-presentation and unit latency; invalid latency metadata fails or is excluded explicitly rather than producing nonfinite positions.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Tests prove render cursor progress through failed/stale updates, boundary changes and stop/resume. Native offline AVAudioEngine tests prove 2x timing with stable pitch, low-pass attenuation, delay/reverb tails, neutral PCM behavior, bounded post-FX capture, paused zero, and latency compensation. Mutex copy callbacks are thread-safe but are not a hard-real-time guarantee. All unsafe audio-buffer borrows are scoped to callbacks and never escape. Shutdown removes the tap and stops the engine before resource release.

### State and platform ownership

| State | Storage / isolation | Read / mutation | Lifetime |
|---|---|---|---|
| Native audio graph and live parameters | MainActor engine | Public controls / snapshot | Engine stop, tap removal, owner release |
| Adopted and pending transport | Mutex<State> | Snapshot / submit / render callback | Engine-owned transport; immutable PCM also retained off callback |
| Post-effect capture | Preallocated Mutex storage | Owned snapshot copy / native tap bounded write | Engine-owned capture; stop disables and clears capture |

This package targets macOS AVFAudio only; it has no WASM or Embedded implementation or conditional synchronization path. No cross-platform synchronization capability is inferred from the native tests.
