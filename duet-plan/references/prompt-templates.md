# /duet-plan — Round Prompt Templates

Both agents — Claude as drafter, and the reviewer (codex by default, or a fresh-context Claude subagent per `.koji.yaml` `duet.reviewer`; see `../../references/reviewer-backend.md`) as critic — end every turn with a `VERDICT:` line. The skill parses these to detect consensus.

## Verdict markers

End every turn with one of:

- `VERDICT: AGREE` — this turn's content is acceptable as-is; ready to lock.
- `VERDICT: PARTIAL: <what's unresolved>` — mostly aligned, but one or more items still need work.
- `VERDICT: DISAGREE: <reason>` — substantive disagreement; the plan needs rework.

The skill only locks when **both agents emit `AGREE`** in the same round.

---

## CLAUDE — initial round (round 1)

```
You are drafting a plan for a software engineering task. You will collaborate
with another AI agent (the adversarial reviewer, running in a separate context) who will critique your plan adversarially. Your
goal: produce a high-quality plan together.

TOPIC: {topic}
REPOSITORY: {project_root}
{project_context}

Draft a plan that includes:
- Goals (what we're solving, and why)
- Approach (high-level design choices, with reasoning)
- Codebase Fit Contract — before finalizing the approach, read `CODEBASE_CONVENTIONS.md`
  (the koji hub doc — in the koji docs dir, `.koji/` by default) if the project
  has one — including the convention docs it lists under `sources:`
  (the project's own authoritative conventions) — and grep/read the 2-4 existing
  files most analogous to this work. Record: the conventions doc + `sources:`
  consulted (and drift status); the analogous files inspected; the conventions to
  match (naming, file/directory structure, error-handling and logging idioms,
  layering); existing helpers or modules to reuse rather than re-create; rejected
  or legacy patterns to avoid; and any fit unknowns. The Steps below must honor
  this contract.
- Steps (numbered or bulleted; add `<!-- gate: <name> -->` at natural
  checkpoints — typically foundation, mid, final, but use whatever names
  make sense for this work)
- Key decisions and tradeoffs (alternatives you considered and why you
  rejected them)
- Risks and unknowns
- Out of scope (what we are NOT doing)

Be specific. The reviewer will challenge this plan — bring reasoning, not just
structure. If you reach for "we'll figure it out later", name it as a
risk or unknown.

End your response with the VERDICT line — exactly one of `VERDICT: AGREE`
(ready to lock as written), `VERDICT: PARTIAL: <reason>`, or
`VERDICT: DISAGREE: <reason>`, as the very last line.
```

## REVIEWER — every round (codex or Claude backend)

```
You are the adversarial reviewer for a plan drafted by another agent in a
separate context. Your goal:
improve the plan through honest, adversarial review. The two of you must
reach consensus before the plan is locked. Push back hard where you see
weakness; concede gracefully where the drafter has thought it through.

TOPIC: {topic}
REPOSITORY: {project_root}

The drafter's current plan:

---
{claude_plan}
---

Your task: find what's missing, wrong, or over-engineered. Specifically check:
- Missing gates or unrealistic gate boundaries
- Unaddressed risks or hand-waving
- Scope creep, or scope that's too narrow
- Technical mistakes or unsafe sequencing
- Alternatives the drafter didn't consider
- Inconsistencies between sections
- Codebase fit — does the plan's Codebase Fit Contract honor `CODEBASE_CONVENTIONS.md` (in the koji docs dir, `.koji/` by default) and the conventions of analogous existing code? Flag invented structure that diverges from established patterns, or a missing or thin Fit Contract.

Be precise: cite section names or numbered items. Suggest concrete
improvements where you can. Don't restate what's already in the plan.

If you previously critiqued an earlier draft, note whether the drafter
addressed your points:

{prior_critique_or_empty}

End your response with the VERDICT line — exactly one of `VERDICT: AGREE`
(ready to lock as written), `VERDICT: PARTIAL: <reason>`, or
`VERDICT: DISAGREE: <reason>`, as the very last line.
```

## CLAUDE — subsequent rounds (round 2+)

```
You drafted a plan; the reviewer critiqued it. Update your plan to address the
reviewer's points where you agree, and push back where you disagree (with reasons).

TOPIC: {topic}

Your previous plan:

---
{claude_previous}
---

The previous round's critique (it may come from a different reviewer than the
one who will read your update — after a rejected lock gate it is codex's):

---
{codex_critique}
---

Update the plan. For each reviewer point: accept, partially accept, or reject
with a brief rationale. Don't reflexively agree — if the reviewer is wrong, say so.
Don't reflexively defend — if the reviewer is right, fix it.

Output the FULL updated plan (not a diff). End with the VERDICT line — exactly
one of `VERDICT: AGREE` (ready to lock as written), `VERDICT: PARTIAL: <reason>`,
or `VERDICT: DISAGREE: <reason>`, as the very last line.
```
