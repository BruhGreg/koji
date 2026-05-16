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
  "cross_review_required": <bool>,
  "cross_review_done":     <bool>,
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

Each `<finding>` carries the reviewer-prompt.md schema plus synthesizer-added fields:
- `agreed_by` — array, e.g. `["claude","codex"]` or `["codex"]`
- `cross_review` (optional, when a cross-review verdict applied) — `{"by": "claude"|"codex", "verdict": "AGREE-HIGH"|"AGREE-MEDIUM"|"AGREE-LOW"|"DISAGREE"|"NEEDS-MORE-CONTEXT"}`
- `claude_severity` / `codex_severity` — original per-reviewer ratings, kept when severity was resolved by cross-review (so the user can see how it shifted)

## Cross-review flags

| Field | Meaning |
|---|---|
| `cross_review_required` | First-pass synthesizer sets `true` whenever ANY reviewer-exclusive finding has severity ≥ medium. Lows skip ("not a style committee"). |
| `cross_review_done`     | `false` after first-pass synthesis; `true` after re-synthesis with `--cross-review-done` (i.e., after Step 4 of `/duet-review` runs). |

**Hard gate.** `/duet-review` Step 5/6 refuse to run when `cross_review_required && !cross_review_done`. This is the structural fix for the v0.5.3-era "orchestrator skipped Step 4" failure mode — the synthesizer holds the state, the SKILL.md checks the state, the user never sees a stale verdict.

## Verdict semantics

| Verdict | Trigger | Exit code |
|---|---|---|
| `PASS` | No findings of any severity. | 0 |
| `PASS-WITH-NOTES` | No `high`, but medium/low present. | 0 |
| `REJECT` | ≥1 `high` finding where both reviewers agreed — first-pass fingerprint match OR cross-review AGREE-HIGH promotion. | 1 |
| `CONTESTED` | ≥1 `high` finding still reviewer-exclusive after cross-review (or before, if cross-review hasn't run yet). | 2 |

**Cross-review can flip the verdict** in either direction:
- A first-pass solo medium can be promoted to a high-consensus finding (medium → `AGREE-HIGH` → REJECT).
- A first-pass solo high can be resolved to medium-consensus (high → `AGREE-MEDIUM` → PASS-WITH-NOTES).
- A first-pass solo high can be rejected by the other reviewer (`DISAGREE`) and stay solo, keeping the verdict CONTESTED.

## For callers (e.g., /duet-impl)

- `exit_code=0` → proceed to ship.
- `exit_code=1` → block. Surface findings to user. Re-run `/duet-review` after fixes.
- `exit_code=2` → unresolved disagreement. Require explicit user decision before proceeding.

## Auto-apply tracking

- `auto_applied` — fixes the skill applied (silent-rule match OR user picked "Apply"/"Apply+remember…").
- `user_held` — high-consensus findings where the user picked "Hold" in the 4-choice prompt.
- `reported_only` — everything else (medium/low, high-contested findings, non-mechanical fixes).
