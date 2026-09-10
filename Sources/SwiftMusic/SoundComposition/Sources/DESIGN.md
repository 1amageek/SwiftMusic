# Sources

## Purpose and Scope

Sample and synthesizer declarations and source capability descriptors. No children.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`Sample`, `SampleAsset`, `SampleBank`, `SampleDescriptorError`, `SampleRegion`, `SampleSlice`, `Synthesizer`, `SynthesizerDescriptorError`, `Waveform`, `Wavetable`, `PulseWave`, `Noise`, `FrequencyModulation`, `GranularPlayback`, `SourceKind`, `SourceFilter`, `FilterKind`, `FilterSlope`, `Unison`, `VoicePolicy`, `VoiceStealing`.

## Related Designs

- Parent: [SoundComposition](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../../Tests/SwiftMusicTests).
- Related component: [SoundComposition](../DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [MusicalValues](../../MusicalValues/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Compilation](../../Compilation/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [RenderPlan](../../RenderPlan/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Performance](../../Performance/DESIGN.md); shared SwiftMusic types retain their existing access levels.

## Architecture

```text
Sound declarations + values + patterns + automation
    -> Compilation -> RenderPlan -> host
Performance -> declaration evaluation
```

## Contracts and Invariants

Source declarations, access levels, state isolation, error propagation and compiler ordering are unchanged by this layout. Public consumers continue to import SwiftMusic. Tests remain in one SwiftMusicTests target; production directories do not introduce separate representations or adapters.

## Verification and Change Impact

Verify every relocated Swift file against its original SHA-256 digest, run the SwiftMusic behavioral suite, and check documentation links and SwiftPM source discovery. Changes to these types require checking their compiler callers and the public tests; folder placement alone does not establish runtime correctness.

### Source settings

`Tuning(referencePitch:frequencyHz:)`, `Envelope(attackSeconds:decaySeconds:sustainLevel:releaseSeconds:)`, `SampleRegion(startFraction:endFraction:)`, and `Unison(voices:detuneCents:)` have throwing initializers. Frequencies are finite positive; time and detune are finite nonnegative; normalized fields are 0...1; region start is less than end; unison is 1...16 voices. `CompiledSource` also exposes its optional pattern anchor; source ID remains the join key for events and client rows.

Tuning and envelope support both sources. Sample region supports only Sample; unison only Synthesizer. An incompatible source anywhere in the modifier subtree is a typed compilation failure. Repeated settings apply inner-to-outer, so outer replaces the same field. `CompiledSource` exposes snapshot ID, source kind, and explicit optional settings.

## Native Source Performance

P03 turns existing source descriptors into audible native behavior while keeping musical compilation independent of file and audio I/O. SwiftMusic validates and emits immutable source/event policy; MusicPlaygournd resolves files, allocates voices, and renders PCM. No compiler API reads a file, opens an audio device, or silently substitutes a built-in sound.

Existing `Envelope` remains the amplitude ADSR descriptor and both current initializers remain source compatible. `EnvelopeCurve` is `.linear` or `.exponential(exponent: Double)` with finite exponent greater than zero. `EnvelopeReleaseAnchor` is `.gateEnd` or `.eventEnd`. Additive Envelope initializers accept attack, decay and release curves plus a release anchor, defaulting all curves to linear and the anchor to gateEnd; existing values therefore keep their prior metadata. For a segment from `a` to `b`, normalized local time `t` uses `a + (b - a) * pow(t, exponent)`, with linear equivalent to exponent one. Attack runs 0 to 1, decay 1 to sustainLevel, sustain holds, and release starts at the selected anchor from the contour's actual value at that instant and reaches zero over releaseSeconds. Zero-length segments take their ending value without division.

`pitchEnvelope(_ envelope: Envelope, depth: Semitones)` and `filterEnvelope(_ envelope: Envelope, depth: Semitones)` replace the corresponding optional source modulation descriptor; their signed finite depth multiplies the normalized ADSR contour. Pitch adds that value in semitones. Filter modulation multiplies cutoff by `pow(2, depth * contour / 12)`, so zero depth is neutral and negative depth lowers cutoff. The P02.4 event envelope overrides only amplitude Envelope; source amplitude envelope is its fallback. Pitch/filter modulation each owns its supplied Envelope and does not reuse the amplitude event override. Outer declarations replace the same descriptor, and all metadata remains immutable.

`SourceFilter` retains its P02.4 kind/Q/slope shape. P03 permits `.lowPass`, `.highPass` and `.bandPass`, rejects `.notch`, requires finite resonance Q in `0.1...32`, and keeps `FilterSlope.twelve` and `.twentyFour`. `lowPass`, `highPass` and `bandPass` each have overloads accepting a fixed `Frequency` or a `CutoffPattern`, with `cycle: MusicalTime = .whole`, `resonanceQ: Double = 0.7071067811865476` and `slope: FilterSlope = .twelve`; a fixed value writes one cutoff to every current event and records an ordered `_LiveEventProgram` event operation so later recurring occurrences receive the same cutoff. It adds no independent period and does not remove periods from earlier pattern samplers. Every event under a source filter must have finite positive cutoff below the renderer sample-rate Nyquist limit after filter-envelope modulation. Invalid kind, Q, base cutoff or reachable modulated endpoint is a typed failure; no value is clamped. Existing `AudioEffect.filter` remains a post-mix render node owned by P04 and is not reinterpreted as this per-voice filter.

The additive public surface is fixed as follows; the existing four-argument Envelope calls remain valid because the new arguments default as shown.

```swift
public enum EnvelopeCurve { case linear; case exponential(exponent: Double) }
public enum EnvelopeReleaseAnchor { case gateEnd; case eventEnd }
public struct EnvelopeModulation {
    public let envelope: Envelope
    public let depth: Semitones
}

public init(
    attackSeconds: Double, decaySeconds: Double, sustainLevel: Double, releaseSeconds: Double,
    attackCurve: EnvelopeCurve = .linear, decayCurve: EnvelopeCurve = .linear,
    releaseCurve: EnvelopeCurve = .linear, releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
) throws
public init(
    attack: Duration, decay: Duration, sustainLevel: Double, release: Duration,
    attackCurve: EnvelopeCurve = .linear, decayCurve: EnvelopeCurve = .linear,
    releaseCurve: EnvelopeCurve = .linear, releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
) throws

public func pitchEnvelope(_ envelope: Envelope, depth: Semitones) -> ModifiedSound
public func filterEnvelope(_ envelope: Envelope, depth: Semitones) -> ModifiedSound
public func lowPass(_ cutoff: Frequency, resonanceQ: Double = 0.7071067811865476,
                    slope: FilterSlope = .twelve) -> ModifiedSound
public func highPass(_ cutoff: Frequency, resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
public func bandPass(_ cutoff: Frequency, resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
public func highPass(_ cutoff: CutoffPattern, cycle: MusicalTime = .whole,
                     resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
public func bandPass(_ cutoff: CutoffPattern, cycle: MusicalTime = .whole,
                     resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
```

```text
oscillator/sample frame
  -> sample traversal or pitch + pitch envelope
  -> per-voice source filter + filter envelope
  -> amplitude ADSR -> velocity -> event gain/pan
  -> source mix -> existing ordered render nodes
```

`Sample(_ name:)` and `SourceKind.sample(String)` keep their named procedural behavior. P03.3 adds `Sample(file:rootPitch:)` and `Sample(bank:)` as descriptor-only sources. `SampleAsset(key:fileURL:rootPitch:)` requires an absolute file URL and a key that the existing mini-pattern parser accepts by itself as exactly one non-rest leaf with the identical token text; whitespace, delimiters, operators, empty text and `~` are therefore rejected at the asset index rather than creating an unreachable bank entry. `rootPitch` defaults to `.middleC` and declares the pitch heard when decoded traversal rate is one under A4=440 equal temperament. The direct-file initializer has the same default. `SampleBank(_:)` requires an ordered nonempty array of `SampleAsset`, rejects duplicate keys, and never enumerates a directory. A bank source seeds its event with the first explicitly ordered asset key. `SampleSelectionPattern` is `ExpressibleByStringLiteral`, uses the existing bounded mini-pattern grammar and transforms, and permits bank keys but not rests; malformed syntax remains deferred for literals.

The compiler gives file/bank seed events pitch `.middleC`; a direct file event keeps `CompiledSoundEvent.sampleKey` nil and a bank seed stores its first key. Later notes, transpose and pitch patterns retain their existing effective-MIDI validation. `.sampleSelection(_ pattern: SampleSelectionPattern, cycle: MusicalTime = .whole)` samples the selected key at each current event onset, preserves rhythm/note provenance, and never changes event onset, duration, pitch, label or source identity. It requires a positive cycle and every affected source to be a bank containing every realized key; direct files, procedural samples, synthesizers, unknown keys, rests, empty realization, parser/count/period overflow and invalid UTF-8 locations fail with the declared typed error.

Modifier order follows the existing parameter-pattern contract. Before a rhythm/note generator, sample selection resolves only the current finite seed and contributes no future clock. After a generator it is an ordered `_LiveEventProgram` event sampler, contributes its complete transformed period to the checked common window and resolves every generated onset before periodic values are copied. Thus live variation is written `Sample(bank: bank).rhythm(...).sampleSelection(...)`; the API does not hide a pre-generator sampler in the constructor. A later selection replaces each event's earlier key value while earlier declared sampler periods remain in the LCM. `Sound.repeated` closes it with the existing template rule. Renderer and Playback never parse or advance the pattern.

Canonical live evaluation extends `_SoundCompilationContext.applyEvents` with read-only `CompiledSource` lookup. It uses existing source IDs to validate the event's bank and key and mutates only event copies; it does not allocate, replace or renumber sources, tracks or render nodes. `_LiveEventProgram.emit` receives the same immutable compiled-source snapshot that the initial compiler pass produced, so initial and future-onset validation share one bank authority.

The additive public surface is `Sample(file url: URL, rootPitch: Pitch = .middleC) throws`, `Sample(bank: SampleBank)`, `SampleAsset(key: String, fileURL: URL, rootPitch: Pitch = .middleC) throws`, `SampleBank(_ assets: [SampleAsset]) throws`, `sampleSelection(_:cycle:)`, `sampleRegion(_:)`, `sampleReversed()` and `samplePlaybackRate(_:) throws`. The rate is finite and strictly positive; one is neutral. Region is applied first, reversal changes traversal direction inside that region, and rate multiplies pitch traversal without changing musical event onset, gate, duration or compiled extent. An outer declaration replaces the same region, direction or rate setting. These settings apply only to file/bank descriptors as specified; applying them to a procedural named sample or synthesizer is a typed compilation failure. Pitch-preserving stretch remains P06.

The immutable compiled representation adds `SourceKind.fileSample(fileURL:rootPitch:)`, `SourceKind.sampleBank(SampleBank)`, optional `CompiledSoundEvent.sampleKey`, and `CompiledSource.sampleReversed` plus `samplePlaybackRate` whose defaults are false and one. `SampleDescriptorError` owns `invalidFileURL`, `emptyBank`, `invalidKey(index:)`, `duplicateKey(_:)` and `invalidPlaybackRate(_:)`. `SampleSelectionPatternError` owns parser/value failures with UTF-8 offsets; bank-dependent absence is `SoundCompilationError.unknownSampleKey(key:utf8Offset:)`, and applying traversal to an incompatible source is `SoundCompilationError.unsupportedSourceSetting`. Literal construction never converts one of these failures into an empty/default descriptor.

P03.3 file and bank samples are pitched through their explicit asset root. The renderer combines the selected asset's root, event pitch/offset, optional source tuning and pitch envelope with `samplePlaybackRate`; no filename or PCM analysis guesses pitch. Procedural built-ins have no decoded asset/root and retain the P03.2 typed rejection for those pitch settings. They keep their synthesized waveform and do not pass through the file loader. SwiftMusic owns descriptor/key/pattern/settings validation and immutable metadata only; it never opens a URL or decodes audio.

### P06 sample slicing, stretch and granular playback

P06.1 extends only decoded file/bank samples. `SampleSlice` stores zero-based `index` and positive `count`; `init(index:count:) throws` requires `1...1024` slices and `index < count`. `Sound.sampleSlice(_:)` replaces the source region with that exact equal subdivision of the currently declared `SampleRegion`, or of 0...1 when no region exists. Region and slice follow ordinary inner-to-outer replacement: an outer `sampleRegion` discards the inner slice, while an outer slice subdivides the current region. A procedural named sample or Synthesizer fails with `unsupportedSourceSetting`; there is no procedural approximation.

`Sound.chopped(into count: Int) throws` is an event transform requiring `1...1024`. It replaces each current event by `count` stable-order events whose exact starts and durations partition that event's `MusicalTime` duration and whose event-level slice indices partition its effective source region. Copies retain source/Track, pitch, velocity, gain/pan, duck, harmony, pattern anchor and `patternStepIndex`; harmony occurrence IDs are copied through the established copy owner so independent chopped occurrences cannot merge. Gate/envelope apply independently to each true chopped onset. The transform is captured by `_LiveEventProgram`, preserves the enclosing recurrence period, and checks multiplication against the compiler event limit before allocation. Count one is metadata/PCM neutral.

`GranularPlayback` is an immutable `Sendable`, `Equatable` descriptor with `grainDuration: Duration`, `overlap: Double`, `positionJitter: Double` and `seed: UInt64`; its throwing initializer requires a finite positive duration, finite overlap in `0..<1` and finite jitter in `0...1`. `.standard` is 40 milliseconds, 0.5 overlap, zero jitter and seed zero. `Sound.granular(_:)` replaces the decoded source's granular timbral mode while preserving its current traversal duration. Granular playback does not claim pitch-preserving time stretch. `Sound.sampleStretch(to duration: MusicalTime) throws` separately requires a positive exact beat duration and stores a native pitch-preserving preprocessing request. An outer stretch replaces only stretch duration; an outer granular declaration replaces only grain settings, so they compose without hidden defaults or declaration-order coupling. These source settings do not retime compiled event onsets or recurrence.

CompiledSource retains optional `granularPlayback` and `sampleStretchDuration`; CompiledSoundEvent retains optional event `sampleSlice`. The compiler validates source compatibility, checked slice fractions, live copies and limits but performs no decoding or DSP. Existing `samplePlaybackRate`, root pitch, tuning, pitch envelope and portamento still own pitched traversal after stretch preprocessing. Stretch itself changes decoded duration at zero pitch shift; it does not modify root pitch or compensate another pitch modifier. Every final effective pitch remains subject to the existing MIDI/Nyquist rules. Errors are typed `SampleDescriptorError` cases for invalid slice/count, duration, overlap and jitter; no invalid value becomes a neutral descriptor.

Swift Testing proves region/slice declaration order, exact chop starts/durations, live/repeated event counts, count-one compatibility, full provenance/harmony/duck copying, descriptor replacement, file/bank admission, procedural rejection and checked preallocation failure. Renderer behavior and grain resource ownership belong to the MusicPlaygournd Rendering design.

### P06 oscillator and synthesis descriptors

P06.2 preserves existing `Waveform.sine`, `.square`, `.saw`, `.triangle`, `.noise` and `.sawtooth`, including their prior PCM paths. It adds `.bandLimitedSaw`, `.pulse(PulseWave)`, `.frequencyModulation(FrequencyModulation)`, `.coloredNoise(Noise)` and `.wavetable(Wavetable)`. `PulseWave.init(width:) throws` requires finite width strictly between zero and one. `FrequencyModulation.init(ratio:index:) throws` requires a finite positive modulator/carrier ratio and finite nonnegative phase-modulation index in radians; carrier and modulator are sine oscillators, so this bounded descriptor is not a recursive oscillator graph. `NoiseColor` is `.white`, `.pink` or `.brown`; `Noise` stores color and an explicit `UInt64 seed`. Existing `.noise` remains the prior deterministic white-noise seed/path for source compatibility.

`Wavetable.init(samples:) throws` owns an immutable one-cycle Float table with a power-of-two count in `2...4096` and finite normalized samples in `-1...1`; first and last entries are adjacent cyclic samples and no duplicate endpoint is required. The compiler retains the descriptor in SourceKind and does not resample, normalize or infer pitch. Invalid pulse/FM/table values use typed `SynthesizerDescriptorError` cases and never become sine, silence or a truncated table.

Existing `Unison(voices:detuneCents:)` and `.unison(_:)` are the public unison API. One voice is an exact bypass regardless of detune. For two or more voices the compiler retains 1...16 voices and finite nonnegative detune; the renderer places voice cents uniformly and symmetrically from `-detuneCents` through `+detuneCents`, all beginning at phase zero, and returns their arithmetic mean before the existing source Envelope/filter/gain/pan path. Unison is valid only for pitched sine, square, saw, band-limited saw, triangle, pulse, FM and wavetable synthesizers. White/colored noise and every Sample reject it as `unsupportedSourceSetting`, because detune has no pitched oscillator to vary.

All new synthesizers remain terminal immutable Sound values. Existing note, tuning, pitch offset/automation/envelope, harmony, portamento, voice policy, rhythm/provenance and render-graph contracts compose without a second pitch owner. Compiler validation keeps each unison-shifted effective MIDI value in 0...127; the renderer owns tuning/FM/Nyquist admission and alias/state/resource behavior. Swift Testing proves construction failures, exact retained descriptors, old case/source compatibility, one-voice bypass, symmetric cents, incompatible-source rejection and unchanged event/graph/provenance metadata.

The native decode, cache, traversal and error contract is owned by the renderer design. Failure retains the previously adopted loop. Built-in kick/snare/closedHat generation remains available only for their existing names and is never a fallback for a failed file or bank reference.

`VoicePolicy` is an optional immutable source setting: `.monophonic` is exactly a one-voice oldest-stealing policy, while `.polyphonic(limit: Int, stealing: VoiceStealing)` requires `1...SoundCompiler.Limits.maximumEvents`. `VoiceStealing` is `.oldest` or `.quietest`. `voicePolicy(_:)` replaces the policy on every source in its subtree; nil metadata preserves the current render-all-overlaps path byte for byte. `chokeGroup(_ name: String)` replaces an optional nonblank normalized group name and may intentionally join different sources. Applying either modifier to an empty subtree still validates its value.

Compiler output adds optional `CompiledSource.voicePolicy` and `chokeGroup`; neither changes, removes, copies or retimes `CompiledSoundEvent`, source/track identity, render nodes, rhythm/note provenance or the live recurrence period. Modifier order only replaces source policy metadata. Invalid limits/names are typed `SoundParameterError` failures. Public types are `Sendable`, `Equatable` and `Hashable`, and the additive signatures are `voicePolicy(_ policy: VoicePolicy)` and `chokeGroup(_ name: String) throws`.

At each event onset the native scheduler first terminates every older active voice in the same choke group, then applies the incoming source's voice limit. Oldest chooses the smallest true onset and then compiled event order. Quietest compares the active voice's actual instantaneous stereo magnitude immediately before the incoming onset after oscillator/sample traversal, filter, amplitude envelope, velocity, event gain and pan but before source mixing; it does not substitute velocity, age or envelope level as a proxy. Equal finite magnitudes use oldest then compiled order. Simultaneous events are admitted in compiled event order, so a later same-frame choke or limit decision may terminate an earlier one deterministically. Release and seamless-wrap portions remain active until their true audible asset/envelope horizon; a terminated voice never resumes in the next cycle.

Allocation changes PCM ownership only. The immutable compiled event list and its source anchor, pattern text and step index remain complete even when a voice is suppressed or terminated, so clients retain the exact declaration provenance. P03.4 does not reinterpret selection patterns, change musical extent, add per-note public handles or promise editor visualization of allocation decisions.
