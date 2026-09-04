# koji

Repo-local memory layer for AI coding agents. Like a fermentation starter — seed any project with structured session continuity.

AI coding agents forget. Every new chat starts cold — yesterday's decisions, fixes, and gotchas don't survive. koji writes project state into plain markdown in your repo, so the next session (and the next agent) reads it and picks up where you left off.

Ten skills covering session lifecycle, doc-drift tracking, and adversarial cross-model planning/review. Pure bash + markdown, no build step.

## Install

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
```

## Quick Start

```bash
> /koji-init       # creates .koji/ + TODO.md, asks 2 setup questions
> /kick-off        # start a session (blank context first time)
... work, take notes ...
> /wrap            # writes session log + lessons + handoff, commits
```

Next day:

```bash
> /kick-off        # reads last session + handoff + focus-filtered lessons
... agent already knows yesterday's state, picks up where you left off ...
```

What gets written to your repo:

```
.koji/                       # session docs (committed)
├── agent-session.md
├── AI_HANDOFF.md
├── lessons.md
├── CODEBASE_CONVENTIONS.md
└── sessions/                # archive directory
TODO.md                      # task tracking
```

## Skills

**Session lifecycle**

| Skill | What it does |
|-------|-------------|
| `/koji-init` | Bootstrap: create docs scaffolding and `.koji.yaml` in any project |
| `/kick-off` | Start session: load handoff, lessons, last session. `/kick-off <focus>` for a custom direction |
| `/take-note` | Mid-session: save progress. `/take-note <note>` to skip the inference |
| `/wrap` | End session: update lessons + handoff + session log, archive, commit |
| `/inspect-doc-drift` | Audit docs tagged with `covers:` frontmatter for drift vs the code they describe |

**Duet workflow** — cross-model agent collaboration. The `duet` keyword is required to invoke; casual "let's plan" or "review this" will not trigger these.

| Skill | What it does |
|-------|-------------|
| `/duet-plan` | Multi-round Claude↔codex planning dialogue. Locks plan to `$DOCS_PATH/plans/<slug>.md` on consensus |
| `/duet-impl` | Walks a locked plan gate-by-gate, tracking progress as a task list. Implements each phase, gate-reviews at `<!-- gate: NAME -->` with the reviewer(s) your duet setup picked, runs `/duet-review` at the end |
| `/duet-review` | 2-reviewer adversarial code review. Claude + codex run in parallel as **background tasks** — keep working while they run — cross-review on disagreement, prompt to apply high-confidence fixes. Scopes `base..HEAD`, staged, or the uncommitted **working tree** |

All duet skills follow the [agent-autonomy principle](references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for deadlocks and policy choices.

**Triangulate** — user-as-participant cross-model decision.

| Skill | What it does |
|-------|-------------|
| `/triangulate` | Claude + codex argue in parallel on one question with web research per voice. You synthesize the call. Optional save to `.koji/plans/` or `.koji/research/`, or update an existing plan — picked conversationally based on what's active in the project |

Different shape from `/duet-*`: where the duet skills converge AI voices to consensus, `/triangulate` keeps **you** as a third reference point and the synthesizer.

**Plan hardening** — autonomous cross-model review of a locked plan (requires gstack and codex).

| Skill | What it does |
|-------|-------------|
| `/plan-triangulate-review` | Drives gstack's `/plan-eng-review` inline over a locked plan; triages each finding and runs a Claude↔codex debate only on the contentious ones (auto-locks on consensus, hard 3-round cap), then one erratum ratifies. Lean by design — not a fan-out. Invocation requires the `triangulate-review` intent (not bare `/triangulate`) |

## Configuration

`.koji.yaml` in your project root. All fields optional.

```yaml
docs_dir: .koji              # where session docs live
template: default            # "default" (full) or "simple" (minimal)
archive:
  strategy: numbered         # "numbered" (archive-NN.md) or "dated" (YYYY-MM/DD-slug.md)
  threshold: 5               # archive when this many sessions exist
  keep: 1                    # keep this many in the active file
agents:                      # tags for session entries
  - Claude
wrap:
  starter_prompt: true       # print a starter prompt for the next session
  commit_gate: auto          # auto = `npm run lint:check` if present | none | "<command>"
```

Global preferences (`commit_strategy` — `together` | `split` | `amend-if-same-session` —, `duet_setup` — the last duet setup you picked — and `auto_update`) live in `~/.config/koji/config.yaml`.

## Notable features

**Focus-filtered context at kick-off.** `/kick-off` doesn't dump everything — it pulls a wide-recall set of *candidate* lessons from `lessons.md` (anything matching your kick-off arg, last session's notes, or open TODOs, plus a recency baseline) and then judges which actually bear on the session, ignoring the noise. The relevance call is the agent's, not a bash keyword score. Tag entries `YYYY-MM-DD — [tag1,tag2] — …` to sharpen matching.

**Load on Kick-Off.** Add a `## Load on Kick-Off` section to `agent-session.md` listing docs to pull into context at session start. `/wrap` proposes adds/removes to keep it aligned with where the project is going — including active plans, which auto-flow into LOKO during their lifecycle and out again when they complete. See [`kick-off/SKILL.md`](kick-off/SKILL.md).

**Doc drift detection.** Tag any doc with `covers:` frontmatter listing the code paths it describes. `/kick-off` warns when covered paths have drifted past a commit threshold since the doc was last edited. `/inspect-doc-drift` audits the whole repo. Deterministic — no LLM needed.

**Wrap without prompts.** `/wrap` runs end-to-end with no prompts: adds apply, deterministic removes apply, judgment removes only once established, and the commit goes in with its message printed, never waited on. The one question it ever asks is how to commit (one commit, or code then docs), once per machine; the answer is saved. `wrap.commit_gate` runs your commit gate before `/wrap` commits — `auto` picks `npm run lint:check` when `package.json` has one; a failing gate never commits silently, and a missing gate is skipped, never fatal. `commit_strategy: amend-if-same-session` folds a docs-only wrap into your own unpushed same-session commit (`git commit --amend --trailer`, subject preserved) instead of trailing it with a `docs(koji)` commit.

**Duet workflow.** Cross-model agent collaboration that doesn't block the user. `/duet-plan` runs a multi-round Claude↔codex dialogue till consensus, locks the plan. `/duet-impl` walks the plan gate-by-gate with a gate review at each (who reviews is your duet setup, below), then audits the cumulative diff against every explicit promise the locked plan made — contract verification distinct from the quality reviews. `/duet-review` does a 2-reviewer adversarial pass with severity-aware cross-review on any reviewer-exclusive medium/high disagreement; a hard gate, a `-PRELIMINARY` verdict suffix, and a caller-side re-check under `/duet-impl` make sure the cross-review pass can't be silently skipped. All three run reviewers as background tasks — you can keep working while they progress; `/duet-impl`'s intermediate gates never block. `/duet-review`'s Claude side scales with the effort you pick: at `max` — or an explicit "full review" / "fan out" / "deep review" — it fans out into five angle reviewers (correctness, removed-behavior, cross-file, reuse, altitude) that the main agent consolidates into one finding set, while `xhigh` and `high` run a single holistic pass and "quick" / "save tokens" forces the single pass even at max.

**Duet setup.** Each duet run starts with one question: how to spend budget. Pick a reviewer strategy — `both` (Claude and codex both review every round and gate; at gates and in the final review they cross-review what they disagree on), `claude-then-codex` (a fresh-context Claude reviews every round and gate, and one codex call confirms each lock or pass), `codex` (codex reviews everything), or `claude` (no codex at all — same model family, weaker signal, the quota escape hatch) — plus an effort tier for both families (`max` / `xhigh` / `high`) and a Claude reviewer model. The pick is remembered, so the next run is one keystroke: reuse or change. Say it in the invocation phrase ("duet impl the oauth plan with both reviewers at max") and there is no question at all. Claude reviewers run at the effort you chose through the `koji-reviewer-*` agents that `setup` installs — always a fresh context, never a fork of the authoring session; codex runs at that `model_reasoning_effort`. Quota rule: when codex hits its limit (or fails to start) on a review that isn't the final one, koji substitutes a fresh-context Claude reviewer for that review and tries codex again on the next; only the final review waits for codex.

**Codebase fit.** The duet skills hold new code to *this project's* conventions — file structure, naming, idioms, layering — not just correctness. `/duet-plan` records a Codebase Fit Contract in every plan; `/duet-impl` gate reviews and `/duet-review` carry a `codebase-fit` lens. The shared reference is `CODEBASE_CONVENTIONS.md` in your koji docs dir: a hub that *points* (never copies) to the project's own convention docs — `CONTRIBUTING.md`, `AGENTS.md`, `.cursorrules`, a `STYLE.md` — via a `sources:` list, and accumulates a canonical-exemplar index plus a rejected-patterns log from what review actually catches. `/koji-init` scaffolds it for new projects; `/kick-off` backfills it into existing ones.

**Dead-code sweep.** `/duet-review` and `/duet-impl` gate reviewers actively flag code paths the diff makes unreachable — superseded helpers, dead branches, never-called arms — as `deadcode` findings. Carve-outs cover test scaffolding, generated files, and forward-compat / migration-bridge code so additive substrate phases pass cleanly. `/duet-impl`'s end-of-run report also surfaces a code-delta ratio (e.g. `+2310 / −267 (ratio 8.6:1)`) alongside the promise audit — a substrate-vs-refactor meta-signal that pairs with the deadcode findings.

**Triangulation (`/triangulate`).** When you want multi-side debate but YOU should be the synthesizer (not the agents): Claude + codex argue in parallel on one question with web research per voice, present their positions, and you weigh and decide. Optional save to `.koji/plans/` or `.koji/research/`, or append a synthesis section to an existing plan — picked conversationally based on what's active in the project. For *autonomous* per-finding hardening of a locked plan, that loop is now its own skill — **`/plan-triangulate-review`** (below); lone `/triangulate` stays a pure one-question engine.

**Plan hardening (`/plan-triangulate-review`).** Autonomous, lean cross-model hardening of a *locked* plan. Drives gstack's `/plan-eng-review` inline; per finding it triages — refute or record most by reading the source, debate only the genuinely contentious ones (Claude↔codex, auto-lock on consensus, hard 3-round cap). One end-of-run erratum ratifies the decisions, cross-model concessions, and anything still split. Invocation requires the `triangulate-review` intent (not bare `/triangulate`); requires gstack and codex. The reference run hardened a locked ADR in 4 model calls — a triage loop, not a fan-out.

**Walk-away sessions.** `/duet-plan`, `/duet-impl`, and `/plan-triangulate-review` keep the machine awake (`caffeinate` / `systemd-inhibit`) while their background AI dispatches run, then release it at the end, so you can start a long run and step away. (Lone `/triangulate` is interactive — it hands you each decision — so it skips keep-awake, like `/duet-review`.) Opt-in only (never plain `/kick-off`); reference-counted so overlapping runs share one keep-awake, and ownership-safe — a keep-awake you started yourself is never touched. `/duet-impl` is unattended-safe by design: it never freezes on a stuck gate. A gate that can't clear after its retries becomes a recorded deferral in `deferred-findings.md` — all surfaced at once on your return — and the walk continues, rather than blocking on a modal prompt. And a codex quota reply or start failure is never misread as "zero findings → pass": gates before the last substitute a fresh-context Claude reviewer and keep walking, and only the final `/duet-review` gate backs off (~15 min) and resumes within codex's 5-hour window — a depleted quota slows the walk, it never banks a silent false review.

**Plans + research working docs.** `.koji/plans/` (decided work, ready to implement) and `.koji/research/` (investigation findings, pending validation). Research files are topic-addressable — new findings accumulate into existing topic-files (`## Decisions` newest-first) rather than spawning parallel session-named files. Lightweight YAML frontmatter (`status:` field, kind-aware: pending/in-progress/completed/archived for plans, unvalidated/validated/archived for research). `/kick-off` surfaces pending entries; `/duet-impl` marks plans `completed` at end of run; `koji-plans-research --set-status <path> <new>` mutates from the command line, and `--set-next-step <path> "<text>"` rewrites the `next-step:` line; `/wrap` re-checks an active plan's `next-step` whenever the session touched that plan. Drift-exempt (not code-coverage docs).

## Deeper docs

The README is intentionally short. SKILL.md files have the details:
- [`kick-off/SKILL.md`](kick-off/SKILL.md), [`wrap/SKILL.md`](wrap/SKILL.md), [`take-note/SKILL.md`](take-note/SKILL.md), [`koji-init/SKILL.md`](koji-init/SKILL.md), [`inspect-doc-drift/SKILL.md`](inspect-doc-drift/SKILL.md)
- [`duet-plan/SKILL.md`](duet-plan/SKILL.md), [`duet-impl/SKILL.md`](duet-impl/SKILL.md), [`duet-review/SKILL.md`](duet-review/SKILL.md)
- [`triangulate/SKILL.md`](triangulate/SKILL.md) — Claude + codex + you = 3 reference points on one decision
- [`plan-triangulate-review/SKILL.md`](plan-triangulate-review/SKILL.md) — autonomous per-finding hardening of a locked plan (drives `/plan-eng-review` + per-finding debate)
- [`references/agent-autonomy.md`](references/agent-autonomy.md) — shared principle for the duet skills
- [`references/reviewer-backend.md`](references/reviewer-backend.md) — reviewer backend mapping, read-only clause, quota rule
- [`tests/run.sh`](tests/run.sh) — fixture runner for the bash helpers (`tests/run.sh [case]`); not an install gate

## FAQ

**Where do session docs live?** In each project's `.koji/` directory, committed to git. `~/.config/koji/` only stores global preferences.

**Why does `/kick-off` ask about a bypass key?** Older `/koji-init` versions wrote `permissions.defaultMode: bypassPermissions` into `.claude/settings.local.json`. Since Claude Code 2.1.257 that key is inert at project scope, so `/kick-off` offers to remove it, and `/wrap`'s permission hygiene now reads the effective mode from user and managed settings instead. koji never writes `~/.claude/settings.json`.

**Will `/koji-init` overwrite my existing docs?** No. If existing session files are found in `docs/`, koji asks whether to relocate or keep them. Content is preserved.

**Does it conflict with gstack?** No. Different skill names, designed to coexist.

**Does it phone home?** No telemetry, no analytics. All session data stays in your repo.

## Works With

- **Claude Code** (primary target)
- Any AI agent that reads markdown skill files

## License

MIT
