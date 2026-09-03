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
1. Create `.koji/` (and `.koji/sessions/` if `docs/sessions/` exists).
2. Move **only** koji session files from `docs/` to `.koji/`: `agent-session.md`, `AI_HANDOFF.md`, `lessons.md`, `SESSION_TEMPLATE.md`, and `sessions/`. Do NOT move other project docs.
3. Update any `docs/`-prefixed references inside the moved files to `.koji/` equivalents. Also update `CLAUDE.md` if it references those paths.
4. Set `DOCS_DIR=.koji` and skip Steps 2-3 (files already exist) — proceed to Step 4.

**If B (Keep in `docs/`):** Set `DOCS_DIR=docs` and skip Steps 2-3 — proceed to Step 4.

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

### 2b. Permission Mode

Resolve the *effective* mode first — the two project files are no longer where bypass lives:

```bash
source <(~/.claude/skills/koji/bin/koji-permission-mode)
echo "Effective mode: $EFFECTIVE_MODE (source: $MODE_SOURCE) | bypass: $EFFECTIVE_BYPASS | Claude Code: $CLAUDE_VERSION"
```

Fires only when `EFFECTIVE_BYPASS` is `false`. **Skip silently** when bypass is already in force (typically from `~/.claude/settings.json` — a user who set it once should not be re-asked in every new project) or when `MODE_SOURCE` is `disabled` (policy forbids bypass; nothing koji offers can change that).

Since Claude Code **2.1.257**, `permissions.defaultMode: bypassPermissions` set in `.claude/settings.json` or `.claude/settings.local.json` **does not take effect** — only user settings, managed settings, or the launch flag can set it. Earlier koji versions wrote that key into the local file; `/kick-off` Step 0i now offers to remove the inert leftover. koji **never writes `~/.claude/settings.json`**: a user-wide switch is the user's own call to make by hand.

**On Claude Code ≥ 2.1.257 (or `CLAUDE_VERSION=unknown`)** — use AskUserQuestion:

> Claude Code can prompt before each tool call (default), or auto-allow them in
> `bypassPermissions` mode. Project-scope bypass no longer takes effect, so koji
> can't set it for this repo alone; the per-project equivalent is a launch flag.
> Recommended for trusted personal projects; keep prompts for shared/prod work
> where per-tool review is part of the workflow.

Options:
- A) Per-launch bypass — I'll show the launch flag and an alias (recommended for personal projects)
- B) Keep per-tool prompts — standard Claude Code behavior

If A: print the tip and do nothing else:

> Launch with `claude --permission-mode bypassPermissions` in this repo. To make it one word:
> `alias claude-yolo='claude --permission-mode bypassPermissions'` in your shell rc.
> To turn bypass on for every project instead, set `permissions.defaultMode: bypassPermissions`
> yourself in `~/.claude/settings.json` — koji does not write that file.

If B: do nothing.

**On Claude Code < 2.1.257** — project-scope bypass still works; keep the original behavior. Use AskUserQuestion with the same two options worded as *A) Auto-allow tools — set `permissions.defaultMode: bypassPermissions` in `.claude/settings.local.json` (per-machine, never committed)* / *B) Keep per-tool prompts*. If A:

```bash
F="$PROJECT_ROOT/.claude/settings.local.json"
mkdir -p "$(dirname "$F")"
if [ -f "$F" ]; then
  TMP=$(mktemp) && jq '.permissions.defaultMode = "bypassPermissions"' "$F" > "$TMP" && mv "$TMP" "$F"
else
  printf '%s\n' '{"permissions": {"defaultMode": "bypassPermissions"}}' > "$F"
fi
```

If B: do nothing.

### 3. Create Scaffolding

Based on answers, create the following (skip files that already exist):

```
$DOCS_DIR/
├── agent-session.md          # from templates/$TEMPLATE/
├── AI_HANDOFF.md             # from templates/$TEMPLATE/
├── lessons.md                # from templates/$TEMPLATE/
├── SESSION_TEMPLATE.md       # from templates/$TEMPLATE/
├── CODEBASE_CONVENTIONS.md   # codebase-fit reference for /duet-plan + /duet-impl
├── plans/                    # cross-session implementation handbooks
│   └── .gitkeep
├── research/                 # cross-session unvalidated findings
│   └── .gitkeep
└── sessions/                 # archive directory
    └── (INDEX.md if dated strategy)
```

Copy templates from `~/.claude/skills/koji/templates/$TEMPLATE/` to `$PROJECT_ROOT/$DOCS_DIR/`.

**Note:** `TODO.md` is NOT created here. It gets created automatically by `/wrap` the first time task-related work is done — no empty scaffolding.

Also copy `SESSION_TEMPLATE.md` into `$DOCS_DIR/` so the project has a local reference.

**Plans + research scaffolding.** Create `$DOCS_DIR/plans/` and `$DOCS_DIR/research/` with a `.gitkeep` and brief `README.md` in each:

- **`plans/`** — implementation handbooks; `/duet-plan` locks, `/duet-impl` consumes.
- **`research/`** — investigation findings pending validation; default `status: unvalidated`.

Both surface in `/kick-off` (pending entries). `/duet-impl` Step 4 marks plans `completed` at end of run. Status field is optional — missing frontmatter degrades to the kind-default with `(inferred)` annotation.

Write `$DOCS_DIR/plans/README.md` with this content (outer fence uses four backticks so the inner three-backtick `yaml` block is preserved verbatim):

````markdown
# Plans

Implementation handbooks for designed-but-not-yet-implemented work. One file per
plan. Use `koji-plans-research --set-status <path> <new>` to update status.

Frontmatter (optional, all fields):

```yaml
---
status: pending | in-progress | completed | archived   # default: pending
origin-session: YYYY-MM-DD
target: implementation
next-step: brief one-line hint surfaced at /kick-off
---
```
````

Write `$DOCS_DIR/research/README.md`:

````markdown
# Research

Investigation findings whose conclusions need validation before becoming
canonical (e.g., ROADMAP / ASSESSMENT updates). One file per investigation.

Frontmatter (optional, all fields):

```yaml
---
status: unvalidated | validated | archived             # default: unvalidated
origin-session: YYYY-MM-DD
target: validation
next-step: brief one-line hint surfaced at /kick-off
---
```
````

**Codebase-fit scaffolding.** Scaffold `$DOCS_DIR/CODEBASE_CONVENTIONS.md` — the durable codebase-fit reference that `/duet-plan` reads (Codebase Fit Contract) and `/duet-impl` enforces (codebase-fit review). It is a *hub*: it points to the project's own pre-existing convention docs and owns only what those lack — koji's exemplar index and rejected-patterns. It grows from `/duet-impl` review findings, so it ships sparse.

First, discover the project's existing convention docs — run the scanner and read the lines it prints (one path per line on stdout; do **not** `source` it):

```bash
CANDIDATES=$(~/.claude/skills/koji/bin/koji-scan-conventions)
[ -n "$CANDIDATES" ] && printf 'Convention candidates:\n%s\n' "$CANDIDATES" || echo "Convention candidates: (none)"
```

- **If `$CANDIDATES` is non-empty:** fire one `AskUserQuestion` — list the candidate paths and ask which are the project's *authoritative code conventions* (multi-select; the user may pick a subset, or none). koji will only *point at* the confirmed docs — never copy or edit them.
- **If empty:** skip the prompt; there is nothing to confirm.

Then scaffold the hub by running `koji-scaffold-conventions` with the confirmed convention-doc paths as arguments — e.g. `koji-scaffold-conventions CONTRIBUTING.md .cursorrules` — or with **no arguments** when there are none. The helper (`~/.claude/skills/koji/bin/koji-scaffold-conventions`) owns the canonical `CODEBASE_CONVENTIONS.md` stub format and **skips silently if the file already exists** — it never clobbers an existing hub.

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
  # prompts: on         # off = no AskUserQuestion during /wrap (documented auto policy applies)
  # commit_gate: auto   # auto = `npm run lint:check` when package.json has it | none | "<command>"
# duet:
#   reviewer: codex     # codex | claude | claude-rounds+codex-final
```

Set `docs_dir` to the value determined by the workflow: `.koji` for fresh installs and relocations, `docs` if the user chose to keep files in `docs/`.

### 5. Wire CLAUDE.md

Check if `CLAUDE.md` exists in the project root.

**If `CLAUDE.md` exists:**
- Check if it already contains a koji session section (look for `## Session Management` or `/wrap` or `/take-note` or `koji`)
- If not found, append the following block at the end:

```markdown

## Session Management (koji)

Session docs in `$DOCS_DIR/` (handoff, lessons, session log + Load on Kick-Off) and `$TODO_FILE` at project root. Use `/kick-off` to start a session, `/wrap` to end, `/take-note` mid-session. For substantial research worth keeping, capture to `$DOCS_DIR/research/` — see `~/.claude/skills/koji/references/research-capture-eval.md` for criteria.
```

**If `CLAUDE.md` does not exist:**
- Create a minimal `CLAUDE.md` with project name and the session management block:

```markdown
# <PROJECT_NAME>

## Session Management (koji)

Session docs in `$DOCS_DIR/` (handoff, lessons, session log + Load on Kick-Off) and `$TODO_FILE` at project root. Use `/kick-off` to start a session, `/wrap` to end, `/take-note` mid-session. For substantial research worth keeping, capture to `$DOCS_DIR/research/` — see `~/.claude/skills/koji/references/research-capture-eval.md` for criteria.
```

(Substitute the actual resolved values — `$DOCS_DIR` to e.g. `.koji` or `docs`, `$TODO_FILE` to e.g. `TODO.md` or `TODOS.md` — when writing to CLAUDE.md. Do not write the literal `$DOCS_DIR` / `$TODO_FILE` strings.)

(Earlier koji versions inlined auto-read instructions for handoff/TODO/lessons. Pointer-only defers to `/kick-off` instead, avoiding duplication and a wrong TODO.md path.)

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
Codebase conventions: $DOCS_DIR/CODEBASE_CONVENTIONS.md (grows via /duet-*)

Available commands:
  /kick-off   — Start a session (loads last session + handoff context)
  /wrap       — End-of-session wrap (lessons + handoff + session log + commit)
  /take-note  — Mid-session progress save
  /koji-init  — Re-run this setup
```
