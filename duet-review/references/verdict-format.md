# Verdict Format

`/duet-review` produces a JSON verdict file consumed by `/duet-impl` (Phase 2 of Bucket 3) and printed in a markdown summary for the user.

## Output path

```
$RUN_DIR/verdict.json
```
where `$RUN_DIR` is the per-invocation temp dir (mktemp -d). The path is printed at end of run.

## Schema

```
{
  "verdict": "PASS" | "PASS-WITH-NOTES" | "REJECT" | "CONTESTED",
  "base": "<base-ref>",
  "head": "<head-sha>",
  "reviewers": ["claude", "codex"],
  "totals": {
    "high_consensus": <int>,
    "high_contested": <int>,
    "medium": <int>,
    "low": <int>
  },
  "high_consensus":  [ <finding>, ... ],
  "high_contested":  [ <finding>, ... ],
  "medium":          [ <finding>, ... ],
  "low":             [ <finding>, ... ],
  "auto_applied":    [ <finding>, ... ],
  "user_held":       [ <finding>, ... ],
  "reported_only":   [ <finding>, ... ],
  "exit_code": 0 | 1 | 2
}
```

Each `<finding>` carries the reviewer-prompt.md schema plus a synthesizer-added `agreed_by` array (e.g., `["claude","codex"]` or `["codex"]`).

## Verdict semantics

| Verdict | Trigger | Exit code |
|---|---|---|
| `PASS` | No findings of any severity. | 0 |
| `PASS-WITH-NOTES` | No `high`, but medium/low present. | 0 |
| `REJECT` | ≥1 `high` finding where both reviewers agreed (same fingerprint). | 1 |
| `CONTESTED` | ≥1 `high` finding, but no fingerprint overlap between reviewers. Triggers cross-review pass; if still no overlap, verdict stays CONTESTED. | 2 |

## For callers (e.g., /duet-impl)

- `exit_code=0` → proceed to ship.
- `exit_code=1` → block. Surface findings to user. Re-run `/duet-review` after fixes.
- `exit_code=2` → unresolved disagreement. Require explicit user decision before proceeding.

## Auto-apply tracking

- `auto_applied` — fixes the skill applied (silent-rule match OR user picked "Apply"/"Apply+remember…").
- `user_held` — high-consensus findings where the user picked "Hold" in the 4-choice prompt.
- `reported_only` — everything else (medium/low, high-contested findings, non-mechanical fixes).
