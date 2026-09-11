# MusicalValues

## Purpose and Scope

Pitch, harmony, exact musical time, tempo conversion and scalar units. No children.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`Arpeggio`, `ArpeggioOrder`, `Chord`, `Decibels`, `Frequency`, `HarmonyError`, `Key`, `MusicalTime`, `MusicalTimeError`, `Pitch`, `PitchError`, `Scale`, `ScaleDegree`, `Semitones`, `Tempo`, `TempoError`, `Tuning`, `Voicing`.

## Related Designs

- Parent: [SwiftMusic](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../Tests/SwiftMusicTests).
- Related component: [SoundComposition](../SoundComposition/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Compilation](../Compilation/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [RenderPlan](../RenderPlan/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Performance](../Performance/DESIGN.md); shared SwiftMusic types retain their existing access levels.

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

### Exact time and rhythm

`MusicalTime` retains normalized non-negative `UInt64` rational storage and adds checked `multiplied(by: UInt64)` and `divided(by: UInt64)`. Multiplication throws overflow; zero division throws `MusicalTimeError.divisionByZero`. Successful results are exact.

`RhythmPattern` supports `ExpressibleByStringLiteral`. A literal retains its text until resolution and never traps on invalid input. Its `steps` getter preserves source compatibility by returning leaf values in depth-first source order. Explicit `init(_ value: String)` and `init(steps:)` validate eagerly and throw. Grammar is a nonempty ASCII-whitespace-separated sequence of `x`, `~`, or recursively nested `[ sequence ]` groups. Brackets are structural and are not leaves. A sequence divides its parent slot equally among its elements; a group occupies one such slot and recursively subdivides it. One internal parser emits each leaf's stable depth-first index and exact unit-cycle start/duration. Pattern source is bounded to 64 KiB UTF-8, 1,024 leaves, and nesting depth 32 before allocation or recursion; empty groups, unmatched brackets, invalid tokens, and exceeded bounds are typed failures. No other mini-notation operator is accepted. The modifier accepts `RhythmPattern`, with cycle defaulting to `.whole`.

`rhythm(pattern, cycle)` requires nonzero cycle and maps exact timed leaves into that cycle. Each hit clones each child event, adds its leaf onset, sets its leaf duration, and records its leaf index; rests emit nothing. Extent is at least the full cycle, preserving trailing rests. Nested modifiers apply inner-to-outer. `offset` adds to starts and extent. `repeated(count)` requires positive `Int`, copies the child sequentially at multiples of child extent, and multiplies extent. `fast` and `slow` require positive `UInt64` and divide or multiply starts, durations, and extent. Expansion and arithmetic are bounded before allocation.

Both pattern types provide `init(validating:)` to unambiguously request eager validation even for a literal argument. Swift may treat `RhythmPattern("...")` or `NotePattern("...")` as literal conversion rather than the throwing unlabeled String initializer. Use the labeled initializer at eager-validation boundaries. Literal equality compares retained source text; whitespace differences remain different declaration values even when they resolve to the same steps.

### Pitch, harmony, and expression

`NotePattern` uses the same bounded bracket structure and deferred/eager construction contract. Its throwing `steps` getter returns depth-first `[Pitch?]`, where nil is an explicit rest. Leaf tokens are `~` or scientific pitch names: A-G (case insensitive), optionally one ASCII `#` or `b`, followed by a decimal octave with optional minus sign. C4 is MIDI 60; enharmonic spellings resolve through the same arithmetic, and results must be 0...127. Structural, malformed-token, and out-of-range failures remain typed with leaf index or source offset where applicable. Numeric parsing rejects overflow rather than trapping.

`notes(_ pattern: NotePattern, cycle: MusicalTime = .whole)` maps exact timed leaves into the cycle. Each pitched leaf clones every child event, adds its onset, sets its leaf duration, replaces pitch, and records its leaf index. Rests clone no events; extent is at least the full cycle. Event limits are checked before expansion, and invalid patterns fail even on an empty subtree. Nested pattern modifiers expand inner-to-outer by these same rules.

`rhythm` and note-pattern overloads add defaulted `fileID: String = #fileID`, `line: Int = #line`, and `column: Int = #column` parameters without changing existing call syntax. They store a validated `SoundSourceAnchor` on every source in their subtree. Each emitted event also stores the zero-based lexical token index from the pattern expansion that owns the source anchor; rests emit no event. Nested pattern modifiers apply inner-to-outer, so the outermost pattern anchor and emitted step index win; other transforms preserve both. `CompiledSource.patternAnchor` remains present when a pattern emits only rests, and events resolve their row through `sourceID` rather than duplicating source provenance.

Pattern failures are exposed as `SoundCompilationError.invalidRhythm(RhythmPatternError)` and `.invalidNotes(NotePatternError)`. An unexpected thrown preparation error must remain an explicit failure (`unexpectedFailure(String)`), never a default sound.

`notes(_:)` requires a nonempty `[Pitch]` and assigns pitches cyclically in current event order. `transpose(_:)` requires pitched events and checked MIDI 0...127 results. `chord(_:)` requires pitched events and expands fixed intervals in order: `.major` = 0,4,7; `.minor` = 0,3,7; `.power` = 0,7; `.dominantSeventh` = 0,4,7,10. Expanded notes retain source, track, time, and expression.

`CompiledSoundEvent` exposes source ID, optional track ID, start, rhythmic duration, optional pitch, MIDI velocity, gate ratio, and an optional zero-based `patternStepIndex`. Rhythm and note-pattern expansion records the lexical token index for each emitted event; repeated, tempo, pitch, and other cloning transforms preserve it, while array-based `notes` clears it because no pattern text exists. Defaults are velocity 80 and gate 1. `Dynamic` maps `pp`, `p`, `mp`, `mf`, `f`, `ff` to documented fixed velocities. `dynamic` and `velocity` replace velocity; velocity requires 1...127. `gate` replaces gate and requires finite positive input. `staccato` multiplies current gate by 0.5. Expression never changes beat duration or extent.

## Key, Harmony, Articulation and Portamento

P05.5 adds typed harmony around the existing `Pitch`, `Semitones`, `Chord`, `PitchPattern` and effective-MIDI rules. `Scale` stores 1...12 finite `Semitones` within one octave, beginning at zero and strictly increasing below 12; its throwing `init(intervals:)` and built-ins `.chromatic`, `.major`, `.naturalMinor`, `.majorPentatonic` and `.minorPentatonic` are the sole scale authority. `Key` stores a `tonic: Pitch` and `scale: Scale`. `ScaleDegree` stores an `Int` where 1 is tonic, 2 is the next scale member, zero is the preceding member and negative values continue downward by Euclidean division. `Sound.notes(_ degrees: [ScaleDegree], in key: Key, fileID:line:column:)` requires a nonempty list and follows the existing array-notes event order/provenance contract: it replaces base pitch with the tonic, adds the exact degree/octave interval to the retained `pitchOffsetSemitones`, and validates the final fractional MIDI value in 0...127. Existing `transpose(Int)`, `transpose(PitchPattern,cycle:)` and pitch automation remain the only transposition APIs and compose in declaration order.

`Chord` retains its existing cases and adds a throwing `init(intervals: [Semitones])` bounded to 1...16 finite intervals. In 0.2 its public stored `intervals` changes from `[Int]` to `[Semitones]`; this is the intentional preview source break required to represent fractional harmony without truncation. Existing constants and `.chord(.major)`-style call sites keep the same musical values, while clients reading `intervals` must consume `Semitones.value`. Chord expansion splits each interval at its toward-zero integral component: that integer updates `event.pitch` through the existing transposition path, preserving built-in observable pitches, while the signed fractional remainder is added to `pitchOffsetSemitones`. The compiler validates the complete base-pitch-plus-offset result in 0...127, so no fractional value is discarded.

Chord and simultaneous NotePattern expansion assign snapshot-local `harmonyGroupID`, `harmonyOccurrenceID` and zero-based `harmonyVoiceIndex` on `CompiledSoundEvent`. A generator/repeat/live copy preserves the semantic group ID and voice index but assigns a fresh occurrence ID to each copied chord occurrence; all events copied from that one occurrence share it. Arpeggiation and its up-down copies preserve the occurrence ID even after their starts diverge. Harmony operations group by `(sourceID, harmonyGroupID, harmonyOccurrenceID)`, never by onset alone, so distinct repeated/live occurrences cannot merge and voicing or inversion declared after arpeggiation still sees the complete original chord. `Voicing` stores 1...16 signed octave offsets and `Sound.voicing(_:)` adds `12 * offset` to voices in declared group order, cycling the offset list. `Sound.inverted(_ count: Int)` accepts `-16...16`: each positive step moves the currently lowest effective voice up one octave and each negative step moves the highest down one octave, with stable event order breaking pitch ties. Both require a complete harmony occurrence, preserve event order, and validate every effective fractional MIDI result without clamping.

`Arpeggio` stores `order: ArpeggioOrder` and positive exact `step: MusicalTime`; order is `.asDeclared`, `.up`, `.down` or `.upDown`. `Sound.arpeggiated(_:)` operates independently on each simultaneous harmony group. It orders by effective pitch with declared voice index as the tie-breaker; up-down emits ascending then descending without duplicating either endpoint and checks expanded count before allocation. It offsets each output by `step * sequenceIndex`, preserves its full duration and other fields, and grows finite extent as needed. It creates no hidden recurrence: after a live generator it transforms one complete canonical group period, while later generators consume the arpeggiated template in normal inner-to-outer order.

`Legato` stores nonnegative exact `overlap: MusicalTime`; `init(overlap: MusicalTime = .zero)` is nonthrowing and `Sound.legato(_ value: Legato = Legato())` marks scoped events for final connection. After all event expansion and stable sorting, the compiler groups events into lanes by source and `harmonyVoiceIndex` (nil is lane zero), then partitions each lane into equal-onset clusters. Events in one cluster never succeed one another. For each cluster with a strictly later cluster it sets every member's gate so the audible gate end is exactly that next onset plus overlap, leaving rhythmic duration unchanged; zero or nonfinite derived gate fails. A finite lane's final cluster retains its prior gates. A live lane connects its final canonical cluster to the first cluster in the next recurrence, so articulation crosses the loop without retriggering or truncation. Legato preserves envelope release-anchor semantics and contributes no new period.

`PortamentoDuration` is `.seconds(Duration)` or `.beats(MusicalTime)` and must resolve to a finite positive duration. `Portamento` is a public `Sendable`, `Equatable`, `Hashable` descriptor with throwing `init(duration:)`; `Sound.portamento(_:)` is an outermost-wins source setting. The compiler retains it as `CompiledSource.portamento` and, after final pitch/order resolution, stores each event's optional `portamentoStartMIDINote: Double`. It uses the same source/harmony lanes and equal-onset clusters as legato: members of one cluster never precede each other, and each event uses the stable last event in the previous strictly earlier cluster. A finite first cluster has nil starts and no glide; a live first cluster uses the stable last event in the final canonical cluster of the preceding recurrence. The destination is the event's final base pitch plus onset-sampled offset. Later pitch-writing modifiers are validated before this final derivation, so metadata never becomes stale.

The native renderer supports portamento for pitched synthesizers and rooted file/bank samples. Over the declared physical seconds or BPM-resolved beats it linearly interpolates in semitone space from `portamentoStartMIDINote` to the event destination, then adds the existing continuous pitch automation and pitch-envelope offset before tuning/frequency conversion. Synth oscillator phase and decoded-sample traversal both use that same per-frame pitch; sample exhaustion analysis calls the identical increment path. Procedural named samples, white noise, missing pitch, a nonpositive/nonfinite resolved duration, effective pitch outside 0...127 or frequency outside Nyquist fail explicitly before successful PCM. Nil portamento retains the existing voice/sample arithmetic byte for byte.

All group and occurrence IDs are snapshot-local metadata and do not replace source anchors or lexical indices. Harmony expansion, occurrence reassignment, up-down duplication, legato linkage and live predecessor resolution obey existing event/rule limits, exact `MusicalTime` arithmetic and live-window duration bounds before allocation. Swift Testing proves scale degree mapping across negative/octave degrees, built-in/custom validation, existing transposition composition, fractional custom chord order and the documented `intervals` source break, voicing/inversion tie rules before and after arpeggiation, distinct repeated/live occurrence IDs and MIDI failures, every arpeggio order/extent/count bound, finite/live legato gates, harmony metadata/provenance and modifier-order counterexamples. Renderer fixtures measure oscillator and rooted-sample glide at start/mid/end, tempo-scaled beats, fixed seconds, pitch automation composition, sample exhaustion and unsupported-source failures; one evaluated harmonic live loop reaches native playback while invalid harmony/portamento retains the adopted revision.

### Rational addition boundary

`MusicalTime.adding` succeeds whenever the normalized sum fits UInt64 numerator and denominator storage. Cross-products use the standard UInt64 full-width operations (available on macOS 14); only the normalized result determines UInt64 overflow. With a shared denominator factor of at least two, both reduced denominator factors are at most UInt64.max / 2, so the sum fits 128 bits. With no shared factor, an overflowing 128-bit sum cannot be reduced and is an explicit overflow. No state, allocation, or platform-specific path is introduced. `MusicalTimeArithmeticTests` owns reducible intermediate, true overflow, zero, and fractional-grid checks. Compiler offset, repetition, and end-time consumers retain the same API and typed failure contract.
