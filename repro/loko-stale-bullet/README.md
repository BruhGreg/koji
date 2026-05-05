# Repro: LOKO session-mention staleness + judgment auto-apply (Fix B + Fix C)

Reproduces the v0.4.8 ratchet — bullets covering active code paths and/or
exempt/untagged narrative docs continued to accumulate even after the
self-tagged temp-doc fix, because:

- Reactive's keep-on-touch overrode any judgment a doc was bibliographically dead (Issue 3a).
- Judgment-only removes were perma-advisory in auto mode (Issue 1).

Fix B adds session-mention staleness as a deterministic signal that
overrides the reactive keep. Fix C drops the asymmetric ratchet by
auto-applying judgment removes once a bullet has been in LOKO ≥ 2 wraps.

## Fixture contents

| File | Status | Reason in fixture |
|---|---|---|
| `agent-session.md` | session log | LOKO has 3 bullets initially; 2 active session entries, both about module-foo and both name-dropping `MODULE_FOO_REFERENCE.md` exactly |
| `MODULE_FOO_REFERENCE.md` | tagged active, mentioned in both sessions | should keep — `mentioned=yes` |
| `MODULE_BAR_GUIDE.md` | tagged active, NOT mentioned in any session body | Fix B target — covers paths touched but doc never referenced |
| `LEGACY_NOTES.md` | untagged narrative, NOT mentioned in any session body | Fix B target — exempts the default-keep bias |
| `FRESHLY_ADDED.md` | untagged narrative, added to LOKO only in wrap 2 (recent) | Fix C grace-period target — judgment off-theme should be advisory, not auto-removed |

Doc and subsystem names are generic placeholders, not project-specific.

**Important** — the session bodies do NOT name-drop docs that are
supposed to read as `mentioned=no`. The helper's mention check is a
literal `grep -F` for path or basename in any active session body, so
even a "we did not consult X.md" sentence would count. Real session
bodies typically don't list what wasn't used; this fixture mirrors that
convention.

## Expected helper output

After staging the fixture in two commits (see "How to run" below),
running:

```bash
koji-doc-status --loko-history
```

should emit (FRESHLY_ADDED.md added in the second commit, the others
present in both):

```
MODULE_FOO_REFERENCE.md	established	yes	2
MODULE_BAR_GUIDE.md	established	no	2
LEGACY_NOTES.md	established	no	2
FRESHLY_ADDED.md	recent	no	1
```

## Expected Pass C behavior under v0.4.9

- **MODULE_FOO_REFERENCE.md** — Reactive fires (covers `src/module-foo/`
  is touched), Pre-check 2 doesn't flag (`mentioned=yes`). **Keep.**
- **MODULE_BAR_GUIDE.md** — Reactive would normally keep (`src/module-bar/`
  is touched), but Pre-check 2 fires: `presence=established` +
  `mentioned=no` → **deterministic** remove, auto-applies. The reactive
  keep is explicitly overridden.
- **LEGACY_NOTES.md** — Default-keep bias would normally apply (untagged,
  manually pinned), but Pre-check 2 fires: `presence=established` +
  `mentioned=no` → **deterministic** remove, auto-applies.
- **FRESHLY_ADDED.md** — Judgment off-theme + `presence=recent` →
  **advisory** only. Listed in the proposal with `*!` markers; user can
  pin by leaving the bullet in place across the next wrap.

## Expected Pass C behavior under v0.4.8

- **MODULE_FOO_REFERENCE.md** — Keep. (Same.)
- **MODULE_BAR_GUIDE.md** — Reactive keeps it. **Bug — never removed.**
- **LEGACY_NOTES.md** — Default-keep bias. **Bug — never removed.**
- **FRESHLY_ADDED.md** — Same advisory-only behavior under both versions
  for new bullets; Fix C makes the grace explicit (`!` marker) without
  changing the auto-mode outcome here.

## How to run the repro by hand

There is no automated runner. To verify the helper:

1. Copy this directory into a throwaway repo:
   ```bash
   cp -r repro/loko-stale-bullet /tmp/repro && cd /tmp/repro
   ```
2. Drop FRESHLY_ADDED.md from the LOKO list temporarily (so wrap 1
   commits without it):
   ```bash
   cp agent-session.md /tmp/agent-session.full
   sed -i '' '/FRESHLY_ADDED/d' agent-session.md
   ```
3. Initial commit (this is wrap 1):
   ```bash
   git init -q && git add -A && git commit -q -m "wrap 1"
   ```
4. Restore FRESHLY_ADDED.md to LOKO and commit (this is wrap 2):
   ```bash
   cp /tmp/agent-session.full agent-session.md
   git commit -q -am "wrap 2"
   ```
5. Touch the covered code paths so tagged docs read as fresh, not orphan:
   ```bash
   mkdir -p src/module-foo src/module-bar
   touch src/module-foo/registry.go src/module-bar/handler.go
   git add -A && git commit -q -m "scaffold module dirs"
   ```
6. Run the helper:
   ```bash
   DOCS_PATH=. PROJECT_ROOT=. ~/.claude/skills/koji/bin/koji-doc-status --loko-history
   ```
7. Verify the table above. Then mentally walk Pass C against the output
   to predict what `/wrap` would propose. Or actually invoke `/wrap` from
   inside the repo if you want a live test.

## Why this fixture is here

Pairs with `repro/loko-temp-doc/` (Fix A coverage). Together they
exercise the three escape hatches Pass C now offers:

| Escape hatch | Repro fixture |
|---|---|
| Self-tagged temp marker (Fix A, v0.4.8) | `loko-temp-doc/` |
| Session-mention staleness (Fix B, v0.4.9) | `loko-stale-bullet/` |
| Judgment auto-apply with grace (Fix C, v0.4.9) | `loko-stale-bullet/` |

Future Pass C changes that touch this surface area should keep both
fixtures' expected behavior — the helper signals are stable contracts.
