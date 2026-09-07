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

### P05 control precedence boundary

This section is the sole authority for live precedence. P05.1 keeps source/subtree automation descriptors in CompiledSound even though LoopRenderer produces immutable PCM. P05.7 makes source/subtree gain, pan, pitch and cutoff, track level/pan, and the existing native master rate, low-pass cutoff, delay mix and reverb mix runtime-addressable only after their concrete path is implemented. No editor control may report an address as live merely because a descriptor exists.

For source, subtree and track addresses, the successful evaluator result retains the bounded CompiledSound plus immutable render inputs needed to reproduce the adopted PCM, including the decoded sample snapshot; it does not retain or rerun user Swift. An address is `(adoptedRevision, targetKind, compiledID)` and is valid only within that revision. One actor accepts override generations, runs at most one cooperative LoopRenderer job, cancels or rejects older generations, and retains the last valid PCM on cancellation, bound failure or render failure. The existing 32-beat/16-second, 1,024-event, 32-source, graph/FFT and decoded-sample budgets remain authoritative; the retained evaluation payload is bounded by those owned inputs rather than an unbounded stem cache. A completed override preserves beatCount and timing, enters AudioTransport at the current normalized frame/beat phase under the same code revision, and crossfades circular old/new PCM for 30 milliseconds. Release rerenders the retained code scalar/automation without the gesture override and uses the same phase-preserving crossfade. This supplies audible source control without source evaluation, a guessed inverse of baked PCM, or a mutable callback graph.

Native master addresses continue through the P04 MainActor properties and smoother without PCM rerender. Across both paths the active knob/XY gesture is the top layer, adopted code automation is next, and its adopted code scalar is the baseline; automation phase continues while overridden. Failed/stale code evaluation retains the adopted retained graph, PCM and active overlay. A newly adopted code revision atomically switches loop and retained inputs at its bar boundary and invalidates prior compiled IDs; unresolved addresses release to the new code result rather than being remapped by position. P05.7 owns serialization/lifetime of retained inputs, latest-generation cancellation, crossfade state and its resource evidence. P05.1 only guarantees complete descriptors and adds no callable future API.

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
