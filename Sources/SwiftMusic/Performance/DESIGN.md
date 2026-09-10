# Performance

## Purpose and Scope

Declaration-local State, injected models and typed performance controls. No children.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`Performance`, `PerformanceControlDescriptor`, `PerformanceControlDomain`, `PerformanceControlError`, `PerformanceControlMetadata`, `PerformanceControlRole`, `PerformanceControlSet`, `PerformanceControlValue`, `PerformanceControllable`, `PerformanceEntry`, `PerformanceMusic`, `PerformanceRequirement`, `PerformanceRequirementProviding`, `PerformanceScope`, `State`.

## Related Designs

- Parent: [SwiftMusic](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../Tests/SwiftMusicTests).
- Related component: [SoundComposition](../SoundComposition/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [MusicalValues](../MusicalValues/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Compilation](../Compilation/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [RenderPlan](../RenderPlan/DESIGN.md); shared SwiftMusic types retain their existing access levels.

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

### Declaration-local State

`SwiftMusic.State<Value: Sendable>` is a MainActor-isolated, native-Observation property-wrapper class whose `wrappedValue` owns a declaration-local value and whose `projectedValue` returns that same State reference. A nonisolated wrapped-value initializer admits ordinary Session construction; all subsequent reads/writes are MainActor-isolated. Copying a Session preserves State identity. The implementation imports Observation, not SwiftUI; clients importing both frameworks qualify the wrapper as `@SwiftMusic.State`.

The owner that retains the initial Session determines its State lifetime. Repeated body evaluation reads the same value; switch evaluation does not own or initialize state. Immutable compiled Sound/PCM snapshots contain resolved values and never access State from an audio callback. State supplies neither persistence, generalized Binding nor an autonomous evaluation loop. `@Performance` remains explicit injection of an external Observable model and is not replaced by local State. `State(wrappedValue:)` creates independent storage; the host decides when to retain or reconstruct declarations. `SoundCompositionTests.localStateRetainsIdentityAndChangesCompiledBranch` verifies shared reference identity, independent initialization, Observation notification and the actual SoundCompiler branch selected after mutation. Qualified SwiftUI.State and SwiftMusic.State declarations may coexist in the same client; host audio switching is verified separately.

## Main-actor performance models

`Music` remains `Sendable`, while its `body` requirement becomes `@MainActor`; `Sound`, every terminal and modifier value, and every compiled result remain immutable nonisolated `Sendable` values. `@Performance(Model.self)` accepts an exact `Model: AnyObject & Observation.Observable & Sendable` type and stores only that type requirement. It never constructs a model, stores a fallback, or turns absence into a valid value. Its nonoptional `wrappedValue` resolves only inside the framework's validated body-evaluation scope.

`@MainActor Music.performance(_ model:)` returns terminal `PerformanceMusic<Base>`, which retains the explicitly supplied model without becoming a `Sound` or another freely composable `Music`. Additional `.performance(_:)` calls add providers; the outermost, most recently applied provider wins for the same exact model type, immediately releases the replaced instance when otherwise unowned, and unused providers are allowed. Every public `SoundCompiler` overload taking `Music` or `PerformanceMusic` is `@MainActor` and performs requirement resolution before reading `body`. Retained distinct exact model types and requirements are each bounded to 1,024 before body access; repeated applications replacing one retained exact type do not accumulate history and therefore do not consume additional provider capacity. A missing exact provider, an exceeded bound, an invalid requirement declaration, or a `CustomReflectable` declaration that hides wrappers without the explicit `PerformanceRequirementProviding` list is a typed `SoundCompilationError`; body is not evaluated and no partial sound is returned. Ordinary reflection streams direct stored wrappers and superclass mirrors to a maximum depth of 64 without recursively reflecting arbitrary model state. Accessing an unresolved wrapper by directly evaluating `Music.body` outside a supported compiler/update/observation entry violates the public programmer precondition and stops, matching existing compiler-terminal body preconditions; it is never a supported failure path or silent model default.

For an Editor-created model, optional `@MainActor PerformanceEntry: Music` declares `associatedtype PerformanceModel: AnyObject & Observation.Observable & Sendable` and `static func makePerformanceModel() -> PerformanceModel`. The factory is the only automatic construction authority; there is no `init()` requirement or reflective constructor. A native caller may always provide its own instance with `.performance(instance)`, which takes precedence over the factory path.

The optional `@MainActor PerformanceControllable` model contract exposes a nonempty stable UTF-8 `performanceModelID` and throwing `var performanceControls: PerformanceControlSet<Self> { get throws }`; malformed computed mappings propagate their typed error instead of requiring `try!`, a hidden fallback or lazy failure. The initial bounded value domains are finite `Double` and finite `SpatialPosition(x:depth:)`. A number descriptor has a nonempty stable UTF-8 control ID, closed admission range and `.scalar` or `.beatsPerMinute` role; a position descriptor has one stable control ID and finite closed x/depth ranges, so an XY update is one atomic value and the UI's vertical axis maps to `depth`. Model/control ID pairs and writable key paths must each be unique, and the complete resolved performance catalog may contain at most one `.beatsPerMinute` control because it owns the single shared render clock. Duplicate identities, key paths or BPM roles, nonfinite values/ranges, reversed ranges, a value outside its range, or a malformed mapping fail with typed `PerformanceControlError` before mutation. A mapped key path must address an independent stored field or a semantically equivalent reversible setter: complete-set rollback restores every mapped value, but cannot promise to reverse unrelated side effects performed by an arbitrary computed setter. Descriptors retain `ReferenceWritableKeyPath` only in the owning MainActor process and are never encoded. Wire metadata contains the stable model/control IDs, domain, role, ranges and current value and remains subject to the existing 1 MiB worker-frame bound. Models without this optional conformance still support in-process Observation/body reevaluation but expose no inferred Editor controls. `PerformanceControlMetadata.validate(_:)` validates a decoded complete single-model catalog with the same ID, domain, value, BPM and 1,024-control admission rules before a host exposes it. Labels preserve the native mapping contract, including explicitly empty labels. The worker connection test proves malformed metadata fails before ready publication; `PerformanceControlTests` covers valid native metadata and invalid decoded catalogs.

`SpatialPosition` is a `Sendable`, `Codable`, `Hashable` value whose `x` is normalized stereo position in `-1...1` and whose `depth` is normalized stylized depth in `0...1`; it is not a physical-distance or 3D-audio claim. `Sound.position(_:)` validates both finite coordinates and lowers at that declaration point, in order, to the existing equal-power pan with `x`, gain `pow(10, (-6 * depth) / 20)`, a low-pass effect with logarithmic cutoff `20_000 * pow(4_000 / 20_000, depth)` and Q `1 / sqrt(2)`, then reverb with room size `0.5 + 0.5 * depth` and wet `0.35 * depth`. At `depth == 0`, gain is exactly one and the filter/reverb stages are bypassed rather than approximated; pan retains the existing explicit-pan law, including its defined center value. The resulting ordinary render nodes retain modifier order, bounds, live recurrence, source/Track identity and provenance. Position replacement is an atomic recomputation of this complete lowering, so no stale axis or derived node survives. P05.7 controls may address the resulting graph values, but they do not own the performance-model position or its cross-process state.

Compiler tests prove the accepted nonoptional declaration and explicit injection, same-type precedence, unused providers, missing-provider failure before body, custom-reflection admission, MainActor isolation, ordinary Music compatibility and unchanged Sound compilation. Control tests prove number/BPM/position admission, exact position lowering at near/far/left/right values, atomic position mutation, duplicate identity/BPM-role/type/range failures and that no SwiftUI module is linked. Native PCM tests prove the declared pan, attenuation, low-pass and reverb changes are audible while `depth == 0` does not add filter/reverb processing.
