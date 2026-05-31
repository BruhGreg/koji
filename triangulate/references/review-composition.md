# /triangulate — composed with a review skill

How to run `/triangulate` **per finding** inside a finding-by-finding plan review
(`/plan-eng-review`, `/plan-devex-review`) so each architectural call is hardened by
cross-model debate before it's locked. koji-side only — the review skill (gstack's) is
never modified; you compose from the outside.

**Validated by hand** on a real ADR plan review: 6 findings triangulated, surfacing 3
codex concessions + 1 Claude concession that single-voice review missed; and (with the
red-team stage) 2 false-alarm findings refuted before they triggered an unnecessary
plan revision.

## When this applies

- The review surfaces **discrete findings one at a time** and asks you to decide each.
  True of `/plan-eng-review` (asks one issue per question, explicitly forbids batching)
  and `/plan-devex-review`.
- NOT holistic reviews — `/plan-ceo-review` (scope expansion) and `/plan-design-review`
  (dimension scoring) don't decompose into per-finding locks. Skip this for them.
- **Opt-in only.** The user asks for it (e.g. *"/plan-eng-review the locked plan with
  /triangulate"*). Never auto-trigger — the cost is real (see Cost guard).

## How it triggers and persists

The review skill is the primary workflow and runs **inline** (not a forked subagent), so
you — the main agent — see every finding it surfaces. Naming `/triangulate` in the
invocation does NOT pre-load it. Instead:

1. At the **first finding**, invoke `/triangulate` (Skill tool) for that finding. That
   loads `/triangulate` + this reference into context.
2. From there this guidance governs the remaining findings. Re-invoking `/triangulate`
   per finding reloads it — so the loop survives compaction on a long review.

## Keep-awake — once, around the whole review

Hold the outer keep-awake for the entire review so it doesn't flap off between findings:

```bash
~/.claude/skills/koji/bin/koji-keepawake start || true   # at the top of the composed review
# ... walk all findings ...
~/.claude/skills/koji/bin/koji-keepawake stop  || true   # after the last finding / red-team stage
```

Lone `/triangulate` is interactive and manages no keep-awake of its own, so this outer
bracket is the review's **only** keep-awake — it stays up across the whole finding walk and
is torn down exactly once, here. Self-cleaning and ownership-safe: it never touches a
caffeinate you started. (The helper is still reference-counted, so a concurrent koji run in
the same project shares this one hold rather than fighting it.)

## The per-finding loop

For each finding the review surfaces:

1. **Run the `/triangulate` engine** (SKILL.md Steps 1–4) on the finding's question +
   options. As you build each voice's Step-2 prompt, **prepend the big-picture lens block**
   (below). When a review section surfaces several findings at once, you MAY fan out —
   dispatch the Claude voices in parallel; codex calls serialize in one background bash
   (codex doesn't parallelize), so codex is the long pole.
2. **The engine's lock-AUQ is the decision gate.** It stands in for the review's own plain
   decision-prompt for that finding — but it's still one AUQ per finding, which is exactly
   what the review requires ("the path from finding to lock goes THROUGH AskUserQuestion").
   The user picks Lock / Another round / Abort as usual.
3. **Fold the locked synthesis into the plan** via the engine's Branch A (Step 5) — it
   already recognizes a `/plan-eng-review`-sourced question and appends to the plan doc
   without re-prompting.
4. **Return to the review's next finding.**

Stream per finding — do **not** gather all findings up front. The review's later questions
are often adaptive (a follow-up depends on your last answer), and the Outside Voice stage
spawns brand-new findings; gathering up front would lose both. Streaming also respects the
review's hard anti-batch rule.

## Voice-prompt addition — the big-picture lens

Add this to each voice prompt (Claude and codex), from finding #1. Derive the downstream
phases by reading the plan/ADR being reviewed (its roadmap / phases / future-work section):

```
BIG-PICTURE LENS: this plan ships in phases. Downstream phases (from the plan):
- <Phase / workstream name> — <one line: what it changes>
- <…enumerate the concrete, named downstream phases…>

Does any downstream phase ABSORB this decision (make today's call redundant) or FLIP it
(force a different shape)? Address this explicitly in your Reasoning.
```

Why: a question decided in isolation anchors on the current phase; the lens surfaces when a
later phase makes the call moot or reverses it. (On the reference run this was discovered
mid-review and retrofitted — bake it in from finding #1, not after a round.) Keep the rest
of the engine's voice template (Position / Reasoning / Tradeoffs / What I'd want the other
voice to defend) and the ≤40-line cap.

## Round 2 — the escape hatch that forces concessions

When voices diverge and the user picks "Another round," build each voice's round-2 prompt as:

- That voice's **round-1 output, verbatim**.
- The **other voice's round-1 output, verbatim**.
- The other voice's "what I'd want you to defend" line, promoted to an explicit
  **"ADVERSARIAL QUESTION FOR YOU: …"**.
- An orchestrator-authored **numbered crux list** specific to this disagreement.
- Always close with the escape hatch: **"Either (a) prove your position with a concrete
  scenario, (b) concede now and say so plainly, or (c) propose a new test that genuinely
  decides it. Be honest — if the other voice is right, say so."**

That explicit prove / concede / propose-new-test close is what produced the clean
concessions on the reference run; a generic "argue again" does not.

## Cost guard + cadence

- **Before dispatch**, show an estimate so the user opts in with eyes open:
  `N findings × 2 voices × ~R rounds at <effort>` → rough wallclock (codex runs serial at
  xhigh, up to ~30 min each in the worst case; usually faster) and a note that it's a
  substantial codex + Claude-Agent spend. This is a legitimate cost-safety prompt under
  [agent-autonomy.md](../../references/agent-autonomy.md) even though it isn't a technical
  question.
- **Between review sections**, fire one cadence AUQ: *Full-auto (triangulate every finding)
  / Lighter (only contentious ones) / Pause*. Lets the user throttle a long run.

## Optional final stage — red-team the Outside Voice

`/plan-eng-review` ends with an optional **"Outside Voice"** (a fresh AI challenges the
finished plan, producing N new findings). Pair it with an adversarial **red-team** that
tries to REFUTE each, so you don't act on confident-but-wrong findings.

Dispatch one fresh agent with the Outside Voice's findings verbatim + permission to read
the codebase. Per finding it outputs:

```
## Finding N
**Verdict:** SOLID | PARTIAL | REFUTED | UNCLEAR
**Claim:** <one-line restatement>
**Evidence checked:** <file:line — what the code actually says>
**Refutation attempt:** <strongest counter, or "couldn't refute">
**Final judgment:** <why, with file:line>
```

Stance: *"Try to REFUTE each finding. Don't accept a claim unless the evidence forces you
to."* Verdict → action:

- **SOLID** → fix; and if it's an architectural decision, triangulate it like any other finding.
- **PARTIAL** → route to `/duet-impl` as an absorption item.
- **REFUTED** → drop, no action.
- **UNCLEAR** → surface to the user.

On the reference run this refuted 2 of 12 Outside-Voice findings — including the largest,
which would otherwise have reverted a multi-round-locked decision.

## Write-back

- **Per finding:** the engine's Branch A fold-in already appends the synthesis + voice
  positions to the plan doc.
- **End of run:** append a short **summary block** to the plan — decisions locked (one line
  each), a cross-model concession summary (who conceded where), and a `/duet-impl`
  absorption list for PARTIAL/SOLID items routed forward. Voice positions accumulate into
  the research topic-file via the engine's append-to-topic-file path (Branch B).

## What this is NOT

No new skill, no `--from-file` flag, no auto-trigger. It is `/triangulate`'s existing engine,
looped per finding by you, under an explicit user opt-in, composing with a review skill koji
doesn't own.
