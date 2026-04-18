---
description: "Inspect drift between tagged docs and the code they describe. Shows a drift report for all docs with a covers declaration in YAML frontmatter, then prompts to fix stale and orphan docs. Also surfaces docs in ## Load on Kick-Off that have no coverage declaration and offers to tag them."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Edit
  - AskUserQuestion
---

# Inspect Doc Drift

Find docs that have drifted out of sync with the code they describe, and help fix them. Operates on docs that declare coverage via YAML frontmatter:

```markdown
---
covers:
  - src/auth/
  - server/routes/auth/
---
```

The skill also surfaces **untagged docs listed in `## Load on Kick-Off`** and offers to tag them — because loaded-without-coverage means loaded-without-drift-signal.

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
```

If `HAS_HANDOFF` is `false`, tell the user to run `/koji-init` first and stop.

## Modes

Parse the argument:

- **No args** → **dashboard + fix-prompt mode** (scan repo, report drift, offer to fix stale docs)
- **`<path>`** → **drill-in mode** (show one specific tagged doc's drift detail, read-only)

---

## Dashboard + fix-prompt mode (no args)

### 1. Discover tagged docs AND docs loaded-but-untagged

**Part A — tagged docs**. Use `git grep` for cross-platform consistency:

```bash
cd "$PROJECT_ROOT"
git grep -l -E '^\s*covers\s*:' -- '*.md' 2>/dev/null | sort -u
```

For each match, read the first ~50 lines to verify a valid frontmatter `covers` list actually exists (see parsing below). Files matching `covers:` but lacking a proper list are ignored.

**Part B — Load on Kick-Off entries** (so we can compare). Read `$DOCS_PATH/AI_HANDOFF.md`, locate the `## Load on Kick-Off` H2 section, extract each bullet's `.md` path. Call this the **loaded set**.

Compute:
- `TAGGED` = docs with a valid `covers` declaration (Part A)
- `LOADED` = docs in Load on Kick-Off (Part B)
- `UNTAGGED_LOADED` = `LOADED - TAGGED` — docs that kick-off loads but have no drift signal

If `TAGGED` is empty AND `UNTAGGED_LOADED` is empty, tell the user:

> No docs declare coverage and no docs are listed in `## Load on Kick-Off`.
> Tagging is optional — add frontmatter to a doc you want drift-tracked:
>
>   ```
>   ---
>   covers:
>     - src/auth/
>   ---
>   ```

Stop.

If `TAGGED` is non-empty, continue to step 2 for the drift compute on tagged docs.
If `UNTAGGED_LOADED` is non-empty, step 3b will surface them at the end.

### 2. Parse coverage declaration + compute status

Read `.koji.yaml` for `docs.stale_threshold` (default `10` if absent or non-numeric).

For each tagged doc:

1. **Parse the `covers` list.** Read the first 50 lines. If the first non-empty line is `---`, find the closing `---`, parse YAML between. Look for top-level `covers` as a YAML list of strings. Example:
   ```yaml
   covers:
     - src/auth/
     - server/routes/auth/
   ```

   If no frontmatter or no `covers` list, skip the doc (treat as untagged — shouldn't happen since discovery matched on the key, but guard anyway).

2. **Orphan check.** For each covered path, check existence with `[ -e "$PROJECT_ROOT/$path" ]`. If ANY path does not exist → doc is **orphan**. (Orphan takes precedence over fresh/stale.)

3. **Determine doc's last-modified commit**:
   ```bash
   DOC_LAST_COMMIT=$(git log -1 --format=%H -- "<doc_path>" 2>/dev/null)
   ```

4. **Count commits in covered paths since that commit**:
   ```bash
   if [ -n "$DOC_LAST_COMMIT" ]; then
     DRIFT=$(git log --oneline "$DOC_LAST_COMMIT..HEAD" -- <covered_paths> 2>/dev/null | wc -l | tr -d ' ')
   else
     DRIFT=0  # new/untracked doc — treat as fresh
   fi
   ```

5. **Status**:
   - Any covered path missing → **orphan**
   - Else `DRIFT > stale_threshold` → **stale**
   - Else → **fresh**

### 3. Print the dashboard

Compact table. Sort orphan rows first, then stale, then fresh. Keep columns aligned:

```
Tagged docs — drift report (threshold: <N> commits)

Doc                                     Covers                            Drift   Status
---                                     ---                               ---     ---
docs/LEGACY_API.md                      src/legacy/                        —      orphan (covered path gone)
docs/ARCHITECTURE.md                    src/core/                         15      stale
docs/API.md                             src/api/                           3      fresh
```

Summary line below:

> <fresh_count> fresh, <stale_count> stale, <orphan_count> orphan.

### 3a. Surface untagged-but-loaded docs

If `UNTAGGED_LOADED` from step 1 is non-empty, print this after the dashboard:

> <N> doc(s) are loaded at kick-off but have no `covers` frontmatter. Without one, drift is invisible — code can change beneath the doc and no one will know.
>
> Loaded but untagged:
>   - docs/X.md
>   - docs/Y.md

Use `AskUserQuestion`:

> Add `covers` frontmatter to each? I'll suggest code paths based on each doc's name + content; you can accept, edit, or skip per doc.

Options:
- **A) Tag all (with suggestions)** — walk each doc, show suggested paths, accept/edit/skip per doc
- **B) Select some** — pick which to tag
- **C) Skip** — leave them untagged (kick-off still loads them)

**For each chosen doc, infer path suggestions (heuristic, intentionally cheap):**

1. **Extract the doc's slug**: lowercase the filename without extension (`AUTH_FLOW.md` → `auth_flow`). Drop any `_flow`, `_guide`, `_setup`, `_routing`, etc. noise suffix, split by `_` and `-`. Call the resulting tokens the **keyword set** (e.g., `{auth}` or `{split, tunnel, routing}`).

2. **Scan candidate dirs** for path matches. Candidate dirs are the project's top-level source locations — detect them by checking which of these exist: `src/`, `backend/`, `server/`, `app/`, `lib/`, `pkg/`, `cmd/`, `internal/`, `api/`, `client/`, `clients/`, `frontend/`, `web/`, `website/`, `ui/`, `core/`, `shared/`. For each candidate dir, look for subdirectories whose names overlap with the keyword set:
   ```bash
   # Example: find dirs under src/ containing "auth"
   find "$PROJECT_ROOT/src" -maxdepth 3 -type d -iname "*auth*" 2>/dev/null | head -5
   ```

3. **Scan the doc body** for code-path-like strings. Grep for patterns that look like paths: matches to `[a-zA-Z_][a-zA-Z0-9_/-]*\.(go|py|ts|tsx|js|jsx|dart|rs|java|rb|md)` or `[a-zA-Z_][a-zA-Z0-9_-]*/` occurring in backticks or markdown links. Take the directory part of each match. Deduplicate. Exclude paths that clearly aren't code (`docs/`, `README`, `LICENSE`, URLs).

4. **Merge + rank**: union of dir-match results and body-mention results. Deduplicate. Limit to top 5. Sort by: (a) directory names that contain a keyword, then (b) paths referenced in body.

5. **Present via `AskUserQuestion`**:

   > **docs/AUTH_FLOW.md** (1 of N untagged)
   >
   > Suggested `covers` paths based on the doc's name and content:
   >   - backend/auth/
   >   - clients/lib/providers/auth_provider.dart
   >   - server/routes/auth/
   >
   > What would you like to do?

   Options:
   - **A) Accept these paths** — write the frontmatter as suggested
   - **B) Edit** — I'll reshow the suggestions as a comma-separated draft you can paste back modified
   - **C) Empty** — write an empty `covers: []` list for now (you can fill it later; kick-off will still load the doc)
   - **D) Skip** — leave this doc untagged for now
   - **E) Quit** — stop the walkthrough; keep tags from docs you've already processed

6. **If the user chose A**: build the frontmatter block with top-level `covers` and the suggested paths; inject or prepend as before; report `Tagged <doc> with N covers path(s) (auto-suggested).`

7. **If the user chose B**: prompt the user with the suggested paths pre-filled (as "here's your starting point, type the final list, space-separated"). Parse the user's input. Write frontmatter.

8. **If the user chose C**: write `covers: []` — a tagged doc with no coverage is fine (drift check is a no-op, status will be `fresh` trivially until the user fills in paths).

9. **If no suggestions were found** (keyword set empty, no candidate dirs matched, no body references): fall back to asking the user directly, unfiltered:
   > `<doc>` — no obvious paths to suggest. Which paths does this doc describe? (space-separated, relative to repo root. Leave blank to skip.)

After walking all chosen docs, the newly-tagged docs have their drift computed (run step 2 for just these) so step 4 can include them.

If `UNTAGGED_LOADED` is empty, skip this step silently.

### 4. If there are problem docs, offer to fix

"Problem" = stale OR orphan. Use `AskUserQuestion`:

> <problem_count> doc(s) need attention (<orphan_count> orphan, <stale_count> stale). Fix now?

Options:
- **A) Yes — walk through each problem doc**
- **B) Select some — pick which to fix**
- **C) Skip — just show the report, don't fix**

If A or B, proceed to the remediation walkthrough (step 5).
If C, exit.

If no stale and no orphan docs, say `All tagged docs are fresh.` and exit.

### 5. Remediation walkthrough

For each problem doc (stale or orphan, in that priority order):

**For stale docs**, print a per-doc briefing:

```
docs/ARCHITECTURE.md — 15 commits behind (stale)
  Covers: src/core/
  Doc last edit: <YYYY-MM-DD>
  Recent commits in covered paths (up to 5):
    abc1234 refactor: split core into submodules (2d ago)
    def5678 fix: core init race condition (5d ago)
    ...
```

**For orphan docs**, the briefing emphasizes the missing path(s):

```
docs/LEGACY_API.md — orphan
  Covers: src/legacy/
  Missing: src/legacy/ (not in working tree)
  Doc last edit: <YYYY-MM-DD>
```

Then `AskUserQuestion`. Menu options depend on status:

**Stale menu:**
- **A) Open the doc for editing** — user manually updates; remind them: *"After you edit + git commit, drift resets automatically. Re-run `/inspect-doc-drift` to verify."*
- **B) Re-tag covers** — code moved? update the covers paths. Prompt for new paths, replace the frontmatter list or HTML-comment line in-place.
- **C) Remove tag** — stop tracking drift. Delete the `koji:` frontmatter block or the `<!-- koji:covers -->` line from the doc.
- **D) Delete doc** — doc is obsolete. Confirm: *"Delete `<path>`? This cannot be undone in this session (git retains history)."* If confirmed, `git rm` the file.
- **E) Skip** — come back to this one later.

**Orphan menu** (open-for-edit is omitted — editing text doesn't bring deleted code back):
- **A) Re-tag covers** — code moved to a new path? update covers accordingly.
- **B) Remove tag** — doc is still useful but no longer tied to specific code. Untag.
- **C) Delete doc** — doc describes code that's gone. Confirm + `git rm`.
- **D) Skip** — revisit later.

**Tag edit mechanics** (for "Re-tag covers" and "Remove tag"):
- Edit the frontmatter `covers` list in-place. For "Re-tag covers": prompt for new paths, replace the list.
- For "Remove tag": delete the `covers:` key from frontmatter. If `covers` was the only key, delete the entire `---...---` block plus the following blank line.

Execute the chosen action, then continue to the next problem doc.

After walking all selected docs, print a summary:

> Processed <N> docs: <opened> opened, <retagged> re-tagged, <untagged> untagged, <deleted> deleted, <skipped> skipped.

---

## Drill-in mode (`/inspect-doc-drift <path>`)

Resolve the given path. Accept either the doc's full path or a unique substring match against tagged docs.

Read the doc and parse the YAML frontmatter `covers` list. If there's no frontmatter or no `covers`:

> <path> has no coverage declaration. No drift to inspect.

Otherwise print a detail view:

```
<path>
  Covers: <space-separated paths>
  Doc last edit: <YYYY-MM-DD> (commit <short-hash>)
  Path existence: <all present | missing: path/X, path/Y>
  Drift: <N> commits in covered paths since doc's last edit
  Threshold: <threshold>
  Status: <fresh | stale | orphan>

  Recent commits in covered paths (up to 10):
    <hash> <subject> (<age>)
    ...
```

Read-only. To remediate, re-run `/inspect-doc-drift` without args.

---

## Edge cases

- **Doc has no git history (new/untracked)**: DRIFT = 0. Still apply orphan check — if covered path missing, doc is orphan; otherwise fresh.
- **Covered path doesn't exist in repo**: doc is **orphan**. Remediation menu surfaces appropriate options.
- **Malformed frontmatter YAML**: skip with `warn: malformed frontmatter in <path>`.
- **Frontmatter exists but `covers` is not a list** (e.g., a string, or missing): treat as no declaration. `warn: covers must be a list in <path>`.
- **Detached HEAD**: `git log HEAD` still works. No special handling needed.
- **User is in a subdirectory**: always use `$PROJECT_ROOT` from the preamble for all git commands.
- **Deleting a doc on option D/C**: use `git rm <path>`. Stage only — do not commit. User's next commit cleans up.

---

## Cross-platform notes

- `git grep`, `git log`, `git rm` — identical on Windows/macOS/Linux.
- No date arithmetic (BSD vs GNU `date` differs) — drift is commit-count-based.
- Forward slashes in all paths; Git Bash translates on Windows.
- Frontmatter is a widely-parseable YAML-in-markdown convention (same shape parsed by Cursor, Continue.dev, Astro, MkDocs, Hugo, Jekyll).

---

## Related skills

- `/kick-off` — parses the `## Load on Kick-Off` section of `AI_HANDOFF.md` to decide which docs to load. Tagged docs that are stale still load at kick-off (with a warning) — skipping is a user decision via `/inspect-doc-drift`.
- `/wrap` — suggests tagged docs to add to the Load on Kick-Off section based on the session's git diff. Complements this skill: wrap decides what to track, `/inspect-doc-drift` decides what to fix.
