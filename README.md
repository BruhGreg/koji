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
| `/koji-doc-review` | Inspect docs tagged with `<!-- koji:covers ... -->`: list freshness, load a stale one on demand, or tag a new one |

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

## Doc Drift Awareness (v0.4.0)

Kick-off reads the mandatory files (`AI_HANDOFF.md`, `TODO.md`, `lessons.md`, last session entry). Other project docs stay invisible unless you explicitly tag them. A tagged doc gets auto-loaded into kick-off context — but only if it still looks fresh against the code it describes.

**Tag a doc** by adding one line at the top:

```markdown
<!-- koji:covers backend/auth/ clients/lib/auth/ -->
```

Multiple paths space-separated. Relative to repo root.

**At kick-off**, for each tagged doc:
- Find the commit that last touched the doc.
- Count commits in the covered paths since then.
- If the count is over the threshold (default 10, override via `.koji.yaml` → `docs.stale_threshold`), skip the doc with a notice: `Skipping docs/X.md — code moved 12 commits since doc last touched.`
- Otherwise load it silently.

**Why exclusion instead of verification**: a silently-skipped doc is a recoverable mistake; a confidently-wrong doc in agent context is not. The default is fail-safe.

**Inspect or force-load** with `/koji-doc-review`:

```
/koji-doc-review              # list all tagged docs + freshness status
/koji-doc-review <path>       # load a specific doc (even if stale)
/koji-doc-review add <path>   # interactively add a koji:covers header
```

No global index file, no YAML sidecar, no wrap-time prompts. The only thing you author is the one-line header per doc you want koji to consider. Opt-in — projects without any tagged docs see zero behavior change.

**Cross-platform**: uses `git grep` and `git log` only. No date math, no platform-specific grep flags. Identical behavior on Windows, macOS, Linux.

## How It Works

```
~/.claude/skills/koji/        # The module (git repo)
├── kick-off/SKILL.md         # /kick-off skill definition
├── wrap/SKILL.md             # /wrap skill definition
├── take-note/SKILL.md        # /take-note skill definition
├── koji-init/SKILL.md        # /koji-init skill definition
├── koji-doc-review/SKILL.md  # /koji-doc-review skill definition (v0.4.0)
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
3. **Load context** — reads AI_HANDOFF.md, TODO.md, lessons.md, last session entry silently.
4. **Extended context** — three-tier context gathering, zero config:
   - **Baseline** (always) — git branch, uncommitted changes, active plans
   - **Reference-follow** (if session note mentions specific files/plans) — reads referenced plans, searches archives for related sessions
   - **Codebase orient** (first session, stale handoff, or no direction) — detects tech stack, project structure, recent commits, key docs
5. **Brief** — concise summary: last session, next task, gotchas, branch, focus.
6. **gstack suggestions** — if gstack is installed, detects your dev phase and suggests 2-3 relevant workflows (e.g., `/browse` for frontend, `/qa` for pre-ship). Skipped if gstack not detected.

### `/wrap`

When you run `/wrap` at session end, it executes six steps in order:

1. **Lessons** — Scans the session for corrections or discoveries. Appends to `lessons.md` with format: `YYYY-MM-DD — [Agent] — what went wrong → rule to prevent it`
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

Starting in v0.4.0, kick-off also runs a **doc inclusion pass** — it scans for docs tagged with `<!-- koji:covers ... -->` headers and loads each one into context if the code it describes hasn't drifted far since the doc was last touched. Stale docs are skipped (the default is fail-safe: a missing doc beats a confidently-wrong one). See **Doc Drift Awareness** above.

### How hard is it to set up?

One command: `git clone ... && ./setup`. Takes ~2 seconds. No dependencies, no build step, no npm/bun/pip. Pure bash + markdown.

## Works With

- **Claude Code** (primary target)
- Any AI agent that reads markdown skill files

Designed to coexist with [gstack](https://github.com/garrytan/gstack) — no naming conflicts.

## License

MIT
