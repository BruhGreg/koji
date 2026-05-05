# Repro: LOKO temp-doc auto-prune (Fix A)

Reproduces the v0.4.6 bug where self-tagged temporary docs accumulated in
`## Load on Kick-Off` because Pass C's exempt/untagged default-keep bias
suppressed their removal indefinitely.

## Fixture contents

| File | Status | Reason in fixture |
|---|---|---|
| `agent-session.md` | session log | LOKO has 3 bullets; one session entry whose theme is `module-foo` with explicit "no phase-X work" next-session signal |
| `TEMP_PHASE_NOTES.md` | exempt + self-tagged temp | declares `covers: none`, opens with "**temporary** session working doc" + "gets archived or deleted" + "roll into" markers |
| `MODULE_REFERENCE.md` | tagged (`covers: src/module-foo/`) | covers active code touched this session — should keep |
| `ARCHITECTURE.md` | untagged, NOT temp | proves default-keep still applies to non-temp untagged pins |

Doc names are generic placeholders, not project-specific. Subsystem
names (`module-foo`, "phase X") are abstract scaffolding for the
walkthrough — substitute your own when reasoning about your project.

## Expected Pass C behavior under v0.4.8

Walk Pass C against the fixture. For each LOKO bullet:

- **MODULE_REFERENCE.md** — Reactive check fires (covers
  `src/module-foo/` and the session touched
  `src/module-foo/registry.<ext>`). **Keep.**
- **ARCHITECTURE.md** — untagged, NOT self-tagged temp, theme partially
  matches (module-foo is mentioned in the architecture overview).
  Default-keep bias applies. **Keep.**
- **TEMP_PHASE_NOTES.md** — exempt, but pre-check matches `temporary
  working doc` + `gets archived or deleted` + `roll into` (three
  markers, all word-boundary clean). Flagged as **self-tagged temp**.
  Theme check: next-session signal says "no phase-X work expected" →
  off-theme. Tagged as **deterministic** remove. **Auto-applies in
  non-interactive mode.** Only the LOKO bullet leaves; the file itself
  is untouched on disk.

## Expected Pass C behavior under v0.4.7 (the bug)

TEMP_PHASE_NOTES.md hits the exempt + manually-opted-in default-keep
bias and is never flagged for removal. The bullet survives every wrap
regardless of how many sessions go by without referencing it. This is
the ratchet.

## Negative-case coverage (word-boundary semantics)

Worth a manual sanity check that the marker matcher is NOT a naive
substring scan. Add a fourth doc to the fixture temporarily:

```markdown
# Permanent reference doc

This is a **non-temporary** working doc — kept long-term.
```

Word-boundary matching should NOT flag this as self-tagged temp.
"non-temporary" is not the marker `temporary working doc`. Same
applies to phrasings like "this is NOT a temp doc" or a quote block
discussing some other doc's lifecycle. If a future change accidentally
weakens the matcher to substring, this case will false-positive.

## How to run the repro by hand

There is no automated runner — koji's "tests" are real /wrap
invocations. To verify Fix A:

1. Copy this directory into a throwaway repo and `git init`.
2. Make one commit so HEAD exists.
3. Touch `src/module-foo/registry.<ext>` (create the file with any
   content), commit.
4. Run `/wrap` from inside that repo.
5. Observe Pass C's consolidated proposal. Under v0.4.8, the Remove
   block should list `TEMP_PHASE_NOTES.md` with reason `self-tagged
   temp ("gets archived or deleted"), off-theme`. Under v0.4.7 it
   should not appear.

## Why this fixture is here

Sets up surface area for Fix B + Fix C (separate PR). Those fixes will
add session-mention age tracking + remove the auto-apply asymmetry —
both will want to extend exactly this fixture (e.g., add a stub doc
that's been in LOKO ≥ 3 sessions but never mentioned, then verify the
B-tracking flags it).
