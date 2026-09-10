# RenderPlan

## Purpose and Scope

Compiled event, source, track and ordered render-node snapshots; no audio execution. No children.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`CompiledEventDuck`, `CompiledPlaybackMode`, `CompiledRenderNode`, `CompiledSound`, `CompiledSoundEvent`, `CompiledSource`, `CompiledTrack`, `SoundSourceAnchor`.

## Related Designs

- Parent: [SwiftMusic](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../Tests/SwiftMusicTests).
- Related component: [SoundComposition](../SoundComposition/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [MusicalValues](../MusicalValues/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Compilation](../Compilation/DESIGN.md); shared SwiftMusic types retain their existing access levels.
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
