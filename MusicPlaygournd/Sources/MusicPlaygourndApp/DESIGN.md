# MusicPlaygourndApp

## Purpose and Scope
Executable module. Parent: [Package](../../DESIGN.md). Child: [Editor](Editor/DESIGN.md).

## Responsibilities and Boundaries
Composition root assembles Core and SwiftUI. No musical reinterpretation in UI.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
Editor -> SourceEvaluator -> AudioLoopEngine -> Editor snapshot
```

## Contracts and Invariants
App uses the same adopted metadata and latency-adjusted transport cursor for compiler-anchored player rows and active tokens. Native editor geometry and one shared vertical scroll position align both panes; the App never infers provenance from source text. Session evaluation renders at a fixed 120 BPM base. BPM and master low-pass/delay/reverb controls update playback live without starting evaluation or changing edit revision. Master waveform and spectrum consume actual bounded post-FX samples. Controls also own meter, transport, and documents. Swift 6.4 toolchain required.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Integration smoke test and visible native app verify the real workflow; command-line launch may use package source path, bundle launch uses embedded source workspace.
