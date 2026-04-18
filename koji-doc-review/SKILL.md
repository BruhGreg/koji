---
description: "Inspect docs tagged with <!-- koji:covers ... -->: list freshness, load explicitly, or refresh drift status."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# Doc Review

Inspect and manage docs that have opted into koji's auto-loading via a `koji:covers` header.

## What this skill is for

koji's `/kick-off` reads mandatory project docs (`AI_HANDOFF.md`, `TODO.md`, `lessons.md`, last session entry). Any other doc is invisible unless the user explicitly tags it.

A doc opts in by adding a single line at the top:

```markdown
<!-- koji:covers path/to/dir/ another/path/ -->
```

At kick-off, koji checks whether each tagged doc looks fresh relative to the code it covers. Stale ones are skipped. This skill lets you inspect what's tagged, see why something was skipped, and force-load a skipped doc if you need it.

## Preamble

Run koji's standard detect script to get project paths:

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
```

If `HAS_HANDOFF` is `false`, tell the user to run `/koji-init` first and stop.

## Workflow

### 1. Determine mode

Parse the argument after `/koji-doc-review`:

- **No args** → **list mode** (show all tagged docs + freshness)
- `/koji-doc-review <path>` → **load mode** (read that doc into context regardless of drift)
- `/koji-doc-review refresh` → alias for list mode (re-check all)
- `/koji-doc-review add <doc-path>` → **tag mode** (guide the user to add a header to a doc)

### 2. Discover tagged docs

Use `git grep` so results respect `.gitignore` and the command works identically on Windows, macOS, and Linux:

```bash
cd "$PROJECT_ROOT"
git grep -l '<!-- koji:covers' -- '*.md' 2>/dev/null
```

For each matched file, extract the first `<!-- koji:covers ... -->` line. Parse the space-separated paths between `koji:covers` and `-->`. Strip leading/trailing whitespace.

If no tagged docs are found, tell the user:

> No docs tagged with `<!-- koji:covers ... -->` in this repo yet.
> Add the header to a doc you want `/kick-off` to consider:
>   `<!-- koji:covers backend/auth/ -->`
> Then re-run `/koji-doc-review`.

Stop.

### 3. Compute freshness per doc

For each tagged doc, compute drift using git only — no date math:

```bash
# 1. The commit that last touched the doc itself
DOC_LAST_COMMIT=$(git log -1 --format=%H -- "<doc_path>" 2>/dev/null)

# 2. Commits in the covered paths since the doc's last commit
if [ -n "$DOC_LAST_COMMIT" ]; then
  DRIFT=$(git log --oneline "$DOC_LAST_COMMIT..HEAD" -- <covered_paths> 2>/dev/null | wc -l | tr -d ' ')
else
  DRIFT=0  # doc has no git history yet (new, untracked) — treat as fresh
fi
```

Where `<covered_paths>` is the space-separated list parsed from the header.

**Threshold**: default is 10. Override via `.koji.yaml`:

```yaml
docs:
  stale_threshold: 10
```

Parse this value from `.koji.yaml` with a simple grep for the `stale_threshold:` line; fall back to 10 if absent or non-numeric.

A doc is **stale** if `DRIFT > stale_threshold`. Otherwise **fresh**.

### 4. List mode output

Print a compact table:

```
Tagged docs (threshold: 10 commits)

Doc                                Covered paths                       Drift   Status
--------------------------------   ---------------------------------   -----   ------
docs/AUTH_FLOW.md                  backend/auth/ clients/lib/auth/       3     fresh
docs/ENDPOINT_RESOLUTION.md        backend/manifest/                    12     stale (skipped at kick-off)
docs/SPLIT_TUNNEL_ROUTING.md       clients/lib/connection/               0     fresh
```

If any are stale, append:

> Run `/koji-doc-review <path>` to load a stale doc anyway.
> Or edit the doc so it reflects current code, then rerun kick-off.

### 5. Load mode

Resolve the given path (user-supplied). Accept either the doc's full path or a unique substring match against tagged docs.

Read the doc with the `Read` tool, internalize its content, and tell the user:

> Loaded `<doc_path>` (drift: N commits since last edit). Holding contents in context for this session.

Do NOT dump the doc content back to the user — they already have it on disk.

### 6. Tag mode

User ran `/koji-doc-review add <doc-path>`. Ask (via AskUserQuestion):

> Which code path(s) does `<doc-path>` describe? (space-separated, relative to repo root)

Accept free-text input. Example expected answer: `backend/auth/ clients/lib/auth/`

Then prepend to the doc file:

```markdown
<!-- koji:covers {user_answer} -->

```

(Blank line after the comment so it doesn't visually bleed into the title.)

Verify by re-reading the first 3 lines of the doc. Confirm to the user:

> Added `<!-- koji:covers {paths} -->` to `<doc-path>`. It will be considered on next `/kick-off`.

### 7. Edge cases

- **Doc has no git history (new/untracked)**: DRIFT = 0, treat as fresh. Do not block on this.
- **Covered path doesn't exist in repo**: still compute drift (git log returns 0 commits). Print a `warn: covered path '<path>' not found` line. Do not error.
- **Multiple `koji:covers` headers in one file**: only the first is read. The rest are ignored.
- **Malformed header (missing closing `-->`)**: skip the doc and print `warn: malformed koji:covers header in <path>`.
- **Detached HEAD**: `git log HEAD` still works. No special handling needed.
- **User is in a subdirectory**: always use `$PROJECT_ROOT` from the preamble for all git commands.

## Cross-platform notes

- `git grep` works identically on Windows, macOS, Linux.
- `git log` is cross-platform.
- No `date -d` (BSD vs GNU differs) — we never do date math.
- Forward slashes in all paths; Git Bash translates on Windows.
- Header syntax uses HTML comments — agnostic to Markdown dialect.

## Related skills

- `/kick-off` — reads the same tags at session start; skips stale docs automatically.
- `/wrap` — no interaction with this system yet. Drift detection is kick-off-side only.
