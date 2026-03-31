# koji

Session management for AI coding agents. Like a fermentation starter — seed any project with structured session continuity.

koji gives your AI agent a memory across sessions: lessons learned, project state handoffs, and session logs with automatic archiving. Install once, use everywhere.

## Why

Every AI coding session starts cold. Your agent doesn't know what happened yesterday, what mistakes were made, or what's next on the roadmap. You end up re-explaining context every time.

koji fixes this with three files and three commands:
- **`lessons.md`** — Append-only log of corrections and gotchas. Your agent reads this and doesn't repeat mistakes.
- **`AI_HANDOFF.md`** — Living snapshot of project state. The briefing doc for whoever picks up next.
- **`agent-session.md`** — Session history with automatic archiving. Full audit trail.

## Install

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
```

That's it. Three skills are now available in Claude Code:

| Skill | What it does |
|-------|-------------|
| `/wrap` | End-of-session: update lessons, handoff, session log, archive, propose commit, generate starter prompt |
| `/take-note` | Mid-session: save progress to current session entry without committing |
| `/init-koji` | Bootstrap: create docs scaffolding and `.koji.yaml` in any project |

## Quick Start

```
> /init-koji
```

koji asks two questions (template style + archive strategy), then creates:

```
docs/
├── agent-session.md       # Session history
├── AI_HANDOFF.md          # Project state for next agent
├── lessons.md             # Corrections and discoveries
├── SESSION_TEMPLATE.md    # Entry format reference
└── sessions/              # Archive directory
```

Plus `.koji.yaml` in your project root for configuration.

At the end of every session, run `/wrap`. Mid-session, run `/take-note`.

## Configuration

`.koji.yaml` lives in your project root. All fields are optional — sensible defaults apply.

```yaml
# koji — session management for AI agents
docs_dir: docs                # where session docs live
template: default             # "default" (full) or "simple" (minimal)
archive:
  strategy: numbered          # "numbered" (archive-01.md) or "dated" (YYYY-MM/DD-slug.md)
  threshold: 5                # archive when this many sessions exist
  keep: 3                     # keep this many in the active file
  dir: sessions               # subdirectory for archives
agents:                       # tags for session entries
  - Claude
  - Cursor
wrap:
  starter_prompt: true        # generate next-session prompt on /wrap
```

### Templates

- **`default`** — Full session entries: Summary, Key Achievements, Test Results, Notes. Best for complex multi-feature projects.
- **`simple`** — Minimal entries: Done, Key Decisions, Files Changed, Next. Best for focused pipelines and scripts.

### Archive Strategies

- **`numbered`** — Archives go to `sessions/archive-01.md`, `archive-02.md`, etc. Simple, linear.
- **`dated`** — Archives go to `sessions/YYYY-MM/DD-slug.md` with an `INDEX.md` lookup table. Scales better for long-running projects.

## How It Works

```
~/.claude/skills/koji/        # The module (git repo)
├── wrap/SKILL.md             # /wrap skill definition
├── take-note/SKILL.md        # /take-note skill definition
├── init-koji/SKILL.md        # /init-koji skill definition
├── bin/
│   ├── koji-config           # Config read/write utility
│   └── koji-detect           # Project detection + config cascade
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
└── docs/                     # Session docs (created by /init-koji)
```

**Config cascade:** `.koji.yaml` (project) > `~/.config/koji/config.yaml` (global) > built-in defaults. Respects `XDG_CONFIG_HOME` if set.

**No build step.** Pure bash + markdown. No dependencies beyond a POSIX shell.

## The `/wrap` Workflow

When you run `/wrap` at session end, it executes five steps in order:

1. **Lessons** — Scans the session for corrections or discoveries. Appends to `lessons.md` with format: `YYYY-MM-DD — [Agent] — what went wrong → rule to prevent it`
2. **AI Handoff** — Updates `AI_HANDOFF.md` with completed tasks, new decisions, changed blockers
3. **Session Log** — Appends a new entry to `agent-session.md`. Archives oldest entries if threshold is reached.
4. **Commit Proposal** — Shows `git diff --stat`, proposes a conventional commit message, waits for approval
5. **Starter Prompt** — Generates a 3-5 sentence briefing for the next session

## Migration from Project-Local Wrap

If you already have `.agents/workflows/wrap.md` or `.claude/skills/wrap/SKILL.md` in your projects, run `/init-koji` — it detects existing docs and only creates `.koji.yaml`. Then delete the old local files:

```bash
rm -f .agents/workflows/wrap.md
rm -rf .claude/skills/wrap .claude/skills/take-note
rm -f .claude/commands/wrap.md
```

## FAQ

### Where do session docs live?

Locally, in each project's `docs/` directory, committed to git. Each project's lessons, handoff, and session history belong with that project. `~/.config/koji/` only stores your global preferences (like default template) — no project data.

### Will `/init-koji` overwrite my existing docs?

No. If `docs/lessons.md`, `docs/AI_HANDOFF.md`, or `docs/agent-session.md` already exist, koji leaves them untouched. It only creates what's missing and generates `.koji.yaml` to match your existing setup.

### What about my old `/wrap` workflow files?

`/init-koji` detects old-style wrap files (`.agents/workflows/wrap.md`, `.claude/skills/wrap/SKILL.md`, `.claude/commands/wrap.md`) and offers to remove them. It always asks first — nothing is deleted without your approval.

### Does it conflict with gstack?

No. gstack has no `wrap`, `take-note`, or `init-koji` skills, so the symlinks don't collide. They coexist in `~/.claude/skills/`.

### What does `~/.config/koji/` contain?

Just `config.yaml` with your global defaults (template preference, archive strategy). No telemetry, no analytics, no project data. All session docs stay in the project repo. Respects `XDG_CONFIG_HOME` if set.

### How does the agent know to read handoff/lessons at session start?

`/init-koji` adds a `## Session Management (koji)` section to your project's `CLAUDE.md` with instructions to read `docs/AI_HANDOFF.md` and `docs/lessons.md` on session start. Claude Code reads `CLAUDE.md` automatically at the beginning of every session.

### Can I use different templates per project?

Yes. Each project's `.koji.yaml` can specify `template: default` or `template: simple` independently. Global default in `~/.config/koji/config.yaml` is used when a project has no `.koji.yaml`.

### How hard is it to set up?

One command: `git clone ... && ./setup`. Takes ~2 seconds. No dependencies, no build step, no npm/bun/pip. Pure bash + markdown.

## Works With

- **Claude Code** (primary target)
- Any AI agent that reads markdown skill files

Designed to coexist with [gstack](https://github.com/garrytan/gstack) — no naming conflicts.

## License

MIT
