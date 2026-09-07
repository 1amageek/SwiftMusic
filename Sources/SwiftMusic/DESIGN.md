# SwiftMusic Module

## Purpose and Scope

This module exports the declaration, compilation, and tempo-mapping API for SwiftMusic. Its parent is the [package design](../../DESIGN.md). Its only component is [`ScoreComposition`](ScoreComposition/DESIGN.md).

## Responsibilities and Boundaries

The module exposes the component contract as one coherent Swift API. It owns neither audio output nor editor presentation and adds no second representation of score timing.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`../../DESIGN.md`](../../DESIGN.md) | parent | package invariants | Defines package scope and client boundaries | Public API changes affect the package contract |
| [`ScoreComposition/DESIGN.md`](ScoreComposition/DESIGN.md) | child | declaration and compilation contract | Owns every production type in this foundation | Do not duplicate its score model in adapters |

## Architecture

```text
Music
  `-- score: some Score
          |
          v
     ScoreBuilder ----> package-owned composition nodes
          |                         |
          +---- custom Score.body --+
                                    v
                              ScoreCompiler
                                    |
                                    v
                              CompiledScore
                                    |
                                  Tempo
```

All production source belongs to `ScoreComposition/`; the module root contains only ecosystem-required composition files if one becomes necessary.

## Contracts and Invariants

- The module exports a single score model and a single compiler path.
- Public declaration values and compilation results are `Sendable` value types.
- The module does not expose internal primitive-dispatch hooks for client implementation.
- Tempo remains independent from `Music`, `Score`, and `CompiledScore`.

## Failure, Concurrency, and Constraints

The module preserves the component's typed failures and synchronous, reentrant behavior. It does not add fallback values or catch errors as success.

## Verification and Change Impact

The package test target exercises the public module through `import SwiftMusic`. Any new module-level adapter must depend on the public compiled-score contract rather than component internals and must update the package design.
