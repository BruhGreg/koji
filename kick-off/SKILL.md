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

Run the one-shot migrator, then print its summary message **only** when something actually migrated:

```bash
source <(~/.claude/skills/koji/bin/koji-migrate-load-on-kickoff)
case "${KOJI_MIGRATED_LOAD_KO:-false}" in
  true|cleanup) echo "$KOJI_MIGRATION_MSG" ;;
esac
true
```

The migrator moves any `## Load on Kick-Off` section from `AI_HANDOFF.md` into `agent-session.md` (above the first `## Session:` entry). Idempotent — no-op after first successful run. Emitted values:

- `KOJI_MIGRATED_LOAD_KO=true` — section moved; `$KOJI_MIGRATION_MSG` is the human summary.
- `KOJI_MIGRATED_LOAD_KO=cleanup` — section already in agent-session.md, stray duplicate stripped from handoff; `$KOJI_MIGRATION_MSG` is the summary.
- `KOJI_MIGRATED_LOAD_KO=false` — no-op; `$KOJI_MIGRATION_MSG` is unset.

**Why the explicit `case` + trailing `true`:** `[ -n "$KOJI_MIGRATION_MSG" ] && echo "$KOJI_MIGRATION_MSG"` looks correct but exits 1 when MSG is empty/unset — and when that line is the last command in a parallel-Bash batch, the harness sees exit 1 and cancels sibling Bash calls. The `case` branches on a known-good value set and always exits 0; the trailing `true` guards against future edits adding a line below that re-introduces a failing-test trailer.

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

**If A**, rewrite the block atomically. Build the new block, then hand the
atomic rewrite to `koji-migrate-claude-block` (same-dir mktemp + the section-
replace awk + `mv`-on-success; promote-only-on-success, never touching the
original until the new content is fully written; cleans up both temps on every
path):

```bash
NEW_BLOCK_FILE=$(mktemp)
cat > "$NEW_BLOCK_FILE" <<EOF
## Session Management (koji)

Session docs in \`$DOCS_DIR/\` (handoff, lessons, session log + Load on Kick-Off) and \`$TODO_FILE\` at project root. Use \`/kick-off\` to start a session, \`/wrap\` to end, \`/take-note\` mid-session. For substantial research worth keeping, capture to \`$DOCS_DIR/research/\` — see \`~/.claude/skills/koji/references/research-capture-eval.md\` for criteria.
EOF

~/.claude/skills/koji/bin/koji-migrate-claude-block "$PROJECT_ROOT/CLAUDE.md" "$NEW_BLOCK_FILE" \
  || { echo "ERROR: migration failed; CLAUDE.md unchanged" >&2; return 1 2>/dev/null || exit 1; }
```

Tell the user (only after the helper succeeded — i.e. after the `mv` landed): `Migrated CLAUDE.md to pointer-only koji block.`

**If B**: do nothing this session — the check fires again next kick-off.

**If C**: persist the decline so this prompt never fires again for this project:

```bash
~/.claude/skills/koji/bin/koji-config set "claude_md_migration_declined_$SESSION_HASH" true
```

Tell the user: `Won't ask again FOR THIS PROJECT. Edit CLAUDE.md manually if you change your mind, or unset with: koji-config set claude_md_migration_declined_$SESSION_HASH false` (the `$SESSION_HASH` namespacing keeps the decline project-scoped).

### 0g. CLAUDE.md research-capture-eval pointer migration (v0.5.6)

`/koji-init` (v0.5.6+) writes a research-capture-eval pointer into the project's `## Session Management (koji)` block. This step migrates existing projects whose koji block predates the addition.

Detect:

```bash
RC_BLOCK_DETECTED=false
if [ -f "$PROJECT_ROOT/CLAUDE.md" ]; then
  awk '
    /^## Session Management \(koji\)/ { in_block=1; block_exists=1; next }
    in_block && /^## / { in_block=0 }
    in_block && /research-capture-eval/ { found=1 }
    END {
      # exit 0 if block exists AND pointer is missing (needs migration)
      if (block_exists && !found) exit 0
      exit 1
    }
  ' "$PROJECT_ROOT/CLAUDE.md" 2>/dev/null && RC_BLOCK_DETECTED=true
fi

RC_DECLINED=$(~/.claude/skills/koji/bin/koji-config get "claude_md_research_capture_declined_$SESSION_HASH" 2>/dev/null || true)
```

If `RC_BLOCK_DETECTED=true` AND `RC_DECLINED` is not `true`, use AskUserQuestion:

> Your CLAUDE.md's koji block doesn't mention the research-capture-eval reference (v0.5.6 addition). When investigation produces "too valuable to throw away" findings during `/duet-plan`, `/triangulate`, or vanilla prompts, this pointer tells the agent where to capture them. Add it now?

Options:
- **A) Migrate now** (recommended) — extend the koji block with the research-capture-eval pointer
- **B) Skip this time** — ask again next kick-off
- **C) Decline permanently for this project** — never ask again

**If A**, rewrite the block atomically. Same shared rewriter as 0f — build the
new block, then call `koji-migrate-claude-block` (the new block already carries
the research-capture-eval pointer, so this step and 0f write identical content;
they differ only in the success message below):

```bash
NEW_BLOCK_FILE=$(mktemp)
cat > "$NEW_BLOCK_FILE" <<EOF
## Session Management (koji)

Session docs in \`$DOCS_DIR/\` (handoff, lessons, session log + Load on Kick-Off) and \`$TODO_FILE\` at project root. Use \`/kick-off\` to start a session, \`/wrap\` to end, \`/take-note\` mid-session. For substantial research worth keeping, capture to \`$DOCS_DIR/research/\` — see \`~/.claude/skills/koji/references/research-capture-eval.md\` for criteria.
EOF

~/.claude/skills/koji/bin/koji-migrate-claude-block "$PROJECT_ROOT/CLAUDE.md" "$NEW_BLOCK_FILE" \
  || { echo "ERROR: migration failed; CLAUDE.md unchanged" >&2; return 1 2>/dev/null || exit 1; }
```

Tell the user (only after the helper succeeded — i.e. after the `mv` landed): `Added research-capture-eval pointer to CLAUDE.md's koji block.`

**If B**: do nothing this session — the check fires again next kick-off.

**If C**: persist the decline:

```bash
~/.claude/skills/koji/bin/koji-config set "claude_md_research_capture_declined_$SESSION_HASH" true
```

Tell the user: `Won't ask again FOR THIS PROJECT. Edit CLAUDE.md manually if you change your mind, or unset with: koji-config set claude_md_research_capture_declined_$SESSION_HASH false`.

### 0h. Codebase-fit conventions setup (v0.6.0)

The codebase-fit feature (`/duet-plan` Fit Contract, `/duet-impl` review) reads `$DOCS_PATH/CODEBASE_CONVENTIONS.md`. New projects get it from `/koji-init`; this step backfills it into projects that predate the feature, registering any convention docs the project already has.

Detect:

```bash
if [ -f "$DOCS_PATH/CODEBASE_CONVENTIONS.md" ]; then CBF_EXISTS=true; else CBF_EXISTS=false; fi
CBF_DECLINED=$(~/.claude/skills/koji/bin/koji-config get "codebase_conventions_declined_$SESSION_HASH" 2>/dev/null || true)
echo "CODEBASE_CONVENTIONS.md exists: $CBF_EXISTS | declined: ${CBF_DECLINED:-false}"
```

If `CBF_EXISTS` is `true` OR `CBF_DECLINED` is `true`, **skip this step silently** — idempotent: a no-op once the doc exists or the user has declined.

Otherwise, scan for the project's existing convention docs:

```bash
CANDIDATES=$(~/.claude/skills/koji/bin/koji-scan-conventions)
[ -n "$CANDIDATES" ] && printf 'Convention candidates:\n%s\n' "$CANDIDATES" || echo "Convention candidates: (none)"
```

**If `$CANDIDATES` is non-empty** — use AskUserQuestion (list the actual candidate paths in the prompt body):

> koji's codebase-fit feature tracks how new code should fit this project. It found existing convention docs: `<candidate list>`. Set up `CODEBASE_CONVENTIONS.md` to point at them?

Options:
- **A) Link the found docs** — `sources:` points at all the listed docs. (Pick "Other" to name a subset — e.g. link `CONTRIBUTING.md` but skip a stale `.cursorrules`.)
- **B) Set up, link none** — create the hub with empty `sources:`; the found docs are not authoritative conventions.
- **C) Don't set up** — decline; koji won't ask again for this project.

**If `$CANDIDATES` is empty** — nothing to confirm; treat it as choice B with no prompt.

**On A / B / empty** — scaffold the hub by running `koji-scaffold-conventions` with the confirmed convention-doc paths as arguments — `koji-scaffold-conventions CONTRIBUTING.md .cursorrules` for choice A, or with **no arguments** for choice B / no candidates. The helper (`~/.claude/skills/koji/bin/koji-scaffold-conventions`) owns the canonical stub format and skips silently if `CODEBASE_CONVENTIONS.md` already exists:

```bash
~/.claude/skills/koji/bin/koji-scaffold-conventions [confirmed-source-path ...]
```

Tell the user: `Set up CODEBASE_CONVENTIONS.md (codebase-fit). Sources: <comma-list, or "none">.`

**On C** — persist the decline so the prompt never fires again for this project:

```bash
~/.claude/skills/koji/bin/koji-config set "codebase_conventions_declined_$SESSION_HASH" true
```

Tell the user: `Won't set up codebase-fit FOR THIS PROJECT. Re-enable with: koji-config set codebase_conventions_declined_$SESSION_HASH false`.

### 0i. Inert project bypass key (v0.8.0)

Pre-v0.8.0 `/koji-init` offered to write `permissions.defaultMode: bypassPermissions` into `.claude/settings.local.json`. Since Claude Code 2.1.257 that key is inert — only user settings (`~/.claude/settings.json`), managed settings, or `claude --permission-mode` can set bypass — so it now does nothing except mislead `/wrap` Step 4's permission-hygiene check. This step offers to remove it.

Detect (the helper resolves the *effective* mode the way Claude Code does and names any inert project-scope value; it never edits anything in report mode):

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
source <(~/.claude/skills/koji/bin/koji-permission-mode)
BYPASS_DECLINED=$(~/.claude/skills/koji/bin/koji-config get "bypass_migration_declined_$SESSION_HASH" 2>/dev/null || true)
echo "Inert bypass key — local: ${INERT_LOCAL_MODE:-none} | project: ${INERT_PROJECT_MODE:-none} | effective: $EFFECTIVE_MODE ($MODE_SOURCE) | declined: ${BYPASS_DECLINED:-false}"
```

If `INERT_LOCAL_MODE` and `INERT_PROJECT_MODE` are both empty, OR `BYPASS_DECLINED` is `true`, **skip this step silently** — idempotent: a no-op once the key is gone or the user has declined.

Otherwise, if AskUserQuestion is not callable, print one line naming the file(s) that carry the key (`INERT_LOCAL_MODE` → `.claude/settings.local.json`, `INERT_PROJECT_MODE` → `.claude/settings.json`) and continue:

> note: `.claude/settings.local.json` sets `permissions.defaultMode=bypassPermissions` — inert since Claude Code 2.1.257. Remove with: `~/.claude/skills/koji/bin/koji-permission-mode --remove-inert`

Otherwise use AskUserQuestion:

> `.claude/settings.local.json` sets `permissions.defaultMode: bypassPermissions` (written by an older `/koji-init`). Claude Code ≥ 2.1.257 ignores bypass set at project scope, so the key does nothing — and it confuses `/wrap`'s permission hygiene. Your effective mode is `<EFFECTIVE_MODE>` (from `<MODE_SOURCE>`) and stays unchanged either way. Remove the key?

Options:
- **A) Remove the inert key** (recommended) — the helper edits only the project-scope file(s), atomically, every other key preserved
- **B) Leave it** — koji won't ask again for this project

**If A**:

```bash
~/.claude/skills/koji/bin/koji-permission-mode --remove-inert
```

Tell the user: `Removed inert bypass key from <file(s)>. To actually run in bypass mode, set permissions.defaultMode in ~/.claude/settings.json yourself or launch with claude --permission-mode bypassPermissions — koji never writes ~/.claude/settings.json.`

**If B**: persist the decline so the prompt never fires again for this project:

```bash
~/.claude/skills/koji/bin/koji-config set "bypass_migration_declined_$SESSION_HASH" true
```

Tell the user: `Won't ask again FOR THIS PROJECT. Re-enable with: koji-config set bypass_migration_declined_$SESSION_HASH false`.

### 1. Check for user-provided focus

If the user typed text after `/kick-off` (e.g., `/kick-off build the news landing page`), use that as the **session focus** — skip reading the last session's starter prompt and use the user's intent instead. Still read handoff and lessons for context.

If no args provided, proceed to step 2.

### 2. Read context (always)

Read these files and internalize the content — do NOT dump them back to the user:

1. `$DOCS_PATH/AI_HANDOFF.md` — project state, architecture rules, gotchas
2. `$TODO_PATH` — open tasks, tech debt, blockers (if `$HAS_TODO` is `true`)
3. **Lessons (focus-filtered).** Prefer the focus-filtered candidate set via the helper; for a small `lessons.md` (≤ ~40 entries) you may read it directly and judge relevance yourself — the pre-filter is an optimization for large corpora, not a wall. Derive a focus string from (a) the user-provided focus arg if any, (b) the last session's "Notes for Next Session" field (read from `$DOCS_PATH/agent-session.md`), (c) the first 3 open items in `$TODO_PATH` if `$HAS_TODO`, and (d) the **active-plan slugs** — the session's current work, which Notes/TODO often miss (the same blind spot 2b's plan auto-load exists to cover). Concatenate with spaces:

   ```bash
   # The Notes-block + top-of-TODO derivation lives in koji-doc-status
   # (--kickoff-focus): parser-heavy awk shouldn't sit inline in a rendered
   # SKILL.md. Pass the TODO path only when $HAS_TODO is true (empty arg = no
   # TODO segment). The helper emits a leading-space-prefixed segment per source
   # in the same order as the old inline block, with no trailing newline, so
   # prepending $USER_FOCUS reproduces the former byte-for-byte FOCUS string.
   FOCUS="${USER_FOCUS:-}"
   TODO_ARG=""
   [ "$HAS_TODO" = "true" ] && TODO_ARG="${TODO_PATH:-}"
   # Capture the focus-extractor's output AND exit separately: inlining the
   # command substitution into the append would discard its status, so a failed
   # extraction (Notes/TODO focus existed but the helper errored) would degrade
   # to cold-start recency with no warning. $FOCUS_EXTRA is empty on failure, so
   # the happy-path FOCUS string is unchanged.
   FOCUS_EXTRA=$(~/.claude/skills/koji/bin/koji-doc-status --kickoff-focus "$DOCS_PATH/agent-session.md" "$TODO_ARG" 2>/dev/null)
   FOCUS_EXIT=$?
   FOCUS="$FOCUS$FOCUS_EXTRA"
   # (d) Fold active-plan slugs into FOCUS — the session's current work, and the
   # dynamic part of LOKO (active plans auto-flow into Load-on-Kick-Off during
   # their lifecycle). Notes/TODO often miss them, leaving the lessons filter
   # blind to the active plan exactly when 2b's plan auto-load has to rescue it.
   # Hyphens → spaces so slug words match lesson tokens. Render-safe: named-var
   # read, no $N field refs (same pattern as 2b's records walk). 2b re-fetches
   # these records independently in its own block (cheap, read-only) — bash vars
   # do not survive across steps, so each block fetches what it needs.
   PLAN_SLUGS=""
   while IFS=$'\t' read -r ap_path ap_rest; do
     [ -n "$ap_path" ] && PLAN_SLUGS="$PLAN_SLUGS $(basename "$ap_path" .md | tr '-' ' ')"
   done <<< "$(~/.claude/skills/koji/bin/koji-plans-research --filter active-plan 2>/dev/null || true)"
   FOCUS="$FOCUS $PLAN_SLUGS"
   LESSONS=$(~/.claude/skills/koji/bin/koji-doc-status --lessons-relevant --focus "$FOCUS" --limit 40 2>/dev/null)
   LESSONS_EXIT=$?
   ```

   These are **candidate** lessons — recall is intentionally wide (any focus-token hit, plus a recent baseline). Judge which actually bear on the focus; ignore the rest. Internalize the ones that matter. **If `$FOCUS_EXIT` is non-zero (focus extraction failed), OR `$LESSONS_EXIT` is non-zero, OR `$LESSONS` is empty when focus signals exist**, fall back to reading the top of `lessons.md` directly (first 10 entries) so kick-off still works without focus context — AND surface one line in the kick-off brief naming the degradation, e.g. `> Note: lessons helper degraded (exit $LESSONS_EXIT) — using recency fallback instead of focus ranking.` (or, when `$FOCUS_EXIT` is the nonzero one, `> Note: focus extraction degraded (exit $FOCUS_EXIT) — session-notes/TODO focus may be missing; using recency fallback.`). A nonzero `$FOCUS_EXIT` matters because it means session notes / TODO focus existed but couldn't be read, so the lessons ranking silently lost its focus signal — exactly the silent-degrade shape that kept a BSD-awk bug invisible across multiple versions; visibility is cheap insurance. Cold-start (no focus signals — fresh session with no args, empty Notes, no TODO) returns top 10 by recency automatically and is the documented happy path — no warn needed.
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
# Filter rules (encoded in koji-plans-research --filter):
#   active-plan     → kind=plan,     status ∈ {pending, in-progress}, status_source ≠ invalid
#   active-research → kind=research, status = unvalidated,           status_source ≠ invalid
#   invalid         → kept separately for the Frontmatter warnings line
#
# Counts come from `--count`; records (used for the per-kind rendering below)
# come from `--filter`. The filtering lives in the helper script — SKILL.md
# used to inline awk with `$N` field refs, which a transport-layer somewhere
# between disk and execution can strip (observed during a /kick-off session
# 2026-05; `$2`/`$3`/`$4` vanished while `$PLANS_RESEARCH` survived). Helper
# scripts execute via bash directly, not through the skill renderer, so
# their awk is safe regardless of mechanism.
ACTIVE_PLANS=$(~/.claude/skills/koji/bin/koji-plans-research --count active-plan 2>/dev/null || echo 0)
ACTIVE_RESEARCH=$(~/.claude/skills/koji/bin/koji-plans-research --count active-research 2>/dev/null || echo 0)
INVALID_FM=$(~/.claude/skills/koji/bin/koji-plans-research --count invalid 2>/dev/null || echo 0)

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

When you need the records themselves (to render the per-kind lines above), fetch them per filter — do NOT inline-awk a full `--list` to refilter, that's the trap this step's design exists to avoid:

```bash
ACTIVE_PLANS_RECORDS=$(~/.claude/skills/koji/bin/koji-plans-research --filter active-plan 2>/dev/null || true)
ACTIVE_RESEARCH_RECORDS=$(~/.claude/skills/koji/bin/koji-plans-research --filter active-research 2>/dev/null || true)
INVALID_RECORDS=$(~/.claude/skills/koji/bin/koji-plans-research --filter invalid 2>/dev/null || true)
```

Each record is tab-separated: `path\tkind\tstatus\tstatus_source\torigin\ttarget\tnext_step`. Walk lines using `while IFS=$'\t' read -r path kind status status_source origin target next_step; do …; done <<< "$ACTIVE_PLANS_RECORDS"` (or read into your head — the records are short).

**Active-plan auto-load (always fires when set is small):**

Variables already in scope from the records-fetch above. If `$ACTIVE_PLANS` is `1` or `2`, walk `$ACTIVE_PLANS_RECORDS`, **Read each `path`** (project-relative — prefix with `$PROJECT_ROOT/` if your read tool needs absolute paths), internalize the body, and append one line per loaded plan to the brief:

> Active plan loaded: \<slug\> (\<status\>)

`<slug>` = `basename "$path" .md`. Skip silently when count is `0` (nothing to do) or `> 2` (the user should curate via `## Load on Kick-Off` directly; auto-loading 3+ plans inflates kick-off context unpredictably).

At ≤ 2 active plans, "active" ≈ "relevant" — load it. This catches the case where a recent `/wrap` or `/duet-plan` locked a plan the next session is going to work on, but the LOKO proposal hasn't run yet OR Notes-for-Next-Session keywords didn't match the plan filename to trigger Tier 2 reference-follow. The LOKO write-side mechanism (wrap Pass A.2) is the primary path; this auto-load is the deterministic safety net.

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
# stale_action read via the helper, NOT an inline awk: the skill renderer
# strips awk `$N`/`$0` field refs, which would break the quote-stripping below
# and silently fall back to `warn` regardless of the configured value.
STALE_ACTION=$(~/.claude/skills/koji/bin/koji-doc-status --get-docs-key stale_action 2>/dev/null | grep -E '^[a-z_]+$' || true)
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

**Read budget config from `.koji.yaml`** (both keys optional). Keys MUST live inside the top-level `docs:` block to be honored. `budget_silent` accepts `true`/`yes`/`on`/`1` (case-insensitive); anything else is false. Read via the `koji-doc-status` helper — NOT an inline awk. The reader needs a *dynamic* `$0 ~ "..."key"..."` match, and the skill renderer strips awk `$N`/`$0` field refs from this body; inlined, it would syntax-error to empty and the fallbacks below would silently win, ignoring your `.koji.yaml` config (the exact failure mode step 2b's helper-script note warns about):

```bash
_kds=~/.claude/skills/koji/bin/koji-doc-status

BUDGET_WARN=$("$_kds" --get-docs-key budget_warn_tokens 2>/dev/null | grep -E '^[0-9]+$' || true)
[ -n "${BUDGET_WARN:-}" ] || BUDGET_WARN=15000

_budget_silent_raw=$("$_kds" --get-docs-key budget_silent 2>/dev/null || true)
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
