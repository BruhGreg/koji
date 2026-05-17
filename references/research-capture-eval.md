# Research Capture Evaluation

How to decide whether research that happened during a planning, debate, or
investigation conversation is "too valuable to throw away" — and how to
capture it if so.

Consumed by `/duet-plan`, `/triangulate`, and (via the project's CLAUDE.md
pointer) vanilla prompts where investigation happens outside a koji skill.

## When to surface the capture option

Judgment-gated, not always-on. Surface only when **multiple** of these
signals hold — a single weak signal isn't enough:

- **Multi-source breadth** — investigation spanned 3+ files OR 2+ web
  sources OR mixed code-and-web. A single-file lookup is not research.
- **Problem model** — the synthesis articulates a *model* of the problem,
  not just an answer. Frames competing interpretations (user vs. canonical
  docs), names patterns, identifies subproblems.
- **Alternatives with tradeoffs** — multiple paths considered with cost +
  risk + applicability for each. Not a single recommended path.
- **Uncertainty preserved** — UNVALIDATED / UNTESTED / UNVERIFIED markers,
  "hypothesis", "needs profiling". The work captures what was assumed vs.
  what was confirmed.
- **Validation path** — concrete next steps to confirm or refute the
  findings, not just the findings themselves.
- **Captured pushback** — counterarguments, dead-ends considered, "why
  this hypothesis might be wrong" sections.
- **Cross-references to canonical docs** — engages with ROADMAP /
  ASSESSMENT / ARCHITECTURE rather than standing alone.

Stay silent — no prompt, no mention — when the research was:

- A single-file lookup or trivial fact check
- A point-answer with no model ("the answer is X at line Y")
- Fully resolved in-conversation (no remaining uncertainty)
- Specific to the immediate decision and not generalizable
- Already captured in the code, commits, or the plan that resulted

The calibration target is `.koji/research/line-routing-investigation.md`
(in the Simit project, as of 2026-05-16) — that's what "substantial" looks
like: ~150 lines, 9+ file refs, three options with tradeoffs, an explicit
validation plan, and a section on why the hypothesis might be wrong.

## Capture format

Write to `$RESEARCH_DIR/<slug>.md` with a kebab-case slug derived from the
topic. Auto-suffix on collision (`-2`, `-3`).

### Frontmatter

```yaml
---
status: unvalidated
origin-session: YYYY-MM-DD
target: validation
next-step: <one-line hint surfaced at /kick-off>
---
```

`status: validated` only when the conversation already confirmed the
findings (rare for byproduct research). `target: implementation` when the
research grades directly into actionable work without a separate
validation pass.

### Body

Recommended sections in order. Skip any that don't apply — the goal is a
useful artifact, not a filled-in template.

1. **Status blockquote at top** — one-line gate before canonical docs
   adopt the findings, origin session, investigator scope (e.g., "Explore
   agent on 2026-05-16. Read-only static analysis; did NOT run the code
   or test hypotheses"), validation target.
2. **The reported symptom** — the actual question or problem, in the
   user's framing if available.
3. **Hypothesis** — user's, agent's, or both. Capture both if they
   conflict; the conflict is often the most valuable signal.
4. **Current canonical diagnosis** — what existing docs say, if this
   research is reconsidering them. Quote verbatim.
5. **Investigation findings** — the synthesis. Use uncertainty markers
   liberally. Name subproblems, support each with evidence.
6. **Key file refs** — table of relevant code locations (`file:line` form).
   The reader picking this up later wants to jump straight to lines.
7. **Options / fix paths** — enumerated, each with cost + risk +
   when-it's-appropriate.
8. **Validation needed before action** — numbered experiments to confirm
   or refute. Anyone reading should know what to run next.
9. **Why this hypothesis is suspicious** — the pushback you'd give
   yourself. Counterarguments, dead-ends.
10. **Open questions** — what wasn't answered.
11. **Cross-references** — canonical docs engaged with.

## Exit-prompt pattern (skills use this verbatim)

After the skill's main artifact is delivered, if the criteria above are
met, fire one `AskUserQuestion`:

> **Research capture.** The investigation behind this decision shows
> substantial shape (<one-line summary of which signals fired — e.g.,
> "multi-source breadth, three options with tradeoffs, validation plan
> identified"). Save to `$RESEARCH_DIR/<suggested-slug>.md`?

Options:
- **Yes** — draft the file in the format above and write it.
- **Skip** — move on silently.

Below-threshold research stays silent. No prompt, no mention. The
asymmetry is the point: easy to skip, easy to save, never ceremonial.

## Vanilla guidance

When the user is mid-conversation outside any koji skill and asks
something like "should we save this?" or "this seems valuable, where does
it go?", apply the same criteria above and write to `$RESEARCH_DIR/<slug>.md`
in the same format. The project's CLAUDE.md koji block points here for
awareness — the agent reads this reference, applies the criteria, and
either drafts the capture or explains why it's below threshold.
