---
description: "Bootstrap koji session management in the current project. Creates docs scaffolding, templates, and .koji.yaml config."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - AskUserQuestion
---

# Initialize Koji

Run the preamble to detect current state:

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji init ==="
echo "Project: $PROJECT_NAME ($PROJECT_ROOT)"
echo "Has .koji.yaml: $HAS_PROJECT_CONFIG"
echo "Has docs dir: $HAS_DOCS"
echo "Has session log: $HAS_SESSION_LOG"
echo "Has handoff: $HAS_HANDOFF"
echo "Has lessons: $HAS_LESSONS"
```

---

## Workflow

### 1. Detect Existing State

Check what already exists. If the project already has `docs/agent-session.md`, `docs/AI_HANDOFF.md`, and `docs/lessons.md`, this is a **migration** — only generate `.koji.yaml` to match existing setup. Do NOT overwrite existing docs.

### 2. Ask Preferences (only for new setups or if .koji.yaml doesn't exist)

Ask the user two questions using AskUserQuestion. Use the exact format below — the context paragraph first, then lettered options.

**Question 1 — Template style:**

Use AskUserQuestion:

> koji session entries can follow two formats. Full is great for complex projects
> where you want to track test results and detailed achievements. Simple is leaner —
> just what got done and what's next. You can always change this later in `.koji.yaml`.

Options:
- A) Full — Summary, Key Achievements, Test Results, Notes (recommended for most projects)
- B) Simple — Done, Key Decisions, Files Changed, Next (best for scripts and pipelines)

If A: set template to `default`.
If B: set template to `simple`.

**Question 2 — Archive strategy:**

Use AskUserQuestion:

> When your session log gets long (5+ entries), koji archives the oldest ones
> to keep the active file readable. Numbered is simpler. Dated organizes by
> calendar and adds an INDEX.md for lookup — better if the project runs for months.

Options:
- A) Numbered — `archive-01.md`, `archive-02.md`, etc. (recommended)
- B) Dated — `YYYY-MM/DD-slug.md` with INDEX.md lookup table

### 3. Create Scaffolding

Based on answers, create the following (skip files that already exist):

```
$DOCS_DIR/
├── agent-session.md          # from templates/$TEMPLATE/
├── AI_HANDOFF.md             # from templates/$TEMPLATE/
├── lessons.md                # from templates/$TEMPLATE/
├── SESSION_TEMPLATE.md       # from templates/$TEMPLATE/
└── sessions/                 # archive directory
    └── (INDEX.md if dated strategy)
```

Copy templates from `~/.claude/skills/koji/templates/$TEMPLATE/` to `$PROJECT_ROOT/$DOCS_DIR/`.

Also copy `SESSION_TEMPLATE.md` into `$DOCS_DIR/` so the project has a local reference.

### 4. Generate `.koji.yaml`

Write `.koji.yaml` to the project root:

```yaml
# koji — session management for AI agents
# https://github.com/BruhGreg/koji
docs_dir: docs
template: <chosen_template>
archive:
  strategy: <chosen_strategy>
  threshold: 5
  keep: 3
  dir: sessions
agents:
  - Claude
wrap:
  starter_prompt: true
```

### 5. Wire CLAUDE.md

Check if `CLAUDE.md` exists in the project root.

**If `CLAUDE.md` exists:**
- Check if it already contains a koji session section (look for `## Session Management` or `/wrap` or `/take-note` or `koji`)
- If not found, append the following block at the end:

```markdown

## Session Management (koji)

On session start:
1. Read `docs/AI_HANDOFF.md` for current project state
2. Review recent `docs/lessons.md` entries for gotchas

On session end: run `/wrap`
Mid-session checkpoint: run `/take-note`
```

**If `CLAUDE.md` does not exist:**
- Create a minimal `CLAUDE.md` with project name and the session management block:

```markdown
# <PROJECT_NAME>

## Session Management (koji)

On session start:
1. Read `docs/AI_HANDOFF.md` for current project state
2. Review recent `docs/lessons.md` entries for gotchas

On session end: run `/wrap`
Mid-session checkpoint: run `/take-note`
```

Tell the user: "Added session management instructions to CLAUDE.md — your agent will now automatically read handoff state and lessons at session start."

### 6. For Migrations (existing projects with old-style wrap)

If the project already has `.agents/workflows/wrap.md` or `.claude/skills/wrap/SKILL.md` or `.claude/commands/wrap.md`:

Tell the user:
> koji is now handling `/wrap` and `/take-note` globally. You can safely remove these project-local files:
> - `.agents/workflows/wrap.md`
> - `.claude/skills/wrap/SKILL.md`
> - `.claude/skills/take-note/SKILL.md`
> - `.claude/commands/wrap.md`
>
> Would you like me to remove them now?

Only remove with explicit approval.

### 7. Confirmation

Output:
```
koji initialized for $PROJECT_NAME.

Session docs: $DOCS_DIR/
Config: .koji.yaml
Template: $TEMPLATE
Archive: $ARCHIVE_STRATEGY
CLAUDE.md: session checklist added

Available commands:
  /wrap       — End-of-session wrap (lessons + handoff + session log + commit)
  /take-note  — Mid-session progress save
  /koji-init  — Re-run this setup
```
