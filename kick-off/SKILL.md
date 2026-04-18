---
description: "Start a new session with context. Reads the last session entry and AI handoff to bootstrap the agent, or takes a custom focus as argument."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

# Kick Off

Run the preamble to detect project configuration and environment:

```bash
source <(~/.claude/skills/koji/bin/koji-detect)

# --- Version check ---
KOJI_VERSION=$(cat "$KOJI_SKILLS/VERSION" 2>/dev/null | tr -d '[:space:]')
KOJI_REMOTE_VERSION=$(curl -sf --max-time 3 "https://raw.githubusercontent.com/BruhGreg/koji/main/VERSION" 2>/dev/null | tr -d '[:space:]')

echo "=== koji kick-off ==="
echo "Project: $PROJECT_NAME"
echo "koji: v$KOJI_VERSION"

# Version comparison
if [ -n "$KOJI_REMOTE_VERSION" ] && [ "$KOJI_VERSION" != "$KOJI_REMOTE_VERSION" ]; then
  echo "UPDATE_AVAILABLE: v$KOJI_VERSION → v$KOJI_REMOTE_VERSION"
else
  echo "koji: up to date"
fi

echo "Has session log: $HAS_SESSION_LOG"
echo "Has handoff: $HAS_HANDOFF"
echo "Has lessons: $HAS_LESSONS"
echo "Has TODO: $HAS_TODO"

# --- Detect gstack ---
if [ -d "$HOME/.claude/skills/gstack" ] && [ -f "$HOME/.claude/skills/gstack/VERSION" ]; then
  GSTACK_VERSION=$(cat "$HOME/.claude/skills/gstack/VERSION" 2>/dev/null | tr -d '[:space:]')
  echo "gstack: v$GSTACK_VERSION (available)"
  echo "HAS_GSTACK=true"
else
  echo "gstack: not installed"
  echo "HAS_GSTACK=false"
fi
```

If `HAS_SESSION_LOG` is `false` or `HAS_HANDOFF` is `false`, tell the user to run `/koji-init` first and stop.

---

## Workflow

### 0a. Migration check (docs/ → .koji/)

Run the migration detection script:

```bash
source <(~/.claude/skills/koji/bin/koji-migrate-check)
echo "Needs migration: $KOJI_NEEDS_MIGRATION"
echo "Legacy files: $KOJI_LEGACY_FILES"
```

If `KOJI_NEEDS_MIGRATION` is `true`, tell the user:

> Found koji files in legacy location: $KOJI_LEGACY_FILES
> Your `.koji.yaml` points to `.koji/`.
>
> 1. **Migrate** — move files to `.koji/` and update references
> 2. **Skip** — keep them in `docs/` (update `.koji.yaml` to match)

If **Migrate**: create `.koji/`, move each file from `docs/` to `.koji/`, move `docs/sessions/` to `.koji/sessions/` if present, update `CLAUDE.md` and agent config references, re-run koji-detect.
If **Skip**: patch `.koji.yaml` to `docs_dir: docs`, continue normally.
If `KOJI_NEEDS_MIGRATION` is `false`, skip silently.

### 0b. TODO migration (docs dir → project root)

If `$TODO_NEEDS_MIGRATION` is `true`, the TODO file is inside the docs dir (e.g., `.koji/TODO.md`) but the canonical location is the project root. Migrate it:

1. Move the file: `$DOCS_PATH/$TODO_FILE` → `$PROJECT_ROOT/$TODO_FILE`
2. Scan the project for references to the old path and update them:
   - `CLAUDE.md` — update any `.koji/TODO.md` references to `TODO.md`
   - `$DOCS_PATH/AI_HANDOFF.md` — update links like `[TODO.md](TODO.md)` to `[TODO.md](../TODO.md)` or absolute
   - `AGENTS.md` — update `.koji/TODO.md` references
   - `.koji.yaml` — remove `todo.file` if it was set to the old path
3. If `COMPLETED_TASKS.md` exists in the docs dir and references `TODO.md`, update those links too.
4. Tell the user: `Moved $TODO_FILE to project root (koji 0.3.0 convention).`
5. Re-source koji-detect to update `$TODO_PATH`.

If `$TODO_NEEDS_MIGRATION` is `false`, skip silently.

### 0c. Version check

If the preamble shows `UPDATE_AVAILABLE`:

Use AskUserQuestion:

> koji update available: v{old} → v{new}

Options:
- A) Update now — pulls latest and re-runs setup (~2 seconds)
- B) Skip this time
- C) Always update — auto-update on every kick-off

If A: run `cd ~/.claude/skills/koji && git pull origin main && ./setup` then continue.
If C: run `koji-config set auto_update true` then update.
If B: continue without updating.

If `koji-config get auto_update` returns `true` and an update is available, update silently without asking — just show: `koji updated: v{old} → v{new}`.

### 0d. Load-on-Kick-Off migration (v0.4.3)

Run the one-shot migrator:

```bash
source <(~/.claude/skills/koji/bin/koji-migrate-load-on-kickoff)
```

It moves any `## Load on Kick-Off` section from `AI_HANDOFF.md` into `agent-session.md` (above the first `## Session:` entry). Idempotent — no-op after first successful run.

- If `KOJI_MIGRATED_LOAD_KO=true`: print `$KOJI_MIGRATION_MSG` once, continue.
- If `KOJI_MIGRATED_LOAD_KO=cleanup`: print `$KOJI_MIGRATION_MSG` once (stray duplicate stripped), continue.
- If `KOJI_MIGRATED_LOAD_KO=false`: silent, continue.

### 1. Check for user-provided focus

If the user typed text after `/kick-off` (e.g., `/kick-off build the news landing page`), use that as the **session focus** — skip reading the last session's starter prompt and use the user's intent instead. Still read handoff and lessons for context.

If no args provided, proceed to step 2.

### 2. Read context (always)

Read these files and internalize the content — do NOT dump them back to the user:

1. `$DOCS_PATH/AI_HANDOFF.md` — project state, architecture rules, gotchas
2. `$TODO_PATH` — open tasks, tech debt, blockers (if `$HAS_TODO` is `true`)
3. `$DOCS_PATH/lessons.md` — recent corrections and gotchas (focus on the top 10 entries)
4. `$DOCS_PATH/agent-session.md` — read the **last** session entry for continuity (what was done, notes for next session)

### 2b. Gather extended context (tiered)

Three tiers of additional context. No config needed — triggers are automatic.

**Tier 1 — Baseline (always):**

Run:

```bash
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ACTIVE_PLANS=$(ls "$PROJECT_ROOT/.claude/plans/" 2>/dev/null | grep -c '\.md$' || echo 0)
echo "Branch: $CURRENT_BRANCH"
echo "Uncommitted changes: $UNCOMMITTED"
echo "Active plans: $ACTIVE_PLANS"
```

Internalize. Include branch in the brief header. Warn if uncommitted changes > 0. If active plans > 0, list them as available context.

**Tier 2 — Reference-follow (if session note has references):**

If the "Notes for Next Session" from step 2 mentions specific files, directories, plans, or modules:

1. List `$PROJECT_ROOT/.claude/plans/` — read any plan whose filename matches keywords from the note
2. Grep `$DOCS_PATH/$ARCHIVE_DIR/` for archived sessions matching the focus topic — read the top 2 matches (headers + summary only, not full entries)
3. If the note mentions specific file paths, read them if they exist and are <200 lines

Internalize all findings — do not dump raw content to user. Add a "Context loaded:" line to the brief.

**Skip** if session note is generic ("continue from where we left off") or absent.

**Tier 3 — Codebase orient (if first session, stale handoff, or no session note):**

Triggers when ANY of:
- `agent-session.md` has no session entries (just created by `/koji-init`, only header/template content)
- Last session entry date is >7 days ago (stale)
- Last session entry has no "Notes for Next Session" content (no direction)

Run:

```bash
# Tech stack
for f in package.json go.mod Cargo.toml pyproject.toml Gemfile pom.xml composer.json; do
  [ -f "$PROJECT_ROOT/$f" ] && echo "STACK_FILE: $f"
done
# Structure
find "$PROJECT_ROOT" -maxdepth 2 -type d \
  ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.koji/*' \
  ! -path '*/__pycache__/*' ! -path '*/dist/*' ! -path '*/build/*' \
  ! -path '*/vendor/*' ! -path '*/.git' 2>/dev/null | head -30
# Recent commits
git log --oneline -5 2>/dev/null
# Key docs
for f in ARCHITECTURE.md CONTRIBUTING.md API.md; do
  [ -f "$PROJECT_ROOT/$f" ] && echo "DOC: $f"
done
```

Read detected stack files (just the name/version/framework fields, not the entire file). Read key doc headers (first 10 lines only). Internalize — add 1-2 lines to the brief.

### 2c. Load user-curated docs (opt-in via `## Load on Kick-Off` section)

Projects can opt specific docs into kick-off context by adding a section to `agent-session.md` (above the first `## Session:` entry, alongside the rotating session log):

```markdown
## Load on Kick-Off

- [SPLIT_TUNNEL_ROUTING](docs/SPLIT_TUNNEL_ROUTING.md)
- [ENDPOINT_RESOLUTION](docs/ENDPOINT_RESOLUTION.md)
- docs/AUTH_FLOW.md
- /DESIGN.md
```

The section is optional. If it's absent, skip this entire step silently.

**Parse the section:**

1. Read `$DOCS_PATH/agent-session.md` (already in context from step 2)
2. Locate the heading line matching `^## Load on Kick-Off\s*$` (exact H2, case-sensitive, allows trailing whitespace)
3. If not found → skip this step silently
4. Between that heading and the next `^## ` heading (or EOF), collect each bullet line matching `^\s*[-*]\s+(.+)$`
5. For each bullet:
   - Extract the `.md` path — accept either:
     - Markdown link form: `[text](path.md)` — extract the `path.md` portion
     - Plain path form: just the `.md` path as text
   - Skip if the "path" is an external URL (`http://`, `https://`, `mailto:`)
   - Skip if the path doesn't end in `.md`
   - Resolve relative paths against `$PROJECT_ROOT` (not against `agent-session.md`'s directory — bullets reference project-rooted paths)
   - Paths starting with `/` are treated as project-rooted too (strip the leading `/`)

**For each valid path:**

1. If the file doesn't exist → log a 1-line warning `warn: Load on Kick-Off references <path> (missing)` and skip
2. Read the file using the `Read` tool, internalize its content
3. **Drift check** — parse the doc's YAML frontmatter for a `covers` declaration:

   ```markdown
   ---
   covers:
     - src/auth/
     - server/routes/auth/
   ---
   ```

   If the doc's first non-empty line is `---`, parse YAML up to the next `---`. Look for top-level `covers` as a list of paths.

   If the doc has no frontmatter or no `covers` list, no drift check runs. The doc still loads. `/inspect-doc-drift` will surface it as a candidate for tagging.

4. **If a `covers` list was parsed**:
   - Read `.koji.yaml` for `docs.stale_threshold` (default `10`)
   - Read `.koji.yaml` for `docs.stale_action` (default `warn`; options: `warn` = load but warn, `skip` = don't load)
   - **Orphan check**: for each covered path, verify it exists in the working tree (`[ -e "$PROJECT_ROOT/$path" ]`). If ANY covered path is missing → doc is **orphan**.
   - **Drift compute**: count commits in covered paths since doc's last-modified commit.
   - **Decision**:
     - Orphan → always load + print stronger warning: `⚠ <doc>: covered path '<missing>' no longer exists. Doc may describe removed code.`
     - Drift > threshold (not orphan) → behave per `docs.stale_action` (`warn` loads with `⚠ <doc>: <N> commits behind`; `skip` drops the load with `skipped: <doc> (<N> behind)`)
     - Drift ≤ threshold → load silently

5. Track per-doc outcome (loaded / loaded-warn / skipped / orphan / missing) for the brief summary.

**Config extraction from `.koji.yaml`** (reuse the existing lightweight parse pattern):

```bash
STALE_THRESHOLD=$(grep -E '^\s*stale_threshold\s*:' "$PROJECT_ROOT/.koji.yaml" 2>/dev/null | head -1 | sed -E 's/.*:\s*([0-9]+).*/\1/' | grep -E '^[0-9]+$' || echo 10)
STALE_ACTION=$(grep -E '^\s*stale_action\s*:' "$PROJECT_ROOT/.koji.yaml" 2>/dev/null | head -1 | sed -E 's/.*:\s*([a-z_]+).*/\1/' || echo warn)
```

**In the brief** (step 3 below), append one line summarizing the doc-load pass:

> Docs: <loaded> loaded, <stale> stale, <orphan> orphan, <untagged> untagged, <missing> missing

Counts:
- `loaded` = docs that made it into context (including tagged-fresh + untagged — untagged docs still load)
- `stale` = tagged docs with drift > threshold
- `orphan` = tagged docs whose covered paths no longer exist
- `untagged` = loaded docs with no `covers` frontmatter (no drift signal)
- `missing` = bullet paths that didn't resolve to a file

If `stale > 0`, `orphan > 0`, or `untagged > 0`, also list specifics on the next line:

> Attention: orphan docs/A.md, stale docs/B.md (12), untagged docs/C.md docs/D.md. Run `/inspect-doc-drift` to fix.

**Fail-safe**: if any part of this step errors (config parse fails, regex glitch, unreadable `.koji.yaml`), degrade silently to "no Load on Kick-Off section processed" — never block kick-off on doc-loading issues.

---

### 3. Brief the user

Output a concise briefing (not a wall of text):

> **Session start — $PROJECT_NAME** (`$CURRENT_BRANCH`)
>
> Last session: [1-line summary of what was done]
> Handoff says: [1-line — highest priority open task from TODO.md if it exists, otherwise from AI_HANDOFF.md]
> Watching out for: [1-line gotcha from lessons, if relevant — otherwise skip]
> [If tier 2: Context loaded: read plan X, 2 related archived sessions]
> [If tier 3: Codebase: React 18 + Express, 12 source dirs]
> [If uncommitted > 0: Note: N uncommitted changes from previous session]
>
> **Focus:** [user's arg if provided, OR the "Notes for Next Session" from the last entry]

### 4. Suggest gstack workflows (only if gstack detected)

If `HAS_GSTACK` is `true`, analyze the current dev phase from the handoff and session log, then suggest **2-3 relevant gstack skills** — not all of them, just what makes sense right now.

**Phase detection heuristics:**

- **Planning/early stage** (handoff has mostly unchecked items, few completed):
  - Suggest: `/office-hours` (brainstorm), `/plan-eng-review` (lock architecture)

- **Active development** (in-progress items, recent code changes):
  - Suggest: `/investigate` (if debugging), `/browse` (if frontend), `/design-review` (if UI work)

- **Pre-ship** (feature complete, needs polish/review):
  - Suggest: `/qa` (test + fix), `/review` (pre-landing diff review), `/ship` (create PR)

- **Post-ship** (just deployed or merged):
  - Suggest: `/canary` (monitor production), `/document-release` (update docs)

- **Security/infrastructure work**:
  - Suggest: `/cso` (security audit), `/careful` (safety guardrails)

Format as a short suggestion, not a menu:

> **gstack:** Looks like active frontend work — `/browse` to preview, `/design-review` for visual polish, or `/qa` when ready to test.

If gstack is not detected, skip this step entirely — no output.

### 5. Ready

End with:

> Ready to go. What's first?
