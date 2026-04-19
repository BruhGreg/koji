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

- [<label>](docs/FOO.md)
- [<label>](docs/BAR.md)
- docs/BAZ.md
- /QUX.md
```

The section is optional. If it's absent, skip this entire step silently. Bullets accept markdown-link form `[label](path.md)` or plain path form; paths starting with `/` are treated as project-rooted.

**Query per-bullet status via the shared helper** (`koji-doc-status`, also used by `/inspect-doc-drift`):

```bash
LOKO_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --load-on-kickoff 2>/dev/null || true)
STALE_ACTION=$(grep -E '^[[:space:]]*stale_action[[:space:]]*:' "$PROJECT_ROOT/.koji.yaml" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*([a-z_]+).*/\1/' || true)
[ -n "${STALE_ACTION:-}" ] || STALE_ACTION=warn
```

Each record in `$LOKO_REPORT` is tab-separated:

```
<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>
```

with `status ∈ {fresh, stale, orphan, exempt, untagged, missing, malformed}`. The helper already honors `docs.stale_threshold` from `.koji.yaml` (default `10`) when deciding `fresh` vs `stale`. If `$LOKO_REPORT` is empty, the section is absent or has no valid bullets — skip the rest of this step silently.

**For each record — decide load + warning based on `status` and `$STALE_ACTION`:**

- `missing` → emit `warn: Load on Kick-Off references <path> (missing)`; do not load.
- `malformed` → emit `warn: malformed frontmatter in <path>`; Read the file anyway (count as `untagged`).
- `orphan` → Read the file; emit `⚠ <path>: covered path '<missing>' no longer exists. Doc may describe removed code.`; count as `orphan`.
- `stale` → apply `$STALE_ACTION`:
  - `warn` (default): Read the file; emit `⚠ <path>: <drift> commits behind`; count as `stale`.
  - `skip`: do not load; emit `skipped: <path> (<drift> behind)`; count as `stale-skipped`.
- `fresh` → Read the file silently; count as `loaded`.
- `exempt` → Read the file silently; count as `loaded` (doc declared `covers: none` — intentionally untagged, no drift tracking expected).
- `untagged` → Read the file silently; count as `untagged` (loaded but no drift signal).

Use the `Read` tool for each file that should load — internalize content, do NOT dump it back to the user.

**Compute the load size** after reading:

```bash
# Total chars across every successfully-read doc. Iterate each loaded path:
TOTAL_CHARS=$(cat <loaded_paths> | wc -c | tr -d ' ')
TOTAL_TOKENS=$((TOTAL_CHARS / 4))   # standard ~4 chars/token approximation
```

Also build a per-doc size list (path → chars) — keep it sorted by size descending, used if the budget warning fires.

**Read budget config from `.koji.yaml`** (both keys optional, defaults apply if absent). Keys MUST be inside a top-level `docs:` block to be honored — a stray `budget_warn_tokens:` under another block is ignored. Truthy values for `budget_silent` accept the full YAML-conventional set (`true`/`yes`/`on`/`1`, case-insensitive); anything else is treated as false:

```bash
# Scoped-to-docs: reader — emits the value of a key only if it lives inside `docs:`.
_koji_read_docs_key() {
  awk -v key="$1" '
    /^docs:/ { in_docs=1; next }
    /^[^[:space:]]/ && !/^docs:/ { in_docs=0 }
    in_docs && $0 ~ "^[[:space:]]+"key"[[:space:]]*:" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")   # strip trailing comment
      sub(/[[:space:]]*$/, "")
      # Strip surrounding quotes
      if (substr($0,1,1) == "\"" && substr($0,length($0),1) == "\"") $0 = substr($0,2,length($0)-2)
      if (substr($0,1,1) == "\047" && substr($0,length($0),1) == "\047") $0 = substr($0,2,length($0)-2)
      print; exit
    }
  ' "$PROJECT_ROOT/.koji.yaml" 2>/dev/null
}

BUDGET_WARN=$(_koji_read_docs_key budget_warn_tokens | grep -E '^[0-9]+$' || true)
[ -n "${BUDGET_WARN:-}" ] || BUDGET_WARN=15000

_budget_silent_raw=$(_koji_read_docs_key budget_silent || true)
case "$_budget_silent_raw" in
  true|TRUE|True|yes|YES|Yes|on|ON|On|1) BUDGET_SILENT=true ;;
  *) BUDGET_SILENT=false ;;
esac
```

**In the brief** (step 3 below), append one line summarizing the doc-load pass — always show size:

> Docs: <loaded> loaded (~<kchars>k chars / ~<ktokens>k tokens), <stale> stale, <orphan> orphan, <untagged> untagged, <missing> missing

Counts:
- `loaded` = total successfully-read files (fresh + exempt + untagged + stale-warned + orphan + malformed)
- `stale` = tagged docs with drift > threshold (loaded unless `stale_action=skip`)
- `orphan` = tagged docs whose covered paths no longer exist
- `untagged` = loaded docs with no `covers` frontmatter (no drift signal). Docs declaring `covers: none` are NOT counted here — that sentinel means "intentionally untagged".
- `missing` = bullet paths that didn't resolve to a file

If `stale > 0`, `orphan > 0`, or `untagged > 0`, also list specifics on the next line:

> Attention: orphan <path>, stale <path> (<drift>), untagged <path>. Run `/inspect-doc-drift` to fix.

### 2c'. Budget warning (only if over threshold)

If `$TOTAL_TOKENS > $BUDGET_WARN` **and** `$BUDGET_SILENT` is `false`, fire a warning with an action menu. Otherwise skip this sub-step silently.

Compute the suggested raise-to value:
```bash
RAISE_TO=$(( ((TOTAL_TOKENS * 12 / 10) / 1000 + 1) * 1000 ))   # current × 1.2, rounded up to next 1k
```

Pick the top 3 heaviest docs from the per-doc size list. Then `AskUserQuestion`:

> ⚠ Load on Kick-Off is consuming ~<ktokens>k tokens (threshold: <BUDGET_WARN/1000>k).
>
> Heaviest docs:
>   - <path> (~<N>k chars)
>   - <path> (~<N>k chars)
>   - <path> (~<N>k chars)
>
> **What would you like to do?**

Options:
- **A) Continue** — proceed with kick-off (default). No write. Warning will fire again next kick-off if still over.
- **B) Trim** — show the full per-doc size list, prompt the user for which bullets to remove from `## Load on Kick-Off` in `agent-session.md`. Edit the file to drop the chosen bullets. Does NOT touch the docs themselves.
- **C) Raise threshold** — bump `budget_warn_tokens` in `.koji.yaml` to `$RAISE_TO`. Show the user the exact diff first, then apply on confirm.
- **D) Silence** — set `budget_silent: true` in `.koji.yaml`. Future kick-offs still show size but no menu. Show diff, confirm, apply.

**`.koji.yaml` edit mechanics** (for C and D — done via the `Edit` tool, not sed):

1. Read `.koji.yaml`. Identify whether a top-level `docs:` block exists.
2. **If a `docs:` block exists**: insert or update the target key (`budget_warn_tokens` or `budget_silent`) as a sibling of existing keys like `stale_threshold` / `stale_action`. Preserve all other keys, comments, and ordering.
3. **If no `docs:` block exists**: append a new `docs:` block at the end of the file.
4. **Before writing**, show the user a minimal diff:

   > I'll update `.koji.yaml`:
   >
   > ```diff
   >  docs:
   >    stale_threshold: 10
   > +  budget_warn_tokens: 26000
   > ```
   >
   > Proceed? (y/n)

5. On `y`: apply via `Edit`. Confirm: `Raised budget_warn_tokens to 26k.` / `Silenced budget warnings.`
6. On `n`: no write, warning stays for this session.

**Edge case — no `.koji.yaml` exists at all** (rare; file is normally created by `/koji-init`): omit options C and D from the menu. Show A and B only, plus the hint `Run /koji-init to persist koji config.`

**Fail-safe**: if size computation or yaml parsing errors, skip the warning menu silently and continue. Budget awareness is a nice-to-have, not a blocker.

**Fail-safe**: if the helper errors or returns unparseable output, degrade silently — never block kick-off on doc-loading issues.

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
