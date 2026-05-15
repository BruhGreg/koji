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
  - src/<module-a>/
  - src/<module-b>/
---
```

Docs whose content isn't tied to specific code — onboarding guides, runbooks, glossaries, narrative design docs — can opt out of drift tracking with the **`covers: none`** sentinel:

```markdown
---
covers: none
---
```

These docs still commit normally and still load at kick-off (if listed in `## Load on Kick-Off`); they just drop out of drift reports and untagged-scan prompts.

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

### 1. Discover docs + compute drift

Three lists drive the dashboard. The shared helper `koji-doc-status` emits tab-separated records: `<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>` with `status ∈ {fresh, stale, orphan, exempt, untagged, missing, malformed}`.

**A. Tagged docs — per-doc drift status:**

```bash
cd "$PROJECT_ROOT"
TAGGED_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --scan-tagged 2>/dev/null || true)
```

In `--scan-tagged` mode, `status` is `fresh`, `stale`, `orphan`, `exempt`, or `malformed`. The helper honors `docs.stale_threshold` from `.koji.yaml` (default `10`). `exempt` = doc declared `covers: none` (intentionally untagged — narrative/ops/process content with no code to track).

**B. All tracked `.md` files** (for the untagged scan — `git ls-files` respects `.gitignore`, so vendored trees like `node_modules/`, `Pods/`, `vendor/` are excluded):

```bash
ALL_MD=$(git ls-files '*.md' | sort -u)
```

**C. Load on Kick-Off entries** (for the high-priority untagged bucket):

```bash
LOKO_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --load-on-kickoff 2>/dev/null || true)
```

Column 1 of each record is the bullet's resolved `.md` path.

**Compute the sets:**

- `TAGGED` = column 1 of `TAGGED_REPORT` rows whose `status` is `fresh|stale|orphan|exempt` (drop `malformed` — surface separately as a warning below). `exempt` docs belong in TAGGED so they're excluded from the untagged scan — their `covers: none` frontmatter is the user's explicit "no coverage" declaration.
- `LOADED` = column 1 of `LOKO_REPORT`
- `META` = meta-files that should never be considered for code-coverage tagging. Exclude by basename:
  `README.md`, `LICENSE*.md`, `CHANGELOG*.md`, `CODE_OF_CONDUCT*.md`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CLAUDE.md`, `AGENTS.md`, `AI_HANDOFF.md`, `agent-session.md`, `lessons.md`, `TODO.md`,
  `COMPLETED_TASKS.md`, `SESSION_TEMPLATE.md`.
  Also exclude anything under `$ARCHIVE_DIR/` (session archives).
- `UNTAGGED_ALL` = `ALL_MD - TAGGED - META`
- `UNTAGGED_LOADED` = `UNTAGGED_ALL ∩ LOADED` (high-priority subset)
- `UNTAGGED_OTHER` = `UNTAGGED_ALL - UNTAGGED_LOADED`

**Bucket `UNTAGGED_OTHER` further** for display priority:

- **Under `docs/`** — usually narrative code docs
- **Nested `DESIGN.md` files** (any depth) — design-system docs
- **Root-level docs** (`ARCHITECTURE.md`, `SPEC.md`, etc. — any `.md` at repo root not in META)
- **Other** — everything else (rare; e.g., inline `NOTES.md` in subdirs)

**Surface malformed rows** ahead of the dashboard, one line each:

> ⚠ <path>: malformed `covers:` (not a YAML list). Fix the frontmatter to enable drift tracking.

These docs are NOT counted in the dashboard totals and are NOT surfaced as untagged candidates (their problem is frontmatter syntax, not missing tags).

If `TAGGED_REPORT` is empty AND `UNTAGGED_ALL` is empty, tell the user:

> No tracked `.md` files found (excluding meta-files like README, LICENSE, handoff).
> Tagging is optional — add frontmatter to a doc you want drift-tracked:
>
>   ```
>   ---
>   covers:
>     - src/<module>/
>   ---
>   ```

Stop.

If `TAGGED_REPORT` has any `fresh|stale|orphan` rows, continue to step 2 for the dashboard.
Step 2a will surface `UNTAGGED_ALL` bucketed by priority at the end.

### 2. Print the dashboard

Using the `TAGGED_REPORT` rows (status ∈ {fresh, stale, orphan}), build a compact table. Sort orphan rows first, then stale, then fresh. Keep columns aligned. Threshold comes from `.koji.yaml`'s `docs.stale_threshold` (default `10`):

```
Tagged docs — drift report (threshold: <N> commits)

Doc                                     Covers                            Drift   Status
---                                     ---                               ---     ---
<path>                                  <covers>                           —      orphan (covered path gone)
<path>                                  <covers>                          15      stale
<path>                                  <covers>                           3      fresh
```

**For each stale or orphan row**, append the top 3 commit subjects from covered paths (helps the user triage whether the drift is meaningful or mostly noise). Call the helper:

```bash
~/.claude/skills/koji/bin/koji-doc-status --commits <path> --limit 3
```

Indent the commit lines under their row. Example with commits:

```
docs/ARCHITECTURE.md                    src/core/                         15      stale
  4cfdbfd feat(api): scaffold v2 endpoints (2d ago)
  94e3ba7 refactor: split core into submodules (5d ago)
  8b4c57f fix: init race condition (1w ago)

docs/API.md                             src/api/                          12      stale
  k1l2m3n feat: add /v2 endpoints (3d ago)
  n4o5p6q fix: error response handling (5d ago)
  q7r8s9t refactor: normalize request logging (1w ago)
```

Default mode is **recent with noise filter** — skips low-signal commits (typo/chore/deps/lint/fmt/bump/style/ci/build/docs/version). If every commit in the drift window is noise, the filter falls back to unfiltered so the row always shows something.

Fresh, exempt, and malformed rows do NOT get commit lines.

**Optional modes** (hint to the user after the dashboard if they want different ranking — don't run by default, just mention):

> Need richer triage? Re-run with:
>   `/inspect-doc-drift <path>` — full drill-in (10 commits, unfiltered)
>   or call the helper directly: `koji-doc-status --commits <path> --by-size` (ranks by change size) / `--per-path` (round-robin across covered paths, useful for docs that span multiple modules).

Summary line below the table:

> <fresh_count> fresh, <stale_count> stale, <orphan_count> orphan.

If `exempt` rows exist in `TAGGED_REPORT`, add a one-line footnote (do NOT put them in the main table — the dashboard is about drift, and exempt docs have no drift to measure):

> <exempt_count> doc(s) marked `covers: none` (intentionally untagged — not tracked for drift).

**Edge case — no fresh/stale/orphan rows** (e.g., every tagged doc is `exempt`, or the repo has only exempt docs): skip the drift table entirely but still print the exempt footnote AND the untagged-candidates report (step 2a). If BOTH the table and the untagged buckets are empty but exempt rows exist, print the footnote alone with no "All tagged docs are fresh" message (that would be misleading — they're exempt, not fresh).

### 2a. Surface untagged candidates across the repo

If `UNTAGGED_ALL` from step 1 is empty, skip this step silently (no unindexed docs to tag).

Otherwise, print a bucketed report. The two interesting priorities:

> **Untagged docs — consider tagging so drift can be detected:**
>
> **Loaded at kick-off (HIGH — loaded without drift signal):**
>   - docs/FOO.md
>   - docs/BAR.md
>   - .koji/BAZ.md
>
> **Under `docs/` (MEDIUM):**
>   - docs/QUUX.md
>   - docs/QUX.md
>   - ... (N more)
>
> **Nested `DESIGN.md` files (MEDIUM):**
>   - <subdir-a>/DESIGN.md
>   - <subdir-b>/DESIGN.md
>
> **Other (LOW):**
>   - ... (N more)

Use `AskUserQuestion` — **which bucket(s) to process?**

> What would you like to tag?

Options (dynamic based on non-empty buckets):
- **A) Walk HIGH only** — tag untagged-but-loaded docs (most important)
- **B) Walk HIGH + MEDIUM** — also tag docs under `docs/` and nested `DESIGN.md` files
- **C) Walk everything** — include LOW bucket too
- **D) Pick individual docs** — show a numbered list across all buckets, user selects
- **E) Skip all** — leave them untagged

If only HIGH bucket is non-empty, collapse options A-C into just "Tag these".

Call the resulting list of docs to process `CHOSEN`. If `CHOSEN` is empty, exit.

---

**Then ask how to handle them.** `AskUserQuestion`:

> **<N> untagged docs selected. How would you like to handle them?**

Options:
- **A) Auto-tag** — analyze each doc, propose a tag per doc (covers list, `covers: none`, or defer), show one review summary, let user approve / edit before writing. Deferred docs fall through to the per-doc walk.
- **B) Mark all as `covers: none`** — treat the whole set as narrative/ops/process docs with no code to track. One confirm, done.
- **C) Walk one-by-one** — per-doc prompts (same six-option menu as single-doc mode).
- **D) Cancel** — write nothing, exit.

### Option A — Auto-tag (bulk classify + review)

This is the default path for most projects. The skill does the classification work so the user only makes one approve/edit decision across all docs.

**For each doc in `CHOSEN`:**

1. **Run the cheap heuristic** (see below) to produce candidate paths.
2. **Read the doc's first ~80 lines** for context.
3. **Classify the doc** — decide which action fits best:
   - `tag` — doc clearly describes specific code. Pick a trusted subset of candidate paths (may prune false positives from the heuristic); can be empty-but-list-shaped if nothing in candidates looks right but some code mapping exists.
   - `narrative` — doc is ops/onboarding/glossary/FAQ/policy/process with no code mapping. Will write `covers: none`.
   - `defer` — not confident enough to decide. Will fall through to per-doc walk.

   Use doc title, body content, and candidate paths together. When in doubt, defer — it's cheaper than tagging wrong.

4. Collect the per-doc decisions into a **proposal**.

**Show the proposal** (one `AskUserQuestion` for the whole batch):

> **Proposal for <N> docs:**
>
> **<X> will be tagged (code-mapping found):**
>   - docs/<A>.md → backend/<module>/, server/routes/<module>/
>   - docs/<B>.md → clients/lib/<module>/
>   - ...
>
> **<Y> will be marked `covers: none` (narrative):**
>   - docs/<C>.md
>   - docs/<D>.md
>   - ...
>
> **<Z> deferred — needs your input:**
>   - docs/<E>.md
>   - ...
>
> Proceed?

Options:
- **A) Proceed** — write all decided frontmatter, then fall through to the per-doc walk for deferred docs
- **B) Edit** — show the full proposal as a numbered list; user can flip any decision (tag↔narrative↔defer) or adjust paths before committing
- **C) Cancel** — write nothing, exit

**On Proceed:**
- Write frontmatter for every tagged doc (`covers: [...]`) and every narrative doc (`covers: none`). Report `Wrote covers for <X> doc(s); marked <Y> as covers: none.`
- If any deferred docs remain, drop into the per-doc walk for those only. For each deferred doc, show the standard six-option menu (A-F below). The heuristic's candidate paths still pre-fill the "Accept these paths" suggestion.

**On Edit:**
- Show a numbered list:
  > 1. docs/<A>.md — tag → backend/<module>/, server/routes/<module>/
  > 2. docs/<B>.md — tag → clients/lib/<module>/
  > 3. docs/<C>.md — narrative (covers: none)
  > 4. docs/<D>.md — narrative (covers: none)
  > 5. docs/<E>.md — defer
- Prompt: "Which items to change? (e.g., '3 tag', '5 narrative', '1 paths=foo/ bar/', or 'none' to proceed as-is)"
- Parse user input, update the proposal, re-show, loop until user types `none`/`proceed`.
- Then proceed as above.

### Option B — Mark all as `covers: none`

One confirm prompt showing the list of docs, then write `covers: none` frontmatter to each. No heuristic, no classification.

> **Mark all <N> docs as `covers: none`?**
>   - docs/<A>.md
>   - docs/<B>.md
>   - ...

Options:
- **A) Yes** — write `covers: none` to all. Report `Marked <N> docs as covers: none.`
- **B) Cancel** — exit

### Option C — Walk one-by-one

Current per-doc behavior. For each doc in `CHOSEN`, run the heuristic and show the six-option menu below.

---

**For each chosen doc walked one-by-one, infer path suggestions (heuristic, intentionally cheap):**

1. **Extract the doc's slug**: lowercase the filename without extension (`FOO_GUIDE.md` → `foo_guide`). Drop any `_flow`, `_guide`, `_setup`, `_routing`, etc. noise suffix, split by `_` and `-`. Call the resulting tokens the **keyword set** (e.g., `{foo}` or `{foo, bar, baz}`).

2. **Scan candidate dirs** for path matches. Candidate dirs are the project's top-level source locations — detect them by checking which of these exist: `src/`, `backend/`, `server/`, `app/`, `lib/`, `pkg/`, `cmd/`, `internal/`, `api/`, `client/`, `clients/`, `frontend/`, `web/`, `website/`, `ui/`, `core/`, `shared/`. For each candidate dir, look for subdirectories whose names overlap with the keyword set:
   ```bash
   # Example: find dirs under src/ containing a keyword
   find "$PROJECT_ROOT/src" -maxdepth 3 -type d -iname "*<keyword>*" 2>/dev/null | head -5
   ```

3. **Scan the doc body** for code-path-like strings. Grep for patterns that look like paths: matches to `[a-zA-Z_][a-zA-Z0-9_/-]*\.(go|py|ts|tsx|js|jsx|dart|rs|java|rb|md)` or `[a-zA-Z_][a-zA-Z0-9_-]*/` occurring in backticks or markdown links. Take the directory part of each match. Deduplicate. Exclude paths that clearly aren't code (`docs/`, `README`, `LICENSE`, URLs).

4. **Merge + rank**: union of dir-match results and body-mention results. Deduplicate. Limit to top 5. Sort by: (a) directory names that contain a keyword, then (b) paths referenced in body.

5. **Present via `AskUserQuestion`**:

   > **docs/FOO.md** (1 of N untagged)
   >
   > Suggested `covers` paths based on the doc's name and content:
   >   - backend/<module>/
   >   - clients/lib/providers/<file>.<ext>
   >   - server/routes/<module>/
   >
   > What would you like to do?

   Options:
   - **A) Accept these paths** — write the frontmatter as suggested
   - **B) Edit** — I'll reshow the suggestions as a comma-separated draft you can paste back modified
   - **C) Empty** — write an empty `covers: []` list for now (you can fill it later; kick-off will still load the doc)
   - **D) Skip** — leave this doc untagged for now
   - **E) Quit** — stop the walkthrough; keep tags from docs you've already processed
   - **F) Mark intentionally untagged** — write `covers: none` (use for narrative/ops/process docs that don't map to code; suppresses this doc from future untagged scans)

6. **If the user chose A**: build the frontmatter block with top-level `covers` and the suggested paths; inject or prepend as before; report `Tagged <doc> with N covers path(s) (auto-suggested).`

7. **If the user chose B**: prompt the user with the suggested paths pre-filled (as "here's your starting point, type the final list, space-separated"). Parse the user's input. Write frontmatter.

8. **If the user chose C**: write `covers: []` — a tagged doc with no coverage is fine (drift check is a no-op, status will be `fresh` trivially until the user fills in paths).

9. **If the user chose F**: write `covers: none` frontmatter. Report `Marked <doc> as intentionally untagged (covers: none). It will be silent in future audits.` The doc will show status `exempt` from the helper.

10. **If no suggestions were found** (keyword set empty, no candidate dirs matched, no body references): fall back to asking the user directly, unfiltered:
    > `<doc>` — no obvious paths to suggest. Which paths does this doc describe? (space-separated, relative to repo root. Leave blank to skip. Type `none` to mark as intentionally untagged.)

After walking all chosen docs, re-run `koji-doc-status --scan-tagged` to refresh the drift records for newly-tagged docs so step 3 can include them.

### 3. If there are problem docs, offer to fix

"Problem" = stale OR orphan. Use `AskUserQuestion`:

> <problem_count> doc(s) need attention (<orphan_count> orphan, <stale_count> stale). Fix now?

Options:
- **A) Yes — walk through each problem doc**
- **B) Select some — pick which to fix**
- **C) Skip — just show the report, don't fix**

If A or B, proceed to the remediation walkthrough (step 4).
If C, exit.

If no stale and no orphan docs, **AND at least one `fresh` row exists**, say `All tagged docs are fresh.` and exit. **Exception:** if only `exempt` (and no fresh/stale/orphan) rows exist, the step-2 edge case handler at the bottom of step 2 already printed the exempt footnote without claiming "fresh" — don't print this line here either (exempt docs aren't tracked for drift, so calling them "fresh" is misleading).

### 4. Remediation walkthrough

For each problem doc (stale or orphan, in that priority order), pull its `drift`, `last_commit`, `covers`, and `missing` fields from the `TAGGED_REPORT` record. Fetch recent commits via the helper:

```bash
~/.claude/skills/koji/bin/koji-doc-status --commits "$path" --limit 5
```

**For stale docs**, print a per-doc briefing:

```
<path> — <drift> commits behind (stale)
  Covers: <covers>
  Doc last edit: <YYYY-MM-DD>
  Recent commits in covered paths (up to 5):
    <hash> <subject> (<age>)
    <hash> <subject> (<age>)
    ...
```

**For orphan docs**, the briefing emphasizes the missing path(s):

```
<path> — orphan
  Covers: <covers>
  Missing: <missing> (not in working tree)
  Doc last edit: <YYYY-MM-DD>
```

Then `AskUserQuestion`. Menu options depend on status:

**Stale menu:**
- **A) Open the doc for editing** — user manually updates; remind them: *"After you edit + git commit, drift resets automatically. Re-run `/inspect-doc-drift` to verify."*
- **B) Re-tag covers** — code moved? update the covers paths. Prompt for new paths, replace the frontmatter `covers:` list in-place.
- **C) Remove tag** — stop tracking drift. Delete the `covers:` key from the doc's YAML frontmatter.
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

Fetch the status record via the shared helper:

```bash
RECORD=$(~/.claude/skills/koji/bin/koji-doc-status "$path" 2>/dev/null | head -1)
```

Parse tab-separated fields: `<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>`.

If `status` is `missing`:

> <path> does not exist in the repo. Nothing to inspect.

If `status` is `untagged`: the doc exists but has no `covers:` frontmatter. Instead of dead-ending, run the **single-doc tagging flow** — same heuristic + 6-option menu (Accept / Edit / Empty / Skip / Quit / Mark as none) as the dashboard's per-doc walk in step 2a. Drill-in stops after the menu choice; it does NOT cascade to other docs.

If `status` is `malformed`:

> <path> has a `covers:` key but its value is not a YAML list. Fix the frontmatter to enable drift tracking.

Otherwise print a detail view using the record fields, plus recent commits via the helper:

```bash
~/.claude/skills/koji/bin/koji-doc-status --commits "$path" --limit 10
```

Drill-in uses the default (recent + noise filter). If the user wants the unfiltered or size-ranked view, they can re-invoke the helper directly with `--by-size` or `--per-path`.

```
<path>
  Covers: <covers>
  Doc last edit: <YYYY-MM-DD> (commit <last_commit>)
  Path existence: <all present | missing: <missing>>
  Drift: <drift> commits in covered paths since doc's last edit
  Threshold: <threshold>
  Status: <status>

  Recent commits in covered paths (up to 10, noise-filtered):
    <hash> <subject> (<age>)
    ...
```

### Drill-in remediation menu (only when actionable)

After the detail view, decide whether to show a remediation menu based on `status`:

- **`fresh` / `exempt`** → nothing to fix. Print `Read-only view. Nothing to remediate.` and exit.
- **`stale`** → show the **Stale menu** from step 4 of the dashboard walkthrough (Open / Re-tag / Remove tag / Delete / Exit).
- **`orphan`** → show the **Orphan menu** from step 4 (Re-tag / Remove tag / Delete / Exit).
- **`malformed`** → show a focused menu specific to frontmatter issues:
  - **A) Open the doc for editing** — user fixes the `covers:` key by hand
  - **B) Rewrite as a list** — prompt for space-separated paths; write `covers: [<path1>, <path2>]` or the indented-list form
  - **C) Mark intentionally untagged** — write `covers: none`
  - **D) Remove tag** — delete the `covers:` key (and the frontmatter block if empty)
  - **E) Exit** — leave it; re-run when ready

Tag-edit mechanics (Re-tag / Remove tag / Mark as none / Delete) are shared with step 4 of the dashboard walkthrough — same code path, single doc.

After the user picks an action (or Exit), print a one-line summary: `<path>: <action taken>` and return. The drill-in does NOT cascade to other problem docs — to fix multiple, re-run `/inspect-doc-drift` without args.

---

## Edge cases

- **Doc has no git history (new/untracked)**: DRIFT = 0. Still apply orphan check — if covered path missing, doc is orphan; otherwise fresh.
- **Covered path doesn't exist in repo**: doc is **orphan**. Remediation menu surfaces appropriate options.
- **Malformed frontmatter YAML**: skip with `warn: malformed frontmatter in <path>`.
- **Frontmatter exists but `covers` is not a list** (e.g., a scalar other than `none`, or missing): treat as malformed. `warn: covers must be a list or the sentinel 'none' in <path>`.
- **`covers: none` sentinel** (case-insensitive): doc is intentionally untagged. Status = `exempt`. Dropped from drift dashboard (counted in a footnote) and from the untagged bucket. Use for narrative, ops, or process docs with no code to track.
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

- `/kick-off` — parses the `## Load on Kick-Off` section of `agent-session.md` to decide which docs to load. Tagged docs that are stale still load at kick-off (with a warning) — skipping is a user decision via `/inspect-doc-drift`.
- `/wrap` — suggests tagged docs to add to the Load on Kick-Off section based on the session's git diff. Complements this skill: wrap decides what to track, `/inspect-doc-drift` decides what to fix.

**Shared primitive:** both `/kick-off` and `/inspect-doc-drift` read doc drift through `~/.claude/skills/koji/bin/koji-doc-status`. Modes:
- `--scan-tagged` / `--load-on-kickoff` / explicit paths → per-doc status records: `<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>` with `status ∈ {fresh, stale, orphan, exempt, untagged, missing, malformed}`. `exempt` = doc declared `covers: none` (intentionally untagged).
- `--commits <path> [--limit N] [--by-size|--per-path]` → per-line commit view `<short-hash> <subject> (<age>)`. Default picks most-recent N with a noise-prefix filter (typo/chore/deps/lint/fmt/bump/style/ci/build/docs/version). `--by-size` ranks by `files_changed × (insertions + deletions)`. `--per-path` round-robins across covered paths.
