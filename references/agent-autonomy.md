# Agent Autonomy Principle

Shared across all `/duet-*` skills. The duet skills execute autonomously. Humans see prompts only when agents cannot proceed on their own.

## Don't ask the human about

- **Technical correctness** — agents (Claude + codex) decide together. If one is uncertain, consult the OTHER agent first.
- **Planning details during dialogue rounds** — keep debating until consensus or until the round limit is hit. Don't bail out mid-round.
- **Implementation choices at a gate** — if codex flags an issue, fix-and-proceed is the default. Ask only if the fix would require user judgment.
- **Routine clarifications** that reading code, running tests, or checking the diff would answer. Read the code first.

## DO ask the human about

- **Deadlocked planning consensus** — after N rounds of debate, agents still disagree on a contested decision. Surface the disagreement summary, present both paths, ask which to take.
- **Implementation blind spot** — BOTH agents stuck on the same uncertainty after trying to resolve together. Examples: ambiguous intent in the spec, external API behavior neither can verify, judgment call about scope.
- **Policy decisions** — what to remember/apply/skip. These are user choices, not technical answers. Example: `/duet-review`'s 4-choice auto-apply prompt (Apply / Hold / Apply + remember for repo / Apply + remember for session).
- **Cost safety checks** — prompts that guard against runaway resource use (e.g., reviewing a 5000-line diff). Allowed even when no technical question exists. Keep these narrow and rare.

## How each duet skill implements this

### /duet-plan (Phase 3, future)

Multi-round Claude ↔ codex dialogue with consensus detection. Default round limit: 5. On deadlock, surface the disagreement summary with options to break the tie. Within rounds, agents debate freely without consulting the user.

### /duet-impl (Phase 2, future)

At each gate (foundation / mid / final), codex reviews. The implementer first tries fix-and-proceed. If unsure, consults codex with a clarifying question. Escalates to user only when both are stuck on the same blind spot.

### /duet-review (Phase 1, shipped v0.6.0)

- **Cross-review pass on CONTESTED** — when reviewers disagree, run one cross-review pass where each reviewer assesses the OTHER's findings. Only surface `CONTESTED` verdict to user when this pass didn't produce consensus.
- **4-choice auto-apply prompt** — policy choice (what to do with a confirmed-bug finding), not technical. Permitted under "policy decisions" above.
- **>5000-line diff confirmation** — cost guard, not technical. Permitted under "cost safety checks" above.

## Bottom line

Agents do their best to find solutions together. Humans see prompts only when:
1. The agents have genuinely tried and failed, OR
2. The question is not technical (policy / cost / scope choice).

If an agent finds itself reaching for `AskUserQuestion` for a technical issue, the first move should be: *can the other agent help resolve this?* — not *let me ask the user.*
