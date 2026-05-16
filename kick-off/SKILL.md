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

### 0e. Record session start

Write a session-start sentinel so `/wrap` can find "files touched this session" deterministically. Do NOT rely on `HEAD@{1}` — that's reflog movement (branch switches, rebases, amends all break it), not a session boundary.

The sentinel lives at `$SESSION_START_FILE` (resolved by `koji-detect` to `~/.config/koji/sessions/<project>-<hash>/start`). Global state, NEVER in the repo, so it can't be committed by accident.

```bash
mkdir -p "$SESSION_DIR"
if [ ! -f "$SESSION_START_FILE" ]; then
  # --verify so empty repos skip cleanly. Without it, `git rev-parse HEAD`
  # writes the literal "HEAD" to stdout (swallowed by 2>/dev/null) — the
  # sentinel would later mask the entire first session's diff.
  if HEAD_SHA=$(git rev-parse --verify HEAD 2>/dev/null); then
    printf '%s\n' "$HEAD_SHA" > "$SESSION_START_FILE"
  fi
fi
```

**First-write-wins:** if the file already exists (a previous `/kick-off` was not followed by `/wrap`), do NOT overwrite — the real session start is preserved across accidental re-kick-offs. `/wrap` deletes the file at end-of-session, so the next `/kick-off` creates a fresh marker.

**Empty-repo behavior:** if the project has no commits yet (no HEAD), the sentinel is NOT written this kick-off — the next `/kick-off` after the first commit will write it cleanly. /wrap in the meantime degrades to working-tree-only diff (Pass A weakens, other passes unaffected).

### 0f. CLAUDE.md old-block migration

Earlier koji versions (< v0.5.0) wrote a 3-instruction auto-read block into project `CLAUDE.md` that duplicated `/kick-off`'s job and pointed `TODO.md` to the wrong path. Current `/koji-init` writes a pointer-only block; this step migrates existing projects.

Detect the old block:

```bash
OLD_BLOCK_DETECTED=false
if [ -f "$PROJECT_ROOT/CLAUDE.md" ] && awk '
  /^## Session Management \(koji\)/ { in_block=1; next }
  in_block && /^## / { in_block=0 }
  in_block && /^On session start:/ { found=1 }
  END { exit found ? 0 : 1 }
' "$PROJECT_ROOT/CLAUDE.md" 2>/dev/null; then
  OLD_BLOCK_DETECTED=true
fi

CLAUDE_MD_DECLINED=$(~/.claude/skills/koji/bin/koji-config get "claude_md_migration_declined_$SESSION_HASH" 2>/dev/null || true)
```

If `OLD_BLOCK_DETECTED=true` AND `CLAUDE_MD_DECLINED` is not `true`, use AskUserQuestion:

> Found old koji `## Session Management (koji)` block in CLAUDE.md with 3 auto-read instructions (one of which points TODO.md to the wrong path). Modern koji uses a pointer-only block that defers to `/kick-off` for context loading. Migrate?

Options:
- **A) Migrate now** (recommended) — replace the block with the pointer-only version
- **B) Skip this time** — ask again next kick-off
- **C) Decline permanently for this project** — never ask again

**If A**, rewrite the block atomically:

```bash
NEW_BLOCK_FILE=$(mktemp)
CLAUDE_TMP=$(mktemp "$PROJECT_ROOT/CLAUDE.md.XXXXXX")
cat > "$NEW_BLOCK_FILE" <<EOF
## Session Management (koji)

Session docs in \`$DOCS_DIR/\` (handoff, lessons, session log + Load on Kick-Off) and \`$TODO_FILE\` at project root. Use \`/kick-off\` to start a session, \`/wrap\` to end, \`/take-note\` mid-session.
EOF

awk -v new_block_file="$NEW_BLOCK_FILE" '
  BEGIN {
    while ((getline line < new_block_file) > 0) {
      new_block = (new_block == "" ? line : new_block ORS line)
    }
    close(new_block_file)
  }
  /^## Session Management \(koji\)/ {
    print new_block
    print ""
    in_block=1
    next
  }
  in_block && /^## / { in_block=0 }
  !in_block { print }
' "$PROJECT_ROOT/CLAUDE.md" > "$CLAUDE_TMP" \
  && mv "$CLAUDE_TMP" "$PROJECT_ROOT/CLAUDE.md" \
  || { rm -f "$CLAUDE_TMP" "$NEW_BLOCK_FILE"; echo "ERROR: migration failed; CLAUDE.md unchanged" >&2; return 1 2>/dev/null || exit 1; }
rm -f "$NEW_BLOCK_FILE"
```

Tell the user (only after the `mv` succeeded): `Migrated CLAUDE.md to pointer-only koji block.`

**If B**: do nothing this session — the check fires again next kick-off.

**If C**: persist the decline so this prompt never fires again for this project:

```bash
~/.claude/skills/koji/bin/koji-config set "claude_md_migration_declined_$SESSION_HASH" true
```

Tell the user: `Won't ask again FOR THIS PROJECT. Edit CLAUDE.md manually if you change your mind, or unset with: koji-config set claude_md_migration_declined_$SESSION_HASH false` (the `$SESSION_HASH` namespacing keeps the decline project-scoped).

### 1. Check for user-provided focus

If the user typed text after `/kick-off` (e.g., `/kick-off build the news landing page`), use that as the **session focus** — skip reading the last session's starter prompt and use the user's intent instead. Still read handoff and lessons for context.

If no args provided, proceed to step 2.

### 2. Read context (always)

Read these files and internalize the content — do NOT dump them back to the user:

1. `$DOCS_PATH/AI_HANDOFF.md` — project state, architecture rules, gotchas
2. `$TODO_PATH` — open tasks, tech debt, blockers (if `$HAS_TODO` is `true`)
3. **Lessons (focus-filtered).** Don't read all of `$DOCS_PATH/lessons.md` — load the relevant subset via the helper. Derive a focus string from (a) the user-provided focus arg if any, (b) the last session's "Notes for Next Session" field (read from `$DOCS_PATH/agent-session.md`), and (c) the first 3 open items in `$TODO_PATH` if `$HAS_TODO`. Concatenate with spaces:

   ```bash
   FOCUS=""
   [ -n "${USER_FOCUS:-}" ] && FOCUS="$USER_FOCUS"
   if [ -f "$DOCS_PATH/agent-session.md" ]; then
     # Latest Notes for Next Session (wrap appends at bottom).
     NOTES=$(awk '
       /^### Notes for Next Session[[:space:]]*$/ { capturing=1; buf=""; next }
       capturing && /^## |^### / { capturing=0 }
       capturing { buf = buf ORS $0 }
       END { print buf }
     ' "$DOCS_PATH/agent-session.md" 2>/dev/null | head -20)
     FOCUS="$FOCUS $NOTES"
   fi
   if [ "$HAS_TODO" = "true" ] && [ -f "$TODO_PATH" ]; then
     # Top of TODO.md, sans Completed. Template uses heading-style tasks,
     # so dumb-include (not `grep '^- \[ \]'`) is intentional.
     TODOS=$(awk '/^## Completed/{exit} 1' "$TODO_PATH" 2>/dev/null | head -30)
     FOCUS="$FOCUS $TODOS"
   fi
   LESSONS=$(~/.claude/skills/koji/bin/koji-doc-status --lessons-relevant --focus "$FOCUS" --limit 8 2>/dev/null || true)
   ```

   Internalize `$LESSONS` — these are the lessons most relevant to this session, plus a recent baseline. **If the helper fails or returns empty**, fall back to reading the top of `lessons.md` directly (first 10 entries) so kick-off still works without focus context. Cold-start (no focus signals — fresh session with no args, empty Notes, no TODO) returns top 10 by recency automatically, matching pre-v0.5 behavior.
4. `$DOCS_PATH/agent-session.md` — read the **last** session entry for continuity (what was done, notes for next session)

### 2b. Gather extended context (tiered)

Three tiers of additional context. No config needed — triggers are automatic.

**Tier 1 — Baseline (always):**

Run:

```bash
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
[ -n "$CURRENT_BRANCH" ] || CURRENT_BRANCH="detached"   # --show-current prints empty (not non-zero) on detached HEAD
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Active plans + research entries from $PLANS_DIR and $RESEARCH_DIR.
# Filter rules:
#   plans     → status ∈ {pending, in-progress} AND status_source ∈ {explicit, inferred}
#   research  → status = unvalidated AND status_source ∈ {explicit, inferred}
#   invalid   → kept separately for the Frontmatter warnings line
PLANS_RESEARCH=$(~/.claude/skills/koji/bin/koji-plans-research --list 2>/dev/null || true)
ACTIVE_PLANS=$(printf '%s\n' "$PLANS_RESEARCH" | awk -F'\t' '
  $2 == "plan" && $4 != "invalid" && ($3 == "pending" || $3 == "in-progress")
' | wc -l | tr -d ' ')
ACTIVE_RESEARCH=$(printf '%s\n' "$PLANS_RESEARCH" | awk -F'\t' '
  $2 == "research" && $4 != "invalid" && $3 == "unvalidated"
' | wc -l | tr -d ' ')
INVALID_FM=$(printf '%s\n' "$PLANS_RESEARCH" | awk -F'\t' '$4 == "invalid"' | wc -l | tr -d ' ')

echo "Branch: $CURRENT_BRANCH"
echo "Uncommitted changes: $UNCOMMITTED"
echo "Active plans: $ACTIVE_PLANS"
echo "Active research: $ACTIVE_RESEARCH"
[ "$INVALID_FM" -gt 0 ] && echo "Frontmatter warnings: $INVALID_FM"
```

Internalize. Include branch in the brief header. Warn if uncommitted changes > 0.

If `$ACTIVE_PLANS > 0` or `$ACTIVE_RESEARCH > 0`, **render one line per kind** in the brief (Step 3) — only when the count is positive — formatted as:

> **Pending plans:** <slug-1> (in-progress), <slug-2> (pending, inferred)
> **Pending research:** <slug-3> (UNVALIDATED — <next-step from frontmatter>)

The `(inferred)` annotation fires when `status_source = inferred` (file has no YAML status; default applied). The trailing `— <next-step>` on research lines comes from the `next-step:` frontmatter field; omit the dash and the string when the field is empty (`-`).

If `$INVALID_FM > 0`, list the invalid entries on a separate line so the user notices the typo and can fix it:

> **Frontmatter warnings:** <path> (invalid status: `<raw>`)

Filter records by walking `$PLANS_RESEARCH` (tab-separated `path\tkind\tstatus\tstatus_source\torigin\ttarget\tnext_step` per row).

**Tier 2 — Reference-follow (if session note has references):**

If the "Notes for Next Session" from step 2 mentions specific files, directories, plans, or modules:

1. List `$PLANS_DIR` and `$RESEARCH_DIR` — read any plan/research file whose filename matches keywords from the note
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
STALE_ACTION=$(awk '
  /^docs:[[:space:]]*(#.*)?$/ { in_docs=1; next }
  /^[^[:space:]]/ && !/^docs:/ { in_docs=0 }
  in_docs && /^[[:space:]]+stale_action[[:space:]]*:/ {
    sub(/^[[:space:]]+stale_action[[:space:]]*:[[:space:]]*/, "")
    sub(/[[:space:]]+#.*$/, "")
    sub(/[[:space:]]*$/, "")
    # Strip surrounding quotes (YAML allows `stale_action: "skip"`)
    n = length($0)
    if (n >= 2) {
      f = substr($0, 1, 1); l = substr($0, n, 1)
      if ((f == "\"" && l == "\"") || (f == "\047" && l == "\047")) $0 = substr($0, 2, n - 2)
    }
    print; exit
  }
' "$PROJECT_ROOT/.koji.yaml" 2>/dev/null | grep -E '^[a-z_]+$' || true)
[ -n "${STALE_ACTION:-}" ] || STALE_ACTION=warn
```

Each record in `$LOKO_REPORT` is tab-separated:

```
<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>
```

with `status ∈ {fresh, stale, orphan, exempt, untagged, working-doc, missing, malformed}`. The helper already honors `docs.stale_threshold` from `.koji.yaml` (default `10`) when deciding `fresh` vs `stale`. If `$LOKO_REPORT` is empty, the section is absent or has no valid bullets — skip the rest of this step silently.

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
- `working-doc` → Read the file silently; count as `loaded` (file under `$PLANS_DIR/` or `$RESEARCH_DIR/` — koji working docs, never code-coverage docs; drift bookkeeping doesn't apply).

Use the `Read` tool for each file that should load — internalize content, do NOT dump it back to the user.

**Compute the load size** after reading:

```bash
# Total chars across every successfully-read doc. Iterate each loaded path:
TOTAL_CHARS=$(cat <loaded_paths> | wc -c | tr -d ' ')
TOTAL_TOKENS=$((TOTAL_CHARS / 4))   # standard ~4 chars/token approximation
```

Also build a per-doc size list (path → chars) — keep it sorted by size descending, used if the budget warning fires.

**Read budget config from `.koji.yaml`** (both keys optional). Keys MUST live inside the top-level `docs:` block to be honored. `budget_silent` accepts `true`/`yes`/`on`/`1` (case-insensitive); anything else is false:

```bash
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

**In the brief** (step 3 below), append one line summarizing the doc-load pass — always show size, and always include all four count buckets even when zero (consistent shape makes drift/untagged growth obvious across sessions):

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

If `$TOTAL_TOKENS > $BUDGET_WARN` **and** `$BUDGET_SILENT` is `false`, warn the user. Otherwise skip this sub-step silently.

Compute the suggested raise-to value:
```bash
RAISE_TO=$(( ((TOTAL_TOKENS * 12 / 10) / 1000 + 1) * 1000 ))   # current × 1.2, rounded up to next 1k
```

Pick the top 3 heaviest docs from the per-doc size list (use the top 2 for the non-interactive one-liner).

**Interactive mode — fire an `AskUserQuestion` menu:**

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

**Non-interactive fallback — auto mode, or any reason `AskUserQuestion` should not fire:**

Skip the menu. Emit a single actionable line alongside the brief, then continue with kick-off. The next kick-off will naturally reflect any edits — do NOT suggest re-running `/kick-off`, and do NOT describe the menu options (they're unreachable in this mode):

> ⚠ Load on Kick-Off: ~<ktokens>k tokens (threshold: <BUDGET_WARN/1000>k). Heaviest: <path1> (~<N>k), <path2> (~<N>k). To trim, edit `## Load on Kick-Off` in `agent-session.md`. To raise or silence, set `budget_warn_tokens` or `budget_silent` under `docs:` in `.koji.yaml`.

**`.koji.yaml` edit mechanics** (for interactive C and D — done via the `Edit` tool, not sed):

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

**Fail-safe**: if size computation, yaml parsing, or the helper errors out, degrade silently and continue — never block kick-off on doc-loading issues.

---

### 3. Brief the user

Output a concise briefing (not a wall of text):

> **Session start — $PROJECT_NAME** (`$CURRENT_BRANCH`)
>
> Last session: [1-line summary of what was done]
> Handoff says: [1-line — highest priority open task from TODO.md if it exists, otherwise from AI_HANDOFF.md]
> Watching out for: [1-line gotcha from lessons, if relevant — otherwise skip]
> [If active plans > 0: **Pending plans:** <slug> (<status>[, inferred]), ...]
> [If active research > 0: **Pending research:** <slug> (UNVALIDATED[ — <next-step>]), ...]
> [If invalid frontmatter > 0: **Frontmatter warnings:** <path> (invalid status: `<raw>`)]
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
