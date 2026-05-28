# Research Capture Evaluation

How to decide whether research that happened during a planning, debate, or
investigation conversation is "too valuable to throw away" — and how to
capture it if so, in a way that future agents can find by topic.

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

## Naming convention (filename = content handle, not session record)

Research filenames are **content-addressable handles**. Future agents find
a topic by name; new findings on that topic ACCUMULATE into the same file
rather than spawning parallel session-named files.

Slug = 1-3 word content area, kebab-case. Names the *thing being studied*,
not the *event that produced the finding*. Examples:

| Original question / event | Session-derived slug (avoid) | Content-area slug (use) |
|---|---|---|
| "How should ADR-006 Phase 1 handle snapshot clone cost?" | `adr-006-plan-eng-review-triangulates` | `variable-store-snapshot-perf` |
| "Should we use `Arc<RwLock>` or `Arc<Mutex>` for the store?" | `a3-triangulate-decision` | `variable-store-concurrency` |
| "What's the FMI 3.0 variability schema mapping?" | `duet-plan-round-3-output` | `fmi-variability-mapping` |
| "Why is line routing producing duplicate segments?" | `line-routing-investigation-2026-05-16` | `line-routing` |

Sniff test: if the slug contains `triangulate`, `duet`, `session`, `plan-review`,
`investigation`, `decision`, a date, or any session/skill name — it's
session-derived; rename to the content area.

The slug names the topic-file. The topic-file is the **handle** for everything
captured about that topic, across all the sessions that ever touch it.

## Topic-overlap check (run before deriving a new slug)

Before writing a new research file, the agent MUST scan existing topic-files:

```bash
ls -1 "$RESEARCH_DIR"/*.md 2>/dev/null
```

For each existing file, read the first ~10 lines (frontmatter + H1 +
opening paragraph — enough to identify the topic without dragging in body
content). Then decide:

- **Strong overlap** — same topic, same scope → **append** to existing
  file under `## Decisions`.
- **Related but distinct** — overlapping concerns but a different topic →
  **new file** with a `## Cross-refs` entry linking to the related topic.
- **No overlap** — fresh content area → **new file**, content-area slug.

When unsure, default to **new file with cross-ref**. Cheap to migrate later
(combine two files); expensive to re-split a merged file. The agent's bias
should be toward correctly identifying overlap when present (don't spawn
parallel files on the same topic), but never force-merging when distinct.

Multiple overlap candidates: pick the strongest by content match; mention
the others in the AUQ option description (`also overlaps: <other-slug>`).

## Capture format

### Frontmatter

```yaml
---
status: unvalidated
origin-session: YYYY-MM-DD              # first capture; do NOT bump on append
target: validation
next-step: <one-line hint surfaced at /kick-off>
---
```

`status: validated` only when the conversation already confirmed the
findings (rare for byproduct research). `target: implementation` when the
research grades directly into actionable work without a separate
validation pass.

On append: leave frontmatter unchanged. `origin-session` tracks when the
topic-file was *created*; the dated subsection header inside `## Decisions`
tracks when each finding was added.

### Accumulating section structure (topic-file shape)

Topic-files use a stable top-level structure so appends have a clear home:

```markdown
# <topic name in prose, e.g. "Variable Store: snapshot performance">

## Decisions

### YYYY-MM-DD — <one-line summary of this finding>

<synthesis paragraph>

<details><summary>Voice positions / supporting detail</summary>

…

</details>

### YYYY-MM-DD — <next finding on the same topic>

…

## Open questions

- <question 1>
- <question 2>

## Cross-refs

- Related: [<other-topic>](./<other-topic>.md) — <one-line nature of the relation>
```

**Append rules:**

- Prepend new `### YYYY-MM-DD …` subsections at the **top** of `## Decisions`
  (newest first — the most recent finding is what a future reader needs first).
- If `## Decisions` doesn't exist, create it directly after the H1.
- Update `## Open questions` if the new finding resolves or adds questions.
- Update `## Cross-refs` if the new finding surfaces a related topic
  (one-way ref from this topic to the other; bidirectional maintenance is
  manual for now).
- **Never** rewrite or condense earlier `### YYYY-MM-DD` subsections —
  they're the audit trail. Append/prepend only.

### Per-decision internal structure

Inside each `### YYYY-MM-DD …` subsection, the recommended content (skip
any that don't apply — useful artifact, not filled-in template):

1. **Status line / scope** — investigator (Explore agent / triangulate /
   duet-plan / vanilla), what was inspected (read-only static / ran code /
   tested hypotheses), confidence level.
2. **Symptom or question** — the actual question this finding addresses.
3. **Hypothesis** — user's, agent's, or both. Capture both if they
   conflict; the conflict is often the most valuable signal.
4. **Current canonical diagnosis** — what existing docs say, if this
   finding is reconsidering them. Quote verbatim.
5. **Findings** — the synthesis. Uncertainty markers liberally. Name
   subproblems, support each with evidence.
6. **Key file refs** — table of relevant code locations (`file:line` form).
7. **Options / fix paths** — enumerated, each with cost + risk +
   when-it's-appropriate.
8. **Validation needed before action** — numbered experiments.
9. **Why this hypothesis is suspicious** — counterarguments, dead-ends.

The first decision-subsection establishes the topic; subsequent ones often
just need `(2) Symptom`, `(5) Findings`, `(8) Validation` — the topic
context carries over from prior subsections in the same file.

## Exit-prompt pattern (skills use this verbatim)

After the skill's main artifact is delivered, if the criteria above are
met, run the **Topic-overlap check** (above) and fire one `AskUserQuestion`
with the shape determined by the scan:

**When the scan returns ≥ 1 strong overlap candidate:**

> **Research capture.** The investigation behind this decision shows
> substantial shape (<signal summary — e.g., "multi-source breadth, three
> options with tradeoffs, validation plan identified">). It overlaps with
> existing topic `<overlap-slug>` (<one-line: why-it-overlaps>). Save how?

Options (single-select, max 4):

- **Append to `<overlap-slug>`** *(Recommended when overlap is strong)* —
  prepends a new `### YYYY-MM-DD` subsection to the existing file's
  `## Decisions`. (If multiple overlap candidates: append goes to the
  strongest; mention others in the description.)
- **Save as new research: `<content-area-slug>`** — creates a fresh
  topic-file with the accumulating structure. Add a cross-ref to
  `<overlap-slug>`.
- **Save as new plan** — writes to `$PLANS_DIR/<slug>.md` with `pending`
  status. Use when the synthesis is a directly-actionable decision, not
  open research.
- **Don't save** — synthesis lives in conversation memory only.

**When the scan returns no overlap candidates (or `$RESEARCH_DIR` is empty):**

> **Research capture.** The investigation behind this decision shows
> substantial shape (<signal summary>). Save to
> `$RESEARCH_DIR/<content-area-slug>.md`?

Options:

- **Save as new research** — writes the new topic-file.
- **Save as new plan** — writes to `$PLANS_DIR`.
- **Don't save** — conversation memory only.

Below-threshold research stays silent. No prompt, no mention. The
asymmetry is the point: easy to skip, easy to save, never ceremonial.

## Vanilla guidance

When the user is mid-conversation outside any koji skill and asks
something like "should we save this?" or "this seems valuable, where does
it go?", apply the same criteria above, run the **Topic-overlap check**,
and either:

- **Append** the new finding as a `### YYYY-MM-DD` subsection to an
  existing topic-file under `## Decisions`, OR
- **Write** a new content-area-named file with the accumulating structure.

The project's CLAUDE.md koji block points here for awareness — the agent
reads this reference, applies the criteria + naming + overlap discipline,
and either drafts the capture or explains why it's below threshold.
