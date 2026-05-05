---
covers:
  - src/module-foo/
---

# Module Foo Reference

Stable reference doc for the `module-foo` subsystem.

## Registry

State is held in a typed map keyed by an opaque ID. Insertion is
lock-free under the assumption that ID collisions are computationally
infeasible.

## Discovery

Local discovery first; falls back to a configured rendezvous endpoint if
the local probe yields no results within the configured timeout.
