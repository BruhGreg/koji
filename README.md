# koji

Session management for AI coding agents. Like a fermentation starter — seed any project with structured session continuity.

koji gives your AI agent a memory across sessions: lessons learned, project state handoffs, and session logs with automatic archiving. Install once, use everywhere.

## Why

Every AI coding session starts cold. Your agent doesn't know what happened yesterday, what mistakes were made, or what's next on the roadmap. You end up re-explaining context every time.

koji fixes this with structured session docs and three commands:
- **`lessons.md`** — Append-only log of corrections and gotchas. Your agent reads this and doesn't repeat mistakes.
- **`AI_HANDOFF.md`** — Living snapshot of project state. The briefing doc for whoever picks up next.
- **`agent-session.md`** — Session history with automatic archiving. Full audit trail.
- **`TODO.md`** — Task tracking separate from the handoff. Created automatically by `/wrap` on first use.

## Install

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
```

That's it. Five skills are now available in Claude Code:

| Skill | What it does |
|-------|-------------|
| `/kick-off` | Start session: load handoff, lessons, last session — or `/kick-off build the news page` for a custom focus |
| `/wrap` | End session: update lessons, handoff, session log, archive, propose commit, generate starter prompt |
| `/take-note` | Mid-session: save progress — or `/take-note finished auth, moving to tests` with inline note |
| `/koji-init` | Bootstrap: create docs scaffolding and `.koji.yaml` in any project |
| `/inspect-doc-drift` | Scan docs tagged with a `covers:` frontmatter list, show drift vs their covered code, offer to fix stale ones |

## Quick Start

```
> /koji-init
```

koji asks two questions (template style + archive strategy), then creates:

```
.koji/
├── agent-session.md       # Session history
├── AI_HANDOFF.md          # Project state for next agent
├── lessons.md             # Corrections and discoveries
├── SESSION_TEMPLATE.md    # Entry format reference
└── sessions/              # Archive directory
TODO.md                    # Task tracking (created by /wrap on first use)
```

Plus `.koji.yaml` in your project root for configuration.

Start each session with `/kick-off`. End with `/wrap`. Checkpoint mid-session with `/take-note`.

### Skill Args

Some skills accept text after the command to override default behavior:

```
/kick-off                          → reads last session, resumes from handoff
/kick-off build the news page      → skips last session, focuses on your intent

/take-note                         → infers progress from conversation context
/take-note finished auth, doing tests  → uses your note directly
```

## Configuration

`.koji.yaml` lives in your project root. All fields are optional — sensible defaults apply.

```yaml
# koji — session management for AI agents
docs_dir: .koji               # where session docs live (legacy: docs)
template: default             # "default" (full) or "simple" (minimal)
archive:
  strategy: numbered          # "numbered" (archive-01.md) or "dated" (YYYY-MM/DD-slug.md)
  threshold: 5                # archive when this many sessions exist
  keep: 1                     # keep this many in the active file
  dir: sessions               # subdirectory for archives
agents:                       # tags for session entries
  - Claude
  - Cursor
wrap:
  starter_prompt: true        # generate next-session prompt on /wrap
todo:
  file: TODO.md               # filename (auto-detected: TODO.md or TODOS.md)
  completed: inline           # "inline" (## Completed section) or "archive" (COMPLETED_TASKS.md)
```

Global config (`~/.config/koji/config.yaml`) also stores persistent preferences:
- `commit_strategy` — `together` or `split`, remembered from your first `/wrap` choice
- `auto_update` — `true` or `false`, auto-update koji on `/kick-off`

### Templates

- **`default`** — Full session entries: Summary, Key Achievements, Test Results, Notes. Best for complex multi-feature projects.
- **`simple`** — Minimal entries: Done, Key Decisions, Files Changed, Next. Best for focused pipelines and scripts.

### Archive Strategies

- **`numbered`** — Archives go to `sessions/archive-01.md`, `archive-02.md`, etc. Simple, linear.
- **`dated`** — Archives go to `sessions/YYYY-MM/DD-slug.md` with an `INDEX.md` lookup table. Scales better for long-running projects.

## Doc Loading at Kick-Off (v0.4.0)

By default `/kick-off` reads four mandatory files (handoff, TODO, lessons, last session entry). Anything else — `docs/*.md`, `DESIGN.md`, architecture notes — is invisible to the agent at session start.

**Opt specific docs into kick-off context** by adding a section to `agent-session.md` (above the first `## Session:` entry — colocated with per-session `Notes for Next Session` since both are kick-off inputs):

```markdown
## Load on Kick-Off

- [Architecture](docs/ARCHITECTURE.md)
- [API Reference](docs/API.md)
- docs/DEPLOYMENT.md
- /DESIGN.md
```

Bullets accept markdown-link form or plain-path form. At kick-off, koji parses this section, loads each `.md` path into context, and reports: `Docs: 4 loaded`.

### Optional: drift awareness via coverage tags

Any doc can declare which code paths it describes via YAML frontmatter. When a tagged doc is in Load on Kick-Off and its covered paths have drifted past `docs.stale_threshold` commits since the doc was last edited, kick-off loads it *with a warning*.

```markdown
---
covers:
  - src/auth/
  - server/routes/auth/
---

# AUTH_FLOW.md
```

Top-level `covers` key. Frontmatter aligns with the wider AI-agent-markdown ecosystem (Cursor rules, Continue.dev, Astro, MkDocs, Hugo, Jekyll all parse it). Mix `covers` alongside other frontmatter keys freely.

**Intentionally untagged docs** — onboarding, runbooks, glossaries, narrative design docs with no code to track — can opt out with the `covers: none` sentinel:

```markdown
---
covers: none
---
```

Such docs still load at kick-off (if listed in `## Load on Kick-Off`) but are dropped from drift dashboards and from `/inspect-doc-drift`'s untagged-scan prompts — the sentinel says "I've looked; it legitimately has no code coverage."

### Config

```yaml
# .koji.yaml
docs:
  stale_threshold: 10       # commits in covered paths since doc's last edit (default 10)
  stale_action: warn        # "warn" (load + warn) or "skip" (default warn)
  budget_warn_tokens: 15000 # warn at kick-off if Load on Kick-Off exceeds this (~60k chars)
  budget_silent: false      # set true to skip the budget warning entirely (size still shown in brief)
```

**Budget keys are optional** — kick-off uses the defaults (`15000`, `false`). In interactive mode the warning fires as an A/B/C/D menu (Continue / Trim / Raise / Silence) that can edit `.koji.yaml` for you. In auto mode (or any non-interactive session) the menu is replaced by a single one-liner pointing you at `agent-session.md` (to trim) and `.koji.yaml` (to raise or silence); next kick-off reflects the edits automatically.

### Orphan detection

If any covered path no longer exists in the working tree (code deleted, moved, or refactored away), the doc is flagged **orphan** — a separate state from stale. Kick-off still loads it but with a stronger warning; `/inspect-doc-drift` sorts orphans first and offers remediation paths that make sense for deleted code (re-tag, untag, or delete the doc).

### `/wrap` proposes adds and removes

`/wrap` keeps `## Load on Kick-Off` aligned with where the project is going. Three passes feed one consolidated proposal:

- **Adds** — tagged docs whose `covers:` overlaps files touched this session, plus tagged docs whose theme matches the next-session mission (per `TODO.md`, "Notes for Next Session", starter prompt, conversation context).
- **Removes** — currently-loaded docs that have stopped being relevant. Conservative guards skip removal if a doc was just added this wrap, is `stale`/`orphan` (might be there to fix), or covers a next-session path. Three escape hatches keep the list from growing unbounded:
  1. **Self-tagged temp docs** (markers like `temporary working doc`, `delete when …`, `gets archived or deleted` in the doc's first ~20 lines) bypass the exempt/untagged default-keep bias and the stale/orphan guard — the author opted into the temp lifecycle, so the LOKO bullet ages out without manual pruning.
  2. **Session-mention staleness** — a bullet that has been in LOKO for ≥ 2 wraps and is absent from every active-log session body is auto-removed even when its covered code is still hot. Code-freshness ≠ doc-freshness; if the user hasn't referenced the doc across multiple sessions, it isn't load-bearing.
  3. **Judgment removes auto-apply with a one-wrap grace** — the v0.4.6 design always treated judgment-based removes as advisory ("auto mode shouldn't yank a doc on a hunch"), which created an add-only ratchet. Now: judgment removes auto-apply when the bullet has been in LOKO for ≥ 2 wraps; recent additions stay advisory so the user can pin them.

Interactive mode shows one prompt: apply all / adds only / removes only / select individually / skip. Auto mode (where prompts can't fire) auto-applies adds and any deterministic removes (untouched past threshold, self-tagged temp marker, OR `established + unmentioned`), auto-applies judgment removes only for established bullets, lists judgment removes against fresh bullets as advisory, and prints one line showing what changed plus how to revert (`git restore`).

### `/inspect-doc-drift`

Audits the whole codebase for doc-code drift and untagged docs.

- **Tagged docs** → reports drift (fresh / stale / orphan) and walks remediation for problem docs (open / re-tag / untag / delete / skip).
- **Untagged `.md` files across the repo** → bucketed by priority:
  - **HIGH** — untagged docs listed in `## Load on Kick-Off` (loaded without drift signal)
  - **MEDIUM** — docs under `docs/` and nested `DESIGN.md` files
  - **LOW** — other tracked `.md` files
  Meta-files are excluded (README, LICENSE, CHANGELOG, CLAUDE.md, AGENTS.md, handoff, session logs, TODO, etc). You pick which bucket(s) to walk; per-doc prompts suggest covers paths via cheap heuristic (filename keywords + body references).

Run with no args for the dashboard + prompts, or `/inspect-doc-drift <path>` to drill into one doc read-only.

### Design notes

No inference. No graph walk. No auto-discovery. Kick-off reads only what you've explicitly listed in the handoff. Projects that don't add the `Load on Kick-Off` section behave exactly as in v0.3.x — zero change. The tag convention lands in a crowded space (Semcheck, Driftcheck, DocSync all solve adjacent problems with LLM calls); koji's angle is the git-commit-count staleness heuristic, which is deterministic, cheap, and doesn't need a model at all.

## How It Works

```
~/.claude/skills/koji/        # The module (git repo)
├── kick-off/SKILL.md         # /kick-off skill definition
├── wrap/SKILL.md             # /wrap skill definition
├── take-note/SKILL.md        # /take-note skill definition
├── koji-init/SKILL.md        # /koji-init skill definition
├── inspect-doc-drift/SKILL.md  # /inspect-doc-drift skill definition (v0.4.0)
├── bin/
│   ├── koji-config           # Config read/write utility
│   ├── koji-detect           # Project detection + config cascade
│   └── koji-migrate-check    # Legacy docs/ → .koji/ migration detection
├── templates/
│   ├── default/              # Full template set
│   └── simple/               # Minimal template set
├── setup                     # Installer
├── VERSION                   # Current version
└── README.md

~/.config/koji/               # Global state (XDG standard)
└── config.yaml               # Global defaults

<project>/
├── .koji.yaml                # Per-project config
└── .koji/                    # Session docs (created by /koji-init)
```

**Config cascade:** `.koji.yaml` (project) > `~/.config/koji/config.yaml` (global) > built-in defaults. Respects `XDG_CONFIG_HOME` if set.

**No build step.** Pure bash + markdown. No dependencies beyond a POSIX shell.

## The `/wrap` Workflow

### `/kick-off`

When you run `/kick-off` at session start:

1. **Migration check** — detects if koji files are in `docs/` (legacy) but `.koji.yaml` points to `.koji/`. Offers to migrate or skip.
2. **Version check** — compares local vs remote VERSION. Offers update / skip / always-update.
3. **Load context** — reads AI_HANDOFF.md, TODO.md, last session entry, and a **focus-filtered subset of lessons.md** (matches drawn from your `/kick-off` arg, last session's Notes for Next Session, and open TODO items, plus a top-3 recency baseline). Untagged entries fall back to body-text matching. Optionally tag entries `YYYY-MM-DD — [Agent] — [domain1,domain2] — …` to sharpen the matching. Cold start (no focus signals) loads top 10 by recency, matching pre-v0.5 behavior.
4. **Extended context** — three-tier context gathering, zero config:
   - **Baseline** (always) — git branch, uncommitted changes, active plans
   - **Reference-follow** (if session note mentions specific files/plans) — reads referenced plans, searches archives for related sessions
   - **Codebase orient** (first session, stale handoff, or no direction) — detects tech stack, project structure, recent commits, key docs
5. **Brief** — concise summary: last session, next task, gotchas, branch, focus.
6. **gstack suggestions** — if gstack is installed, detects your dev phase and suggests 2-3 relevant workflows (e.g., `/browse` for frontend, `/qa` for pre-ship). Skipped if gstack not detected.

### `/wrap`

When you run `/wrap` at session end, it executes six steps in order:

1. **Lessons** — Default action is **skip**. A candidate must clear three gates (rediscovery <5min / common-knowledge / burned-time) AND pass the "would the user write this themselves?" test before being appended to `lessons.md`. Most sessions add zero — that's the success path. Format: `YYYY-MM-DD — [Agent] — what went wrong → rule to prevent it`.
2. **Handoff & TODO** — Updates `AI_HANDOFF.md` with project state changes. Marks completed tasks and adds new items to `TODO.md` (creates it on first use).
3. **Session Log** — Appends a new entry to `agent-session.md`. Archives oldest entries if threshold is reached.
4. **Permission Hygiene** — Promotes safe session permissions to `settings.json`, skips risky ones, asks about grey area (zero prompts most sessions).
5. **Commit Proposal** — Shows `git diff --stat`, proposes a conventional commit. For mixed code+docs changes, asks your preferred split strategy and remembers it for future sessions.
6. **Starter Prompt** — Generates a 3-5 sentence briefing for the next session. Suggests a descriptive session name based on what was accomplished (e.g., `auth-middleware-refactor`).

## Migration from Project-Local Wrap

If you already have `.agents/workflows/wrap.md` or `.claude/skills/wrap/SKILL.md` in your projects, run `/koji-init` — it detects existing docs and only creates `.koji.yaml`. Then delete the old local files:

```bash
rm -f .agents/workflows/wrap.md
rm -rf .claude/skills/wrap .claude/skills/take-note
rm -f .claude/commands/wrap.md
```

## FAQ

### Where do session docs live?

Locally, in each project's `.koji/` directory (or `docs/` for legacy projects), committed to git. Each project's lessons, handoff, and session history belong with that project. `~/.config/koji/` only stores your global preferences (like default template) — no project data.

### Will `/koji-init` overwrite my existing docs?

No. If existing session files are found in `docs/`, koji asks whether you want to relocate them to `.koji/` (the new standard) or keep them in place. Either way, existing content is preserved — nothing is overwritten or deleted.

### What about my old `/wrap` workflow files?

`/koji-init` detects old-style wrap files (`.agents/workflows/wrap.md`, `.claude/skills/wrap/SKILL.md`, `.claude/commands/wrap.md`) and offers to remove them. It always asks first — nothing is deleted without your approval.

### Does it conflict with gstack?

No. gstack has no `wrap`, `take-note`, or `koji-init` skills, so the symlinks don't collide. They coexist in `~/.claude/skills/`.

### What does `~/.config/koji/` contain?

Just `config.yaml` with your global defaults (template preference, archive strategy). No telemetry, no analytics, no project data. All session docs stay in the project repo. Respects `XDG_CONFIG_HOME` if set.

### How does the agent know to read handoff/lessons at session start?

`/koji-init` adds a `## Session Management (koji)` section to your project's `CLAUDE.md` with instructions to run `/kick-off` on session start, which reads the handoff and lessons automatically. Claude Code reads `CLAUDE.md` at the beginning of every session.

### Can I use different templates per project?

Yes. Each project's `.koji.yaml` can specify `template: default` or `template: simple` independently. Global default in `~/.config/koji/config.yaml` is used when a project has no `.koji.yaml`.

### How does TODO.md work?

`TODO.md` is created automatically by `/wrap` the first time task-related work is done — no empty scaffolding from `/koji-init`. It lives at the project root (not inside `.koji/`). `/wrap` marks completed items and adds new tasks discovered during the session. `/kick-off` reads it alongside the handoff for task context. Configure the filename and completed-task handling in `.koji.yaml` under `todo:`.

### What is the commit strategy preference?

When `/wrap` encounters both code and docs changes, it asks whether to commit everything together or split into two commits (code first, docs second). Your choice is saved to `~/.config/koji/config.yaml` so future wraps use the same strategy automatically. Change it anytime with `koji-config set commit_strategy together` or `koji-config set commit_strategy split`.

### How does /kick-off gather context?

Three tiers, zero config. **Baseline** (always): checks git branch, uncommitted changes, active plans. **Reference-follow** (when session notes mention specific files/plans): reads referenced plans and searches archived sessions for related topics. **Codebase orient** (first session, stale handoff >7 days, or no session notes): detects tech stack, project structure, recent commits, key docs. Each tier triggers automatically based on context — no flags to set.

### How hard is it to set up?

One command: `git clone ... && ./setup`. Takes ~2 seconds. No dependencies, no build step, no npm/bun/pip. Pure bash + markdown.

## Works With

- **Claude Code** (primary target)
- Any AI agent that reads markdown skill files

Designed to coexist with [gstack](https://github.com/garrytan/gstack) — no naming conflicts.

## License

MIT
