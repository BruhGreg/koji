# Promise Audit Prompt

Used by `/duet-impl` Step 3a (the cumulative promise audit, between the last gate review and the final `/duet-review`). One Agent (Claude subagent) reads the locked plan + cumulative diff and reports whether each EXPLICIT contract promise made by the plan has shipped.

The audit is contract verification, not quality review. Quality is `/duet-review`'s job — it judges whether the code is good. This audit asks a different question: **for every specific thing the plan said the code would do, did the code do it?** The two are different failure modes; the audit catches the kind that 6 reviewer passes miss (the kind that surfaced as Simit ADR-014: plan §2.8 promised an error kind that the implementation never emitted, and every reviewer read past the gap because they were judging code quality, not auditing the contract).

## Auditor prompt

```
You are auditing whether an implementation honored every EXPLICIT promise its
plan made. You are NOT reviewing code quality — that is a separate reviewer's
job. Your only job: extract every promise the plan declared as a behavioral
contract, then check the diff for evidence that each one shipped.

## What counts as a promise

A promise is a DECLARATIVE behavioral commitment the plan made about the
implementation. Examples (shape; not exhaustive):

- "emits error kind `wiring.invalid_output_index` when an output index is out of range"
- "validates the schema at the boundary of `parse_request`"
- "returns `null` when the input list is empty"
- "rejects requests with HTTP 422 when the body fails validation"
- "adds a `--retries` flag to the CLI"
- "logs a structured warning when the cache misses"
- "exposes `getUser` from the public API"

What does NOT count as a promise:

- Speculation: "we'll consider adding X later", "may extend to Y", "future work"
- Discussion of alternatives: "we considered Z but rejected it"
- Implementation notes that aren't behavioral: "use the existing helper", "refactor in passing"
- Things in the plan's "Out of scope" section
- Pure architecture description that doesn't commit to a specific surface

When in doubt, the test is: could a reviewer point at the diff and say "this
specific thing is missing" if the plan said it and the diff didn't have it?
If yes, it's a promise.

## How to find evidence

For each promise, search the diff for the implementation site:

- **Literal markers** (error kind strings, function names, flag names, route
  paths, log message templates): grep the diff for the exact string. If
  present in an added/changed line, that's strong evidence (high confidence).
- **Behavioral markers** (validation site, rejection path, return shape):
  read the relevant section of the diff and judge whether the code actually
  does the behavior. Cite the file:line that implements it.
- If you can't find evidence: mark as `GAP`. Don't speculate that "it might
  be in a file outside the diff" — the diff is the contract surface.

Confidence levels:

- `high` — literal marker present in the diff, exactly matching the promise.
- `medium` — behavior visibly implemented but not by the exact phrasing the
  plan used (paraphrase match).
- `low` — partial evidence; the promise might be honored but the diff is
  ambiguous. Surface as `low` rather than `GAP` so the reviewer can judge.

## Output — STRICT JSON ONLY

Return a single JSON array. No markdown fences, no preamble, no commentary.
If the plan made no extractable promises, return `[]`.

Schema per entry:

{
  "promise": "<one-sentence statement of what the plan promised>",
  "plan_location": "<section reference — e.g. '§2.8' or 'Steps step-4' or 'Approach para 3'>",
  "evidence": "<file>:<line> or short citation, OR the literal string \"GAP\" if not found",
  "confidence": "high" | "medium" | "low",
  "notes": "<optional one-line clarification — empty string if none>"
}

A GAP entry uses `evidence: "GAP"` and `confidence: "high"` ONLY when the
literal marker (error kind, function name, flag) was searched for and not
found in the diff. For behavioral GAPs (no exact marker to grep), use
`confidence: "medium"` to signal "I looked for the behavior and didn't see
it but a reviewer should double-check."

## Context

The locked plan:
---
{plan_text}
---

The cumulative diff since the plan started shipping ($START_SHA..HEAD):
---
{diff_text}
---
```

## `/duet-impl`-side interpretation

`/duet-impl` Step 3a writes the parsed JSON to `$RUN_DIR/promise-audit.json` and counts entries where `evidence == "GAP"` as the gap count surfaced in Step 6's report and Step 4's plan reconciliation blockquote.

Non-GAP entries (with `evidence: file:line`) are not surfaced by default — they confirm the audit ran and found honored promises, which is useful when debugging but noisy in the normal report. The JSON file holds them for inspection.

If JSON parsing fails or the agent times out, write `[]` and continue. The audit is a guardrail, not a gate — a flaky audit run should not block the final `/duet-review`.

## Why this is separate from gate reviews and `/duet-review`

| Pass | Job | Plan access | Output shape |
|---|---|---|---|
| Gate review (codex single, per gate) | Quality + phase completeness for the segment | Gate-text only | Severity-ranked findings |
| Final `/duet-review` | Quality of cumulative diff | NONE — diff only | Severity-ranked findings (claude + codex cross-reviewed) |
| **Promise audit** (this prompt) | **Contract verification — every explicit promise has evidence** | **Full locked plan** | **Per-promise binary: evidence or GAP** |

Folding the audit into either of the existing review prompts dilutes both jobs — quality review and contract verification have different shapes (severity vs binary), different scopes (per-diff vs per-promise), and different failure modes (missed bug vs missed contract). Keeping them separate keeps each prompt focused.
