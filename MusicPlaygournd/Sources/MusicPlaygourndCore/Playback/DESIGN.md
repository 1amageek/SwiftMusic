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

P04 keeps these APIs and native TimePitch -> EQ -> Delay -> Reverb ownership. While transport is playing, one MainActor `MasterParameterSmoother` applies each accepted target over three linear 10-millisecond intervals using `ContinuousClock`, for a fixed 30-millisecond transition and 100 Hz native writes. Parameters own independent tasks. A newer value for the same parameter cancels only that task and starts from its last applied interpolated value. While transport is stopped, no audible transition exists: an accepted target cancels its parameter task and applies the final native value synchronously, which also keeps existing configure-then-offline-render callers deterministic without MainActor starvation. Validation occurs before changing target/task state and cancellation is not reported as a control failure. Native properties are written only on MainActor, never from the audio callback or under the transport/output-meter Mutex. The internal smoother injects an `@MainActor @Sendable (Duration) async throws(CancellationError) -> Void` sleep closure. Its production adapter alone calls the untyped-throwing `ContinuousClock.sleep(for:)`: `CancellationError` is forwarded, while any non-cancellation error is an explicit internal invariant failure and is never rounded to elapsed time or cancellation. Focused tests drive a typed-cancellation closure and observe applied steps without a public clock protocol, failure channel or configuration API. P05 may add automation precedence without changing this base transition owner.

Low-pass enable and disable have explicit transition state. Enabling from bypass first sets 20,000 Hz and clears bypass, then ramps to the requested cutoff. Changing an enabled cutoff ramps from the last applied frequency. Disabling an enabled filter ramps to 20,000 Hz and sets bypass only after the final step; replacement before that step keeps the filter enabled and starts from the current frequency. A nil target while already bypassed is a no-op. Stopped application of nil bypasses synchronously.

Playback-rate smoothing changes only TimePitch rate. It neither reevaluates source nor resets `framePosition`, accumulated beat position, current/pending revision, effect state or the bar-adoption boundary. Transport remains measured in the prepared loop's source beats; snapshot latency correction uses the current interpolated rate. Delay/reverb master tails remain native post-loop output and post-FX meter data, while code-declared deterministic tails are already part of PreparedLoop. Invalid controls, edit/evaluation/render failure and stale submission preserve the current adopted loop, in-flight ramps and last valid master targets. `stop()` cancels every task and synchronously snaps each native property to its last valid target while inaudible, so the next play starts from the requested state; it does not clear those targets. Engine deinitialization cancels every task before removing the tap and stopping/releasing the graph, and canceled tasks check cancellation before every native write.

P04 playback verification proves exact 10/20/30-millisecond monotonic steps, independent parameters and replacement from an in-flight value; immediate stopped configuration; low-pass 20 kHz enable/disable transitions and bypass timing; no source revision/evaluation on controls; phase-preserving rate change; current-meter boundary adoption during a rate ramp; invalid/stale failure preservation; stop snap-to-target and deinit cancellation with no later native write; native master tail and post-FX meter behavior; and callback isolation. A native actual-output fixture distinguishes smoothed controls from a step while retaining pitch through tempo change.

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
