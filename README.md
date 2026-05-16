# koji

Session management for AI coding agents. Like a fermentation starter — seed any project with structured session continuity.

koji gives your AI agent a memory across sessions: lessons learned, project state handoffs, and session logs with automatic archiving. Nine skills, one install. Pure bash + markdown, no build step.

## Install

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
```

## Skills

**Session lifecycle**

| Skill | What it does |
|-------|-------------|
| `/koji-init` | Bootstrap: create docs scaffolding and `.koji.yaml` in any project |
| `/kick-off` | Start session: load handoff, lessons, last session. `/kick-off <focus>` for a custom direction |
| `/take-note` | Mid-session: save progress. `/take-note <note>` to skip the inference |
| `/wrap` | End session: update lessons + handoff + session log, archive, propose commit |
| `/inspect-doc-drift` | Audit docs tagged with `covers:` frontmatter for drift vs the code they describe |

**Duet workflow** — cross-model agent collaboration. The `duet` keyword is required to invoke; casual "let's plan" or "review this" will not trigger these.

| Skill | What it does |
|-------|-------------|
| `/duet-plan` | Multi-round Claude↔codex planning dialogue. Locks plan to `$DOCS_PATH/plans/<slug>.md` on consensus |
| `/duet-impl` | Walks a locked plan gate-by-gate. Implements each phase, codex single-reviews at `<!-- gate: NAME -->`, runs `/duet-review` at the end |
| `/duet-review` | 2-reviewer adversarial code review. Claude + codex run in parallel as **background tasks** — keep working while they run — cross-review on disagreement, prompt to apply high-confidence fixes |

All duet skills follow the [agent-autonomy principle](references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for deadlocks and policy choices.

**Triangulate** — user-as-participant cross-model decision.

| Skill | What it does |
|-------|-------------|
| `/triangulate` | Claude + codex argue in parallel on one question with web research per voice. You synthesize the call. Optional save to `.koji/plans/` or `.koji/research/`, or update an existing plan — picked conversationally based on what's active in the project |

Different shape from `/duet-*`: where the duet skills converge AI voices to consensus, `/triangulate` keeps **you** as a third reference point and the synthesizer.

## Quick Start

```
> /koji-init
```

Asks two questions (template + archive strategy), then creates:

```
.koji/                  # session docs
├── agent-session.md    # session history
├── AI_HANDOFF.md       # project state for next agent
├── lessons.md          # corrections and gotchas
└── sessions/           # archive directory
TODO.md                 # task tracking (created by /wrap on first use)
```

Use `/kick-off` to start a session, `/wrap` to end one, `/take-note` mid-session.

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
```

Global preferences (`commit_strategy`, `auto_update`) live in `~/.config/koji/config.yaml`.

## Notable features

**Focus-filtered context at kick-off.** `/kick-off` doesn't dump everything — it loads a focus-filtered subset of `lessons.md` matched against your kick-off arg, last session's notes, open TODO items, plus a top-3 recency baseline. Tag entries `YYYY-MM-DD — [tag1,tag2] — …` to sharpen matching.

**Load on Kick-Off.** Add a `## Load on Kick-Off` section to `agent-session.md` listing docs to pull into context at session start. `/wrap` proposes adds/removes to keep it aligned with where the project is going. See [`kick-off/SKILL.md`](kick-off/SKILL.md).

**Doc drift detection.** Tag any doc with `covers:` frontmatter listing the code paths it describes. `/kick-off` warns when covered paths have drifted past a commit threshold since the doc was last edited. `/inspect-doc-drift` audits the whole repo. Deterministic — no LLM needed.

**Duet workflow.** Cross-model agent collaboration that doesn't block the user. `/duet-plan` runs a multi-round Claude↔codex dialogue till consensus, locks the plan. `/duet-impl` walks the plan gate-by-gate with codex review at each. `/duet-review` does a 2-reviewer adversarial pass with severity-aware cross-review on any reviewer-exclusive medium/high disagreement; a hard gate plus `-PRELIMINARY` verdict suffix make sure the cross-review pass can't be silently skipped. All three run reviewers as background tasks — you can keep working while they progress. Codex defaults to `xhigh` effort; opt down with a natural-language signal in the invocation phrase.

**Triangulation (`/triangulate`).** When you want multi-side debate but YOU should be the synthesizer (not the agents): Claude + codex argue in parallel on one question with web research per voice, present their positions, and you weigh and decide. Optional save to `.koji/plans/` or `.koji/research/`, or append a synthesis section to an existing plan — picked conversationally based on what's active in the project.

**Plans + research working docs.** `.koji/plans/` (decided work, ready to implement) and `.koji/research/` (investigation findings, pending validation). Lightweight YAML frontmatter (`status:` field, kind-aware: pending/in-progress/completed/archived for plans, unvalidated/validated/archived for research). `/kick-off` surfaces pending entries; `/wrap` offers status updates for touched files and asks once per session whether to capture a new entry. `koji-plans-research --set-status <path> <new>` mutates from the command line. Drift-exempt (not code-coverage docs).

## Deeper docs

The README is intentionally short. SKILL.md files have the details:
- [`kick-off/SKILL.md`](kick-off/SKILL.md), [`wrap/SKILL.md`](wrap/SKILL.md), [`take-note/SKILL.md`](take-note/SKILL.md), [`koji-init/SKILL.md`](koji-init/SKILL.md), [`inspect-doc-drift/SKILL.md`](inspect-doc-drift/SKILL.md)
- [`duet-plan/SKILL.md`](duet-plan/SKILL.md), [`duet-impl/SKILL.md`](duet-impl/SKILL.md), [`duet-review/SKILL.md`](duet-review/SKILL.md)
- [`triangulate/SKILL.md`](triangulate/SKILL.md) — Claude + codex + you = 3 reference points on one decision
- [`references/agent-autonomy.md`](references/agent-autonomy.md) — shared principle for the duet skills

## FAQ

**Where do session docs live?** In each project's `.koji/` directory, committed to git. `~/.config/koji/` only stores global preferences.

**Will `/koji-init` overwrite my existing docs?** No. If existing session files are found in `docs/`, koji asks whether to relocate or keep them. Content is preserved.

**Does it conflict with gstack?** No. Different skill names, designed to coexist.

**Does it phone home?** No telemetry, no analytics. All session data stays in your repo.

## Works With

- **Claude Code** (primary target)
- Any AI agent that reads markdown skill files

## License

MIT
