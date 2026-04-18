---
description: "Inspect drift between tagged docs and the code they describe. Shows a drift report for all docs with a koji-covers declaration (YAML frontmatter or HTML comment), then prompts to fix stale and orphan docs."
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

Find docs that have drifted out of sync with the code they describe, and help fix them. Operates on docs that declare coverage via either:

**YAML frontmatter (canonical)**:
```markdown
---
koji:
  covers:
    - src/auth/
    - server/routes/auth/
---
```

**HTML comment (shorthand)**:
```markdown
<!-- koji:covers src/auth/ server/routes/auth/ -->
```

Docs without either declaration are not in scope (use regular handoff curation for untagged docs).

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

### 1. Discover tagged docs

Scan for docs that declare coverage in either form, using `git grep` for cross-platform consistency:

```bash
cd "$PROJECT_ROOT"
# Union of HTML-comment form and YAML-frontmatter form
{
  git grep -l '<!-- koji:covers' -- '*.md' 2>/dev/null
  git grep -l -E '^\s*koji:' -- '*.md' 2>/dev/null
} | sort -u
```

For each match, read the first ~50 lines of the doc and determine whether a real `koji:covers` declaration is present (see parsing below). Files that matched `koji:` but don't have a proper `koji.covers` list under frontmatter are ignored.

If no tagged docs found, tell the user:

> No docs declare coverage yet. Tagging is optional — add either form to a doc you want drift-tracked.
>
> Canonical (YAML frontmatter):
>   ```
>   ---
>   koji:
>     covers:
>       - src/auth/
>   ---
>   ```
>
> Shorthand (HTML comment):
>   `<!-- koji:covers src/auth/ -->`

Stop.

### 2. Parse coverage declaration + compute status

Read `.koji.yaml` for `docs.stale_threshold` (default `10` if absent or non-numeric).

For each tagged doc:

1. **Parse the `covers` list.** Read the first 50 lines. Try Form A first:

   **Form A — YAML frontmatter.** If the first non-empty line is `---`, find the closing `---`, parse YAML between. Look for `koji.covers` as a YAML list of strings. Example:
   ```yaml
   koji:
     covers:
       - src/auth/
       - server/routes/auth/
   ```

   **Form B — HTML comment** (only if Form A didn't produce a `koji.covers` list). Grep the first 50 lines for `<!-- koji:covers <paths> -->` and extract space-separated paths between `koji:covers` and `-->`.

   If neither form yields a list, skip the doc (treat as untagged — shouldn't happen since discovery matched on one of the forms, but guard anyway).

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

### 3b. Suggest frontmatter upgrade for shorthand docs

During step 2 parsing, track which form each doc uses (Form A frontmatter, Form B HTML comment). After the dashboard, if any docs use Form B only:

Print:

> <N> doc(s) use the HTML-comment shorthand. YAML frontmatter is the canonical form and aligns with the wider ecosystem (Cursor, Continue.dev, Astro, MkDocs parse frontmatter).
>
> Using shorthand:
>   - docs/X.md
>   - docs/Y.md

Use `AskUserQuestion`:

> Upgrade these to YAML frontmatter?

Options:
- **A) Upgrade all**
- **B) Select some** — pick which to migrate
- **C) Skip** — keep the shorthand form

For each chosen doc:

1. Read the doc
2. Extract `<paths>` from the existing `<!-- koji:covers <paths> -->` line
3. Build the frontmatter block:
   ```
   ---
   koji:
     covers:
       - <path1>
       - <path2>
   ---
   ```
4. **If the doc already has a frontmatter block** (starts with `---`): parse the existing YAML, inject the `koji.covers` key, write back. Preserve all other frontmatter keys.
5. **If the doc has no frontmatter**: prepend the new frontmatter block, then a blank line, then the original content.
6. Remove the original `<!-- koji:covers -->` line from the body.
7. Report: `Upgraded <path> to frontmatter.`

After migration, continue to step 4.

If all tagged docs already use frontmatter, skip this step silently.

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
- If the doc has frontmatter: edit the YAML `koji.covers` list in-place (or remove the `koji:` block entirely for untag).
- If the doc uses the HTML-comment shorthand: replace or remove the `<!-- koji:covers ... -->` line.
- If the doc has both forms for some reason: edit the frontmatter (canonical wins), then remove the HTML comment.

Execute the chosen action, then continue to the next problem doc.

After walking all selected docs, print a summary:

> Processed <N> docs: <opened> opened, <retagged> re-tagged, <untagged> untagged, <deleted> deleted, <skipped> skipped.

---

## Drill-in mode (`/inspect-doc-drift <path>`)

Resolve the given path. Accept either the doc's full path or a unique substring match against tagged docs.

Read the doc and parse the coverage declaration (Form A frontmatter or Form B HTML comment). If neither is present:

> <path> has no koji coverage declaration. No drift to inspect.

Otherwise print a detail view:

```
<path>
  Declaration: <frontmatter | html-comment>
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
- **Covered path doesn't exist in repo**: doc is **orphan** (this replaces the older warn-and-ignore behavior). Remediation menu surfaces appropriate options.
- **Both frontmatter AND HTML comment present**: frontmatter wins (canonical). Ignore the HTML comment.
- **Multiple `<!-- koji:covers -->` lines**: only the first is read. Ignore the rest.
- **Malformed frontmatter YAML**: skip with `warn: malformed koji frontmatter in <path>`; fall back to HTML comment form if present.
- **Malformed HTML comment (missing closing `-->`)**: skip that doc with `warn: malformed koji:covers comment in <path>`.
- **Frontmatter `koji` key exists but `covers` is not a list** (e.g., a string, or missing): treat as no declaration. `warn: koji.covers must be a list in <path>`.
- **Detached HEAD**: `git log HEAD` still works. No special handling needed.
- **User is in a subdirectory**: always use `$PROJECT_ROOT` from the preamble for all git commands.
- **Deleting a doc on option D/C**: use `git rm <path>`. Stage only — do not commit. User's next commit cleans up.

---

## Cross-platform notes

- `git grep`, `git log`, `git rm` — identical on Windows/macOS/Linux.
- No date arithmetic (BSD vs GNU `date` differs) — drift is commit-count-based.
- Forward slashes in all paths; Git Bash translates on Windows.
- Frontmatter is a widely-parseable YAML-in-markdown convention (same shape used by Cursor, Continue.dev, Astro, MkDocs, Hugo). HTML comment shorthand is markdown-dialect-agnostic.

---

## Related skills

- `/kick-off` — parses the `## Load on Kick-Off` section of `AI_HANDOFF.md` to decide which docs to load. Tagged docs that are stale still load at kick-off (with a warning) — skipping is a user decision via `/inspect-doc-drift`.
- `/wrap` — suggests tagged docs to add to the Load on Kick-Off section based on the session's git diff. Complements this skill: wrap decides what to track, `/inspect-doc-drift` decides what to fix.
