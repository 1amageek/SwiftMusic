# Audio Units

## Purpose and Scope
Native macOS discovery and document-state contracts for one hosted Audio Unit effect. Parent: [MusicPlaygourndCore](../DESIGN.md). It has no children. [Playback](../Playback/DESIGN.md) owns graph insertion. Instrument/generator hosting, custom plug-in UI, presets and plug-in authoring are outside this effect-host sprint.

## Responsibilities and Boundaries
This component owns stable component identity, bounded discovery, effect capability admission, typed host errors and portable binary property-list state. It does not render PCM, mutate transport or reinterpret SwiftMusic effects. Only components whose `componentType == kAudioUnitType_Effect` enter the host; an instrument, generator, music device or music effect fails `unsupportedComponentType` rather than appearing usable.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Native runtime boundary | Exposes DTOs and host protocol | macOS AVFAudio only |
| [Playback](../Playback/DESIGN.md) | used by | `AudioUnitHosting` | Owns the single graph slot | Selection never owns PCM |
| [App](../../../MusicPlaygourndApp/DESIGN.md) | used by | descriptors/state/snapshot | Persists explicit user selection | No plug-in custom UI in P06 |

## Architecture
```text
AVAudioUnitComponentManager -> bounded effect descriptors -> selected identifier
selected identifier + optional document state -> AVAudioUnit instantiate -> Playback slot
loaded AU fullStateForDocument <-> bounded binary property-list data
```

## Contracts and Invariants
`HostedAudioUnitID` stores UInt32 component type, subtype and manufacturer and converts losslessly to/from `AudioComponentDescription` with flags/mask zero. Its throwing initializer accepts only `kAudioUnitType_Effect`; every other type fails typed. `HostedAudioUnitDescriptor` stores ID, nonempty name/manufacturer name and UInt32 version. Discovery requests only effects, validates unique IDs and UTF-8 names no longer than 256 bytes, sorts by name, manufacturer, type/subtype/manufacturer values, and returns at most 256 entries; excess or duplicate identity is a typed failure, never truncation or aliasing.

`HostedAudioUnitState` stores exact component ID plus a binary property-list `Data` payload. Construction and decode require 1...1,048,576 bytes, a dictionary-root property list and only PropertyListSerialization-supported values. Restore requires exact selected identity. A unit with nil `fullStateForDocument`, invalid/non-property-list state or oversized serialization reports a typed state-unavailable/invalid-state error; selection remains usable without claiming persistence.

`HostedAudioUnitSnapshot` is `.none` or `.loaded(descriptor:bypassed:)`. Public `@MainActor AudioUnitHosting: AnyObject` provides `discoverAudioEffects() throws`, `selectAudioEffect(_:restoring:) async throws`, `clearAudioEffect() throws`, `setAudioEffectBypassed(_:) throws`, `captureAudioEffectState() throws`, and `audioEffectSnapshot()`. `AudioLoopEngine` is the native implementation. There is one slot and no implicit fallback component.

## Runtime Flows
```text
discover -> validate/sort -> explicit ID
ID -> instantiate candidate -> restore/format validation -> transactional Playback swap
loaded unit -> fullStateForDocument -> validate/serialize -> caller-owned state
```

## State, Ownership, and Lifecycle
Discovery returns values and retains no component instance. Playback retains the selected AVAudioUnit and descriptor on MainActor. One selection generation is current; a newer request supersedes an awaiting request, and a late stale candidate is released without graph attachment. The suspended selection operation retains its engine owner through native completion or the fixed 10-second timeout; external reference release is therefore bounded by that operation rather than guaranteed to invoke deinit immediately. The prior loaded unit remains graph owner until a candidate is fully instantiated, restored and admitted. Clear/shutdown detach and release on MainActor.

## Failure, Concurrency, and Constraints
Instantiation uses `AVAudioUnit.instantiate` with explicit default options and a fixed 10-second completion bound. Timeout, callback error/nil unit, stale selection, unsupported kind, missing component, throwing bus-format admission, invalid latency, state failure and AVAudioEngine start/restart failure are typed. Caller Task cancellation promptly cancels the request. The native completion retains only its request owner rather than the engine; after cancellation/timeout a late unit is released and cannot attach. After bus admission, attach/connect/prepare operate only on known-owned graph nodes and the admitted candidate; these Objective-C precondition operations are not claimed as catchable Swift failures. External plug-in execution is native third-party code under AVFAudio, so P06 makes no sandbox or Objective-C exception-isolation claim. All host and property access is MainActor; the audio callback receives only AVAudioEngine's established render graph.

## Verification and Change Impact
Swift Testing proves identifier round-trip and unsupported types, deterministic discovery/order/duplicate/excess/name bounds, state identity/property-list/size failures, nil state, selection supersession/timeout and late completion disposal. Playback owns actual graph/rollback/bypass/latency checks. A discovered Apple effect is instantiated and restored in the Release/native test; no third-party installation is required. Changes to the slot order or latency reverify Playback/MIDI clock; persisted state changes reverify App document integration.
