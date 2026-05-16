# Gate Review Prompt (intermediate gates)

Used by `/duet-impl` at each intermediate gate (agent identifies gates from plan structure per `/duet-impl` SKILL.md "Gating Strategy"). The implementer's diff for that gate is reviewed by codex (single reviewer). The FINAL phase (cumulative diff at end of run) uses `/duet-review` instead — two reviewers + cross-review pass.

## Reviewer prompt

```
You are reviewing the implementation of one phase of a plan. You are the
SINGLE reviewer for this intermediate checkpoint. The phase is named:
"{gate_name}".

The diff below shows what the implementer did since the previous gate (or
since the start of work, if this is the first gate).

## Your job

Check:
- **Phase completeness** — did the implementer do the work the plan specified for THIS phase?
- **Scope overshoot** — did they do work meant for a LATER phase?
- **Scope undershoot** — did they skip required phase work?
- **Latent bugs** — would these changes cause problems downstream?
- **Correctness, security, data loss** in the changes themselves.

## Output — STRICT JSON ONLY

Return a single JSON array. No markdown fences, no preamble, no commentary.

Schema per entry (matches duet-review/references/reviewer-prompt.md):

{
  "fingerprint": "<file>:<line>:<category>",
  "severity": "high" | "medium" | "low",
  "category": "<one-of: correctness | security | perf | data-loss | error-handling | race | types | deps | deadcode | scope | style | other>",
  "file": "<relative-path>",
  "line": <integer>,
  "description": "<what is wrong, 1-3 sentences>",
  "suggested_fix": {
    "type": "mechanical" | "complex",
    "scope": "single-file" | "multi-file" | "conceptual",
    "details": "<what to change; code-level if mechanical>"
  }
}

Two extra categories vs the final-gate reviewer: `scope` (overshoot/undershoot
relative to the plan's intent for this phase). Use it when the work strays.

## Severity guide for gate reviews

- **high** — BLOCKS proceeding to the next gate. Correctness, security, data loss, or scope overshoot/undershoot that breaks the plan's phasing.
- **medium** — Notable but proceeding is OK. Add to gate-report; don't block.
- **low** — Skip unless directly relevant to this phase.

If you have no findings → return `[]`.

## Context

The plan text for this phase:
---
{phase_text}
---

The diff since the previous gate:
---
{diff}
---
```

## Implementer-side interpretation

`/duet-impl` parses the codex response:

- **No `high` findings** → PASS. Proceed to next gate.
- **`high` findings present, suggested_fix is mechanical** → apply fix, re-run codex review. Up to 2 retries.
- **`high` findings present, suggested_fix is complex/conceptual** → consult codex once for clarification, apply, re-run. If still failing after retry → escalate to user.
- **`medium` findings only** → log to gate-report, proceed.
- **`low` findings only** → ignore.

Per the [agent-autonomy principle](../../references/agent-autonomy.md), escalation to the user happens only when:
1. The 2-retry budget is exhausted AND
2. A consult round with codex did not resolve the disagreement.

Otherwise the implementer keeps trying.
