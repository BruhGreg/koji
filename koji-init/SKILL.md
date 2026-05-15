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

Check what already exists in two passes:

**Pass 1 — Check `docs/` for existing koji session files:**
Look for `docs/agent-session.md`, `docs/AI_HANDOFF.md`, `docs/lessons.md`, and `docs/SESSION_TEMPLATE.md`. If at least two of the three core files (agent-session, AI_HANDOFF, lessons) exist, this is a **migration**.

**Guard:** Only offer relocation if `HAS_PROJECT_CONFIG` is `false` (first-time init). If `.koji.yaml` already exists, respect whatever `docs_dir` it specifies — skip this step.

**If migration detected**, ask the user using AskUserQuestion:

> Found existing session files in `docs/`:
> _(list only files that actually exist)_
> - `docs/agent-session.md`
> - `docs/AI_HANDOFF.md`
> - `docs/lessons.md`
>
> The koji standard directory is `.koji/`. Would you like to relocate?

Options:
- A) Relocate to `.koji/` — move session files, update references (recommended)
- B) Keep in `docs/` — use `docs/` as-is, set `docs_dir: docs`

**If A (Relocate):**
1. Create `.koji/` directory (and `.koji/sessions/` if `docs/sessions/` exists)
2. Move **only** koji session files from `docs/` to `.koji/`:
   - `agent-session.md`, `AI_HANDOFF.md`, `lessons.md`, `SESSION_TEMPLATE.md`
   - `sessions/` subdirectory (entire directory, if it exists)
   - Do NOT move other project documentation in `docs/`
3. Scan the moved files for references to `docs/` session paths (e.g., `docs/lessons.md`, `docs/agent-session.md`, `docs/sessions/`) and update them to `.koji/` equivalents
4. If `CLAUDE.md` exists, update any `docs/AI_HANDOFF.md`, `docs/lessons.md`, or `docs/agent-session.md` references to `.koji/`
5. Set `DOCS_DIR` to `.koji` for the remainder of this workflow
6. Skip Steps 2 and 3 (preferences and scaffolding) — files already exist. Proceed to Step 4.

**If B (Keep in `docs/`):**
1. Set `DOCS_DIR` to `docs` for the remainder of this workflow
2. Skip Steps 2 and 3 — files already exist. Proceed to Step 4.

**Pass 2 — Scan for stray session files outside `$DOCS_DIR/`:**
Search the project root for common session file names that may exist from before koji:
- `agent-session.md`, `AI_HANDOFF.md`, `lessons.md`, `SESSION_TEMPLATE.md` in root
- `.agents/workflows/wrap.md`, `agent-context.md` or similar ad-hoc files

If found, tell the user:
> Found session-related files outside `docs/`:
> - `./agent-session.md` (6 lines)
> - `./agent-context.md` (68 lines)
>
> 1. **Merge** — incorporate content into `docs/` files and delete originals
> 2. **Skip** — leave them, I'll handle manually
> 3. **View** — show me the contents first

If "Merge": read each file, extract useful content (targets → handoff roadmap, session notes → session log, context → CLAUDE.md), write into the appropriate koji doc, then delete the original. If the file is in `.gitignore`, also remove the gitignore entry.

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

**Note:** `TODO.md` is NOT created here. It gets created automatically by `/wrap` the first time task-related work is done — no empty scaffolding.

Also copy `SESSION_TEMPLATE.md` into `$DOCS_DIR/` so the project has a local reference.

### 4. Generate `.koji.yaml`

Write `.koji.yaml` to the project root:

```yaml
# koji — session management for AI agents
# https://github.com/BruhGreg/koji
docs_dir: .koji
template: <chosen_template>
archive:
  strategy: <chosen_strategy>
  threshold: 5
  keep: 1
  dir: sessions
agents:
  - Claude
wrap:
  starter_prompt: true
```

Set `docs_dir` to the value determined by the workflow: `.koji` for fresh installs and relocations, `docs` if the user chose to keep files in `docs/`.

### 5. Wire CLAUDE.md

Check if `CLAUDE.md` exists in the project root.

**If `CLAUDE.md` exists:**
- Check if it already contains a koji session section (look for `## Session Management` or `/wrap` or `/take-note` or `koji`)
- If not found, append the following block at the end:

```markdown

## Session Management (koji)

Session docs in `$DOCS_DIR/` (handoff, lessons, session log + Load on Kick-Off) and `TODO.md` at project root. Use `/kick-off` to start a session, `/wrap` to end, `/take-note` mid-session.
```

**If `CLAUDE.md` does not exist:**
- Create a minimal `CLAUDE.md` with project name and the session management block:

```markdown
# <PROJECT_NAME>

## Session Management (koji)

Session docs in `$DOCS_DIR/` (handoff, lessons, session log + Load on Kick-Off) and `TODO.md` at project root. Use `/kick-off` to start a session, `/wrap` to end, `/take-note` mid-session.
```

(Substitute the actual resolved `$DOCS_DIR` value — e.g., `.koji` or `docs` — when writing to CLAUDE.md. Do not write the literal string `$DOCS_DIR`.)

**Why pointer-only, not auto-read instructions:** earlier koji versions inlined `Read $DOCS_DIR/AI_HANDOFF.md`, `Read $DOCS_DIR/TODO.md`, etc. into this block. That had two problems: (a) it duplicated `/kick-off`'s job (which also handles migrations, version-check, budget warning, drift report), and (b) `$DOCS_DIR/TODO.md` was wrong — TODO.md is at project root, not under `$DOCS_DIR/`. The pointer-only block fixes both: no auto-reads (use `/kick-off`), and the path hint is correct.

Tell the user: "Added koji session-management routing to CLAUDE.md. Start each session with `/kick-off`."

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
  /kick-off   — Start a session (loads last session + handoff context)
  /wrap       — End-of-session wrap (lessons + handoff + session log + commit)
  /take-note  — Mid-session progress save
  /koji-init  — Re-run this setup
```
