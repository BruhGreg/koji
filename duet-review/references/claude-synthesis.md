# Claude-side angle synthesis (fan-out mode)

This is the spec for `/duet-review` **Step 2e**: the **main agent** consolidating the angle
reviewers' findings (fan-out mode) into ONE Claude finding-set written to `$RUN_DIR/claude.json`.

You (the main agent) do this **yourself — not via a subagent** — because you hold the diff and the
task intent in context, and because adjudicating disagreement and verifying against the code
requires that context. This is **judgment work, not a mechanical merge**: the downstream
synthesizer (`koji-duet-synthesize`) already does mechanical fingerprint dedup and bucketing; your
job is the part it cannot do.

## Input / output contract

- **Inputs:** `$RUN_DIR/angle-1.json … angle-5.json` ONLY — each a JSON array of findings in the
  `reviewer-prompt.md` schema (any may be `[]`). The diff is at `$DIFF_FILE`; have it in context.
  **Never read or pool `$RUN_DIR/codex.json` here.** codex is the B-side; the Step 3 synthesizer
  (`koji-duet-synthesize`) is the *only* place A and B meet. Folding codex into the A-side does two
  kinds of damage: it manufactures false consensus (codex findings exact-match themselves →
  spurious `agreed_by:[claude,codex]`), and that fake consensus then **suppresses cross-review** —
  consensus findings skip Step 4, so contaminating the A-side shrinks the reviewer-exclusive set
  that should have triggered it. Keep the A-side strictly the five angles.
- **Output:** ONE JSON array, in the **exact same per-finding schema**, written to
  `$RUN_DIR/claude.json` via the Write tool. `[]` is valid. Downstream strictly requires only
  `severity` and `category` per finding, but fill `fingerprint`, `file`, `line`, `description`, and
  `suggested_fix` whenever known — the richer the A-set, the better the cross-model synthesis.

This is the same file the single-pass path writes directly; once it exists, Steps 3–6 run unchanged.

## Rules (apply in order)

**A. Gather.** Read all five `angle-*.json`. Pool every finding; remember which angle each came from.

**B. Semantically dedup.** Merge findings that describe the **same underlying issue** even when
file, line, or wording differ — e.g. Angle 1 flags `foo.ts:42` and Angle 3 flags the caller
`bar.ts:88` for the same broken contract; that is ONE issue seen from two vantage points. Keep the
clearest description, the most actionable `suggested_fix`, and the most precise `file:line`
fingerprint. Note the corroboration (multiple angles → higher confidence). This is exactly what a
fingerprint-only dedup cannot do, and the reason a model performs this step.

**C. Treat disagreement as signal.** When one angle flags an issue and another angle's trace
**clears or contradicts** it (e.g. Angle 1 "missing null check" vs Angle 3's caller trace showing
the value is guaranteed non-null), do **not** silently drop either side. Re-examine the cited code
against the diff and adjudicate. If you genuinely cannot resolve it, **keep it at a lower severity**
rather than drop it — a contested finding the user can glance at beats a real bug silently removed.
(This is the class of bug — a stale placeholder advertising a removed cast — that surfaced in the
field only *because* two angles disagreed.)

**D. Verify against the diff.** For each surviving candidate, re-read the lines it cites and confirm
it is real. Drop confirmed false positives, pure speculation with no named trigger, and issues
already covered by tests in the diff. This folds `/code-review`'s confidence-scoring discipline into
your own judgment — deliberately **without** spawning per-candidate verifier subagents (that would
add cost and a nesting level; you already have the diff and context to verify in-head).

**E. Assign final severity + fix, then emit.** Set one authoritative `severity` per
`reviewer-prompt.md`'s guide and one coherent `suggested_fix {type, scope, details}` per finding.
When angles disagreed on severity, you decide — lean to the higher severity when a genuine ship
risk exists (matching the synthesizer's downstream max-severity-wins instinct). Pre-dedup by exact
`file:line:category` fingerprint for hygiene (the synthesizer also dedups, but don't rely on it).
Write the consolidated array to `$RUN_DIR/claude.json`. Confirm it parses as a JSON array.

## Non-goals / guardrails

- Don't re-run the review or invent findings no angle raised — you consolidate evidence already
  gathered.
- Don't collapse two genuinely distinct issues that happen to share a file.
- Don't let this become a sixth full pass — it is a consolidation, not a re-review.
- An empty result (`[]`) is a legitimate, honest outcome.

## Worked micro-example

Three raw findings in, two out:

```
IN (pooled from angles):
  [A1] correctness  src/parse.ts:42  "len compared with <=, off-by-one on last elem"
  [A3] correctness  src/parse.ts:41  "loop bound off by one; callers read one past end"   ← same bug, ±1 line
  [A1] error-handling src/io.ts:7    "fopen result unchecked → null deref"
  [A3] (trace)        src/io.ts:7    "caller already guards null before use"                ← contradicts A1
  [A4] perf           src/io.ts:30   "reads file twice; could cache"                        ← low-confidence guess

OUT (claude.json):
  correctness  high    src/parse.ts:42  "Off-by-one on the final element (len <= vs <); callers
                                          read one past the end." (merged A1+A3, B)
  error-handling medium src/io.ts:7     "Unchecked fopen result; the caller guard exists but is
                                          fragile to refactors — check at the source." (C: kept,
                                          downgraded high→medium after adjudication)
  # A4's perf guess dropped — re-read showed the second read is cached already (D).
```
