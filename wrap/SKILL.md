---
description: "End-of-session wrap. Updates lessons, AI handoff, session log, archives old sessions, proposes commit, and generates starter prompt."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
---

# Session Wrap

Run the preamble to detect project configuration:

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji wrap ==="
echo "Project: $PROJECT_NAME ($PROJECT_ROOT)"
echo "Docs: $DOCS_PATH"
echo "Template: $TEMPLATE"
echo "Archive: $ARCHIVE_STRATEGY (threshold=$ARCHIVE_THRESHOLD, keep=$ARCHIVE_KEEP)"
echo "Has docs: $HAS_DOCS | Session log: $HAS_SESSION_LOG | Handoff: $HAS_HANDOFF | Lessons: $HAS_LESSONS"
```

If `HAS_DOCS` is `false`, tell the user to run `/koji-init` first and stop.

Execute the following steps **strictly in order**. Do not skip steps. Do not batch steps.

---

## Step 1 — Lessons

**Default action: SKIP.** Most sessions add zero lessons. **Zero is the success path**, not a missed step. A short, high-signal `lessons.md` is far more valuable than a long one full of noise — every weak entry buries the real future-time-savers underneath it.

Before you even consider an addition, read the most recent 5–10 entries in `$DOCS_PATH/lessons.md`. **That file is the calibration target.** Each existing entry is a rule that would still cost real time to rediscover today, with a concrete consequence and a code/commit reference. If a candidate doesn't sit at that bar, drop it.

### Three gates — a candidate must clear ALL THREE to qualify

1. **Rediscovery gate.** Could a senior dev rediscover this rule in <5 minutes by reading the code, the error message, the framework docs, or one targeted web search? If yes → SKIP.
2. **Common-knowledge gate.** Would a senior dev working in this stack already know this from the framework's own behavior? Restating import-collision rules, framework exception messages, or standard-library quirks is documentation theater, not a project lesson. If yes → SKIP.
3. **Burned-time gate.** Is there a concrete past incident where this rule's absence cost real time, shipped a bug, or required a user correction? "Could theoretically bite future me" does not qualify — only landmines that actually *bit*. If no → SKIP.

A candidate that fails any one of the three is noise. There is no "two out of three is close enough" — close-enough entries are exactly the ones that bury real lessons.

### The "would the user write this themselves?" test

The most valuable lesson is one whose absence would force the user to correct the same mistake again. If the user wouldn't bother writing this down unprompted — would just fix it and move on — neither should you.

- **Valuable shape:** "I had to correct Claude on X again — record the rule so the next agent doesn't repeat it."
- **Noise shape:** "Claude noticed something it had to work around once and is dutifully logging it."

If only Claude would write this entry, it's noise.

### Anti-examples — these LOOK project-specific but aren't

Common near-misses that pass a naive "is it project-touching?" check but fail the gates above. If your candidate matches one of these shapes, **skip it**:

- **Import-resolution / namespace collisions** ("X is exported by both libraries — alias one of them"). Generic language behavior; the analyzer error spells it out.
- **Framework exceptions restated as project rules** (e.g., "LayoutBuilder can't live inside intrinsic-dimension widgets"). The exception text already says this. Hitting it once teaches you forever.
- **Single-use design choices** ("we replaced widget A's built-in X with our own because pixel-fit on this one row"). Design taste, not a project landmine. Re-reading the code answers it in 2 minutes.
- **"We picked X over Y because the user preferred X"** — a preference recorded in code. Not a rule a future agent would walk into blind.
- **Tool or agent knowledge** — how Claude Code hooks work, how koji skills behave, how a git flag works. Belongs in tool docs, not project lessons.
- **Decisions already encoded in config or code** — if you just wrote it into `.koji.yaml`, `settings.json`, a `SKILL.md`, `CLAUDE.md`, or source, it's already persisted. Don't duplicate it as a lesson.
- **Workflow design choices** — "X belongs in kick-off not wrap". The skill file already encodes it.
- **Work outside this project's workspace** — koji, gstack, or other external-tool changes you happened to make while working in this repo belong in those tools' own repos.

### If — and only if — a candidate clears all three gates AND passes the user-test:

1. Read `$DOCS_PATH/lessons.md`.
2. Append the new entry **at the top** (below the header comment), one per line:
   ```
   YYYY-MM-DD — [Claude] — what went wrong → rule to prevent it
   ```
3. Be specific and tactical. Include the concrete consequence and a code/commit reference that ties the rule back to the work.

### Otherwise

**Print nothing about lessons.** Silent skip is the desired UX — do not announce that you considered lessons and found none. Move directly to Step 2a.

---

## Step 2a — AI Handoff

If project state or architecture rules changed (new decisions, gotchas, phase changes):

1. Read `$DOCS_PATH/AI_HANDOFF.md`
2. Update the relevant sections (state, rules, gotchas). Do NOT put task/roadmap items here — those go in TODO.
3. Do NOT rewrite unchanged sections. Only update what changed.
4. **Size constraint: keep AI_HANDOFF.md under ~80 lines / ~500 words.** This file is read on every session start — it must be a tight operational snapshot, not a knowledge base. If detail is needed, reference external docs rather than inlining.
5. **After writing**, check the file size:
   ```bash
   HANDOFF_LINES=$(wc -l < "$DOCS_PATH/AI_HANDOFF.md")
   echo "AI_HANDOFF.md: $HANDOFF_LINES lines"
   ```
   If over 80 lines, warn: `⚠️ AI_HANDOFF.md is $HANDOFF_LINES lines (cap: ~80). Trim stale/completed items or move detail to external docs.` Then re-edit to bring it under the cap before proceeding.

---

## Step 2b — TODO

Review the session for task-related changes: completed work, new tasks discovered, new tech debt, changed blockers.

**If nothing task-related changed this session**, skip this step entirely.

**If task-related changes exist:**

1. **If `$HAS_TODO` is `true`:** Read `$TODO_PATH` and update it:
   - Mark completed items
   - Add new tasks or tech debt discovered during the session
   - For completed tasks:
     - **If `$TODO_COMPLETED` is `inline`:** move to `## Completed` section, add `(YYYY-MM-DD)`
     - **If `$TODO_COMPLETED` is `archive`:** move to `$DOCS_PATH/COMPLETED_TASKS.md` (create if needed, with header: `> Archive of completed work. For active work, see [TODO.md](TODO.md).`), remove from TODO file
   - Do NOT rewrite unchanged sections.

2. **If `$HAS_TODO` is `false`:** This project doesn't have a TODO file yet. Create one at the **project root** (`$PROJECT_ROOT/$TODO_FILE`):
   - Copy the template from `$KOJI_SKILLS/templates/$TEMPLATE/$TODO_FILE` to `$PROJECT_ROOT/$TODO_FILE`
   - Populate it with the tasks from this session (completed items, new items, discovered debt)
   - If `$DOCS_PATH/AI_HANDOFF.md` contains roadmap items, task lists, or "Blocked On" sections, migrate them into the new TODO file and remove them from the handoff (keeps handoff under ~80 lines)
   - Update `AI_HANDOFF.md` header to link to the new TODO file
   - Tell the user: `Created $TODO_FILE at project root — task tracking is now separate from the handoff.`

---

## Step 2c — Update Load on Kick-Off (tag-driven, optional)

The goal: keep `## Load on Kick-Off` aligned with where the project is going. Three passes, one consolidated proposal:

- **Pass A** — deterministic floor: tagged docs whose `covers:` overlaps files touched this session.
- **Pass B** — Claude-judgment: tagged docs whose theme matches this session's work or the next-session mission.
- **Pass C** — review existing entries: currently-loaded docs that have stopped being relevant.

A and B propose **adds**. C proposes **removes**. All three feed one prompt — adds and removes flow together so the list doesn't grow unbounded across sessions.

**Gate — skip the whole step if there's nothing to consider:**

```bash
TAGGED_EXISTS=$(git grep -l -E '^[[:space:]]*covers[[:space:]]*:' -- '*.md' 2>/dev/null | head -1)
LOKO_HAS_BULLETS=$(awk '/^## Load on Kick-Off[[:space:]]*$/{f=1;next} f && /^## /{exit} f && /^[[:space:]]*[-*][[:space:]]+/{print;exit}' "$DOCS_PATH/agent-session.md" 2>/dev/null)
```

- `TAGGED_EXISTS` empty AND `LOKO_HAS_BULLETS` empty → nothing to add, nothing to review. If the repo has any tracked `.md` files, print the one-line nudge below; otherwise skip silently. Exit.
- `TAGGED_EXISTS` empty, `LOKO_HAS_BULLETS` non-empty → A+B have no candidate pool; run C only (judging untagged/exempt entries by theme).
- `TAGGED_EXISTS` non-empty, `LOKO_HAS_BULLETS` empty → run A+B; skip C (nothing to review).
- Both non-empty → run A+B+C.

The nudge (only fires when no tagged docs exist):

> Note: no docs are tagged with `covers:` yet. Run `/inspect-doc-drift` to tag docs so `/wrap` can auto-suggest context for future sessions.

**Load the doc-status reports:**

```bash
TAGGED_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --scan-tagged 2>/dev/null || true)
LOKO_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --load-on-kickoff 2>/dev/null || true)
```

Each record is tab-separated: `<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>`. For Pass A/B, **skip rows with `status ∈ {malformed, exempt}`** in `TAGGED_REPORT` — malformed has no usable covers; exempt declared `covers: none` (re-suggesting would contradict intent). Pass C scores everything in `LOKO_REPORT` (including exempt and untagged — those are docs the user opted into).

**Compute session context:**

```bash
TOUCHED=$(git diff --name-only HEAD 2>/dev/null; git log --name-only --format= HEAD@{1}..HEAD 2>/dev/null | sort -u)
```

Fall back to `git diff --name-only` against an available base if `HEAD@{1}` isn't usable.

---

### Pass A — reactive adds (deterministic floor)

For each tagged doc:

1. Take its `covers` paths (column 5 of `TAGGED_REPORT`).
2. Check if any touched file matches any covered path prefix.
3. If yes AND the doc is NOT already listed in `## Load on Kick-Off`, mark it a **Pass A candidate**.

Label each candidate with the reason: `covers <path> — <N> files changed`.

### Pass B — judgment adds (session + next-session themes)

Pass B runs **unless** the session is genuinely empty (no commits this session, no lessons added, no next-session signals, generated starter prompt is placeholder-only). In practice Pass B fires on almost every real `/wrap` invocation — wrap already has session context in Claude's memory by the time this step runs.

**Signals available to Claude for Pass B:**

- **This session's work**: commits made during this session (`git log HEAD@{1}..HEAD` subjects), lessons appended to `lessons.md` this wrap, and Claude's context of what was discussed / attempted / changed (already in Claude's working memory — no re-read needed).
- **Next-session mission**: the "Notes for Next Session" field wrap is writing (wrap has it in hand), `TODO.md` open items (if the file exists), and the starter prompt wrap is generating (same — in hand).

**Candidate pool for Pass B**: every tagged doc *not* already in `## Load on Kick-Off` and *not* already a Pass A candidate. (No double-suggesting.) For each candidate, gather: path, `covers:` paths, and the first 3 non-empty body lines (to signal the doc's purpose).

**Ask Claude (single batch reasoning pass)**: which of these docs are likely relevant to either (a) the themes of this session's work, or (b) the stated next-session mission? Return the subset as Pass B candidates. Each picked doc should carry a brief "why" tag — e.g., `session theme: invoice logic`, or `next-session TODO: schema migration`.

Err toward *skipping* — suggest only docs with a clear signal, not speculative matches. The user can always add more manually.

**Gate for Pass B to actually run**: check for at least one meaningful signal before invoking the judgment:
- Current session: at least one commit with a non-trivial subject this session, OR at least one lesson appended this wrap, OR Claude's context has substantive session content.
- Next session: "Notes for Next Session" is ≥ 20 chars and not a template placeholder, OR `TODO.md` has ≥ 1 incomplete item, OR the starter prompt contains a specific next-step clause.

If *none* of these hold, skip Pass B (cold-start case — usually first `/wrap` on a brand-new koji setup).

### Pass C — review existing entries (removes)

Pass C asks the inverse question: which currently-loaded docs are likely irrelevant for next session? Same dual-track reasoning as A+B, applied to the existing LOKO list.

**Skip Pass C entirely if any of:**
- `LOKO_REPORT` is empty (no bullets — nothing to review).
- The LOKO section was just created by this wrap (Pass A/B added the first entries on a previously-empty section — no review needed).
- This is the first `/wrap` on a fresh koji install. Detect via `agent-session.md` git history: if the file has never been committed, or the only commits are template scaffolding (no `## Session:` entries yet), skip C. Don't surprise users with removal suggestions on session 1.

**Candidate pool for Pass C**: every entry in `LOKO_REPORT` whose `status` is NOT `missing` (missing entries are a different problem — kick-off already warns about those).

**Pre-check — self-tagged temp docs (runs before scoring, on every LOKO entry):**

Read the first ~20 lines of each LOKO doc (window covers a typical YAML frontmatter block + the doc's H1 + the opening paragraph — enough to catch a self-declared lifecycle without dragging in body content that may quote other docs). Case-insensitive markers indicating the author opted the doc into a temporary lifecycle. **Match with word-boundary semantics — a substring match against negated phrasing like "non-temporary" or "this is NOT a temp doc" should NOT trigger the flag.** When in doubt (e.g., the marker appears inside a code block, blockquote, or sentence describing some *other* doc's lifecycle), do not flag — the recovery cost of a false negative is one more wrap; the recovery cost of a false positive is the user re-pinning the bullet:

- `temporary working doc` / `temporary doc` / `temp doc`
- `[TEMP]` or `(TEMP)` in the title or first heading
- `delete when` / `archive when` / `remove when`
- `gets archived or deleted` / `gets deleted` / `will be deleted`
- `rolls into` / `roll into` (koji-style "rolls into X.md when Y completes")
- An explicit expiry phrase: `remove after <date>`, `expires <date>`, `delete after <date>`

If any marker matches, flag the doc as **self-tagged temp**. For self-tagged temp docs:

- **Bypass the exempt/untagged default-keep bias** below. The author explicitly opted into a temp lifecycle by writing the marker — that's a stronger signal than the "manually opted in" bias was protecting against.
- Apply the normal theme check (Reactive + Theme-based) to decide if it's still in use.
- If the theme check says off-theme → mark for **deterministic** removal (see "Tag each removal" below). Rationale: the marker is a deterministic, author-written signal; treating it as deterministic lets the auto-mode fallback actually apply the removal. Only the LOKO bullet is removed — the doc file itself is untouched and can be re-pinned by the user.
- If the theme check says still-active → keep. The "when X completes" condition hasn't fired yet.

**Pre-check 2 — session-mention staleness (runs after the temp-doc pre-check, before scoring):**

Load per-bullet history from the helper:

```bash
LOKO_HISTORY=$(~/.claude/skills/koji/bin/koji-doc-status --loko-history 2>/dev/null || true)
```

Each row is tab-separated: `<path>\t<presence>\t<mentioned>\t<commits_since_add>` with `presence ∈ {new, recent, established}` and `mentioned ∈ {yes, no}`. The helper scans active-log `## Session:` bodies for the path or basename — archived sessions are not consulted, so the signal weakens with `archive.keep=1`. (Acceptable for the 80% case; revisit if it bites.)

For each LOKO entry where `presence=established` AND `mentioned=no`:

- The bullet has survived ≥ 2 wraps and is absent from every active-log session body. This is the "I added this 3 wraps ago, never used it again" pattern.
- Mark as **deterministic** removal candidate. **This overrides the reactive keep-on-touch decision below** — if the user hasn't referenced the doc in any active session despite multiple wraps, the doc isn't load-bearing even when its covered code is hot. Code-freshness ≠ doc-freshness; session-mention is the better proxy for whether the doc is actually being used.
- Treat the same as a self-tagged temp marker for tagging purposes (deterministic, auto-applies in auto mode).

Skip Pre-check 2 if any of:

- The active log has fewer than 2 `## Session:` entries (cold start; no signal yet).
- The helper returns no rows (LOKO empty or helper errored).
- The doc was already flagged by the temp-doc pre-check above (no double-tagging).

**Score each candidate against this-session + next-session signals** (same signals as Pass B):

- **Reactive**: did its `covers:` paths intersect with `TOUCHED` this session? If yes → keep (theme is active). **Exception:** if Pre-check 2 already flagged this doc as `established + unmentioned`, the reactive keep is overridden — the session-mention signal beats the code-touch signal.
- **Theme-based (Claude-judgment)**: does the doc's purpose match the session's work or the next-session mission per `TODO.md` / Notes for Next Session / starter prompt / conversation context? If yes → keep.
- For untagged or exempt entries (`covers: none` or no `covers:`) **that are NOT self-tagged temp and NOT flagged by Pre-check 2**: default-keep. Only mark for removal if Claude judges the doc clearly off-theme for both this session AND next session — these were manually opted in, so bias hard toward keeping. (Self-tagged temp and session-stale docs skip this default-keep bias per the pre-checks above.)

**Conservative guards — skip suggesting removal if any hold:**

1. **Just-added this session**: doc path is in Pass A's or Pass B's candidate set (don't add and remove in the same wrap).
2. **Drift status is `stale` or `orphan`**: user may have it in LOKO specifically because they want to fix it next session. Leave alone. (**Exception:** doesn't apply to docs flagged by Pre-check 1 (self-tagged temp) or Pre-check 2 (`established + unmentioned`) — both signals are stronger than the "might want to fix" assumption. If two wraps have passed without any session mention, that "might want to fix" signal is stale too.)
3. **Covers next-session mission**: if any of the doc's `covers:` paths fall inside the next-session scope (per starter prompt / Notes / TODO items), keep — Claude judgment.

**Deferred guard (known gap)**: "manually re-added in last 3 sessions". Detecting bouncing-back via `agent-session.md` git history is doable but adds cost; not implemented here. A doc the user keeps re-adding will get re-suggested for removal each wrap until they either pin it some other way or the theme stabilizes. Acceptable for the 80% case — revisit if it bites.

**Pass C candidates that survive the guards** become **remove suggestions**. Tag each removal with the strongest signal that fires:

- **Deterministic** — any of:
  - Covers paths untouched ≥ N commits, where N defaults to the drift threshold.
  - Self-tagged temp marker found (Pre-check 1).
  - `presence=established` AND `mentioned=no` (Pre-check 2 — session-mention staleness).
- **Judgment** — off-theme per Claude, no deterministic backing. Carry the doc's `presence` (new/recent/established) into the tag — the auto-mode fallback uses it.

The auto-mode fallback below treats deterministic vs judgment differently, and inside judgment, `presence` decides auto-apply vs advisory.

If Pass C produces zero remove candidates after guards, that's fine — proceed with adds-only.

---

### Consolidated proposal

Merge Pass A + Pass B (adds) and Pass C (removes). If both lists are empty, skip silently — no prompt, no output.

**Render the proposal as text first** (visible in any mode):

> **Update `## Load on Kick-Off`?**
>
> **Add (<X>):**
>   - docs/<A>.md (touched 3 files in backend/<module>/)
>   - docs/<B>.md * (session theme: invoice rewrite)
>   - docs/<C>.md * (next-session TODO: "migrate schema")
>
> **Remove (<Y>):**
>   - docs/<P>.md — untouched 12 commits, off-theme for next session
>   - docs/<R>.md — self-tagged temp ("delete when phase X completes"), off-theme
>   - docs/<S>.md — 3 wraps in LOKO, no active-log session mention; covers paths active but doc unused
>   - docs/<Q>.md * — theme: irrelevant to next-session UI work
>   - docs/<T>.md *! — theme: probably no longer relevant (recent — pin to keep)
>
> `*` = Claude-judgment (theme-based). `!` = recent addition (advisory only in auto mode — pin if you want to keep). Unmarked = deterministic (diff match, untouched ≥ threshold, self-tagged temp, or session-stale).

Omit the Add or Remove block if its list is empty.

**Interactive mode — fire `AskUserQuestion`:**

Options:
- **A) Apply all** — add and remove as proposed.
- **B) Adds only** — apply additions, leave existing entries alone.
- **C) Removes only** — apply removals, skip additions.
- **D) Select individually** — show a numbered list across both Add and Remove sections; user picks indices to apply.
- **E) Skip** — leave the section unchanged.

Omit B if no adds, omit C if no removes, omit A/B/C as redundant if either bucket is empty (collapses to the obvious one-bucket prompt).

**Non-interactive fallback — auto mode, or any reason `AskUserQuestion` should not fire:**

The proposal text already printed. Decide what to apply automatically:

- **Adds**: apply automatically. Pass A is deterministic; Pass B already errs toward skipping. Low downside.
- **Removes — deterministic** (untouched ≥ threshold, OR self-tagged temp marker found, OR `established + unmentioned`): apply automatically. All three are author/usage-based signals strong enough to act on without confirmation.
- **Removes — judgment-only** (no deterministic backing, picked purely by Claude theme call): apply automatically **only when `presence=established`** (≥ 2 wraps in LOKO). Two wraps of grace before judgment-removes auto-apply gives the user a cycle to notice and pin a doc they want to keep — without that grace, the asymmetric ratchet (adds via judgment auto-apply, removes via judgment never apply) lets the LOKO list grow unbounded across sessions.
- **Removes — judgment + `presence=recent` or `presence=new`**: list as **advisory** and do NOT remove. Auto mode shouldn't yank a freshly-added doc on a hunch — let it ride one more wrap so the user can pin if they meant to keep it.

After applying (or not), emit a one-liner:

> Updated `## Load on Kick-Off`: +<X>, -<Y>. To revert: `git restore "$DOCS_PATH/agent-session.md"`.
> Advisory removals (not applied): docs/<P>.md, docs/<Q>.md. Edit `## Load on Kick-Off` in `agent-session.md` to drop them.

Skip either line if its bucket is empty. If nothing was applied and nothing is advisory, skip the one-liner entirely.

---

**If the user picks A/B/C/D (or auto mode applies), update `agent-session.md`:**

**Adds**:
1. Check if a `## Load on Kick-Off` H2 section exists above the first `## Session:` entry.
2. If not, create it immediately above the first `## Session:` heading (or at EOF if no session entries).
3. Append chosen docs as bullets in path-form:
   ```markdown
   - docs/<A>.md
   ```

**Removes**:
1. Locate the `## Load on Kick-Off` section.
2. For each chosen doc path, find the bullet line (matching the resolved `.md` path — handles markdown-link form `[label](path.md)` and plain-path form). Delete only that line.
3. Preserve formatting of unaffected lines: bullet style, links, indentation, comments.
4. Do NOT delete the H2 itself even if the section ends up empty — leave the heading + any HTML comments. Kick-off treats an empty section as a no-op.

**Report**:

> Updated Load on Kick-Off: added <X> doc(s) (<Xa> reactive, <Xb> theme-based), removed <Y> doc(s).

### Cold-start behavior (explicit)

- **Zero tagged docs, zero `.md`**: step skipped silently.
- **Zero tagged docs, some `.md` exist**: one-line nudge to run `/inspect-doc-drift`. No further action.
- **Tagged docs, empty session** (first ever wrap, no commits, no lessons, no notes yet): A empty + B gated off + C skipped (first wrap) → nothing suggested. The step effectively no-ops until there's enough signal to act on. Don't pester users with bad suggestions from a blank slate.
- **LOKO empty, tagged docs exist**: A+B run; C skipped (nothing to review).
- **LOKO has bullets, no tagged docs anywhere**: C runs over the existing entries (untagged/exempt only). A+B have no candidate pool. The default-keep stance for untagged entries means C usually no-ops here too.

---

## Step 3 — Session Log

1. Read `$DOCS_PATH/agent-session.md`
2. Count the session entries currently in the file.
3. **If the count >= $ARCHIVE_THRESHOLD**, perform archive rotation:

   **If `$ARCHIVE_STRATEGY` is `numbered`:**
   - Check `$DOCS_PATH/$ARCHIVE_DIR/` for existing `archive-NN.md` files
   - Create the next `archive-NN.md` (increment highest NN by 1)
   - Move the oldest entries into it, keeping only `$ARCHIVE_KEEP` most recent
   - Update the archive reference comment at the top of `agent-session.md`

   **If `$ARCHIVE_STRATEGY` is `dated`:**
   - For each entry to archive, create `$DOCS_PATH/$ARCHIVE_DIR/YYYY-MM/DD-slug.md`
   - Update `$DOCS_PATH/$ARCHIVE_DIR/INDEX.md` with a markdown link
   - Remove archived entries from `agent-session.md`
   - Keep only `$ARCHIVE_KEEP` most recent entries

4. Check if the most recent session entry has an `[in progress]` tag (created by `/take-note`):

   **If `[in progress]` entry exists:**
   - Finalize it in-place: remove the `[in progress]` tag from the title
   - Update Summary and Key Achievements with the full session's work
   - Fill in "Notes for Next Session" (this is wrap's responsibility, not take-note's)
   - Do NOT create a new entry — finalize the existing one

   **If no `[in progress]` entry exists:**
   - Read the session template (first check `$DOCS_PATH/SESSION_TEMPLATE.md`, then `$KOJI_SKILLS/templates/$TEMPLATE/SESSION_TEMPLATE.md`)
   - Append a new session entry at the **bottom** of `agent-session.md`, filling in all fields

5. Use `[Claude]` as the agent tag (or the appropriate tag from `$AGENTS`).

---

## Step 4 — Permission Hygiene

Check if `.claude/settings.local.json` exists. If it does:

1. Read `.claude/settings.local.json` (session-accumulated permissions)
2. Read `.claude/settings.json` (committed permissions)
3. Compare — find permissions in local that aren't already in committed
4. **Filter with judgement.** First, check existing `settings.json` permissions — if a new permission is already covered by a broader pattern (e.g., `Bash(git diff:*)` already covers `Bash(git diff --stat)`), skip it entirely. Then categorize the remaining into three buckets:

   **Auto-promote** (clearly safe, reusable across sessions — add without asking):
   - Standard dev commands: `git status`, `git diff`, `git log`, `git add`, `git commit`, `git branch`, `git stash`, `git rev-parse`
   - Build/run commands: `npm run`, `npm install`, `npx`, `cargo`, `go build`, `go test`, `python`, `pytest`, `make`
   - File ops: `mkdir`, `chmod`, `ls`, `cat`, `wc`
   - Tool permissions: `Read`, `Edit`, `Write`, `Glob`, `Grep`
   - koji scripts: `source <(~/.claude/skills/koji/*)`

   **Auto-skip** (never promote):
   - Absolute paths specific to this machine (e.g., `/Users/h.b./specific/file`)
   - One-time exploratory commands (ad-hoc `find`, `grep` with very specific patterns)
   - Destructive commands: `rm -rf`, `git push --force`, `git reset --hard`, `git checkout .`
   - Commands that should always prompt for safety

   **Ask user** (grey area — potentially useful but not obviously safe):
   - Broader `Bash` patterns that aren't standard dev commands (e.g., `Bash(curl:*)`, `Bash(docker:*)`)
   - Commands that touch external services (e.g., `Bash(gh:*)`, `Bash(ssh:*)`)
   - Permissions that are project-specific but not machine-specific (e.g., `Bash(./scripts/deploy.sh)`)
   - **Minimize prompts aggressively:**
     - Batch similar permissions into one group (e.g., `docker build`, `docker compose`, `docker run` → ask once as "Docker commands")
     - If the user already approved or denied a similar pattern in `settings.json` (e.g., they have `Bash(docker build:*)` already), infer their intent for related ones (`docker compose`, `docker run`) and auto-promote without asking
     - If the deny list has a pattern, auto-skip similar ones without asking
     - **Goal: zero prompts most sessions.** Only ask when something genuinely new and ambiguous shows up.

5. **If there are auto-promoted permissions**, briefly list them (one line summary, not a full list):

   > Promoted 4 permissions to settings.json (git, npm, koji scripts). Run `cat .claude/settings.json` to review.

6. **Only if there are grey-area items that can't be inferred**, ask — and keep it to one prompt max:

   > One permission needs your call:
   > - `Bash(docker compose:*)` — keep for next session? (y/n)

7. Merge auto-promoted + user-approved into `.claude/settings.json`, preserving existing entries. Do not duplicate.
8. If nothing new to promote, skip this step entirely — no output.

---

## Step 5 — Commit Proposal

**Important:** Steps 1-4 above only edit files. No commits happen until this step.

1. Run `git status` and `git diff --stat` to capture **all** changes (session work, wrap doc updates, and permission changes).
2. Classify every changed file as either **code** (session work) or **docs** (koji files: `$DOCS_PATH/lessons.md`, `$DOCS_PATH/AI_HANDOFF.md`, `$TODO_PATH`, `$DOCS_PATH/COMPLETED_TASKS.md`, `$DOCS_PATH/agent-session.md`, `$DOCS_PATH/SESSION_TEMPLATE.md`, `$DOCS_PATH/$ARCHIVE_DIR/**`, `.claude/settings.json`).
3. Determine the commit strategy:

   **If there are only doc changes (work was already committed):**
   - Propose a single commit: `docs(koji): update session logs`
   - Stage all doc files, present the message, wait for approval, commit.

   **If there are only code changes (no docs were modified — unlikely during wrap):**
   - Propose a single conventional commit for the work.
   - Stage all files, present the message, wait for approval, commit.

   **If there are both code changes AND doc changes (mixed worktree):**

   First, check `$COMMIT_STRATEGY` for a saved preference:

   **If `$COMMIT_STRATEGY` is `together`:** Use the saved preference — stage everything, propose one commit. Tell the user: `Using saved preference: single commit. (Change with koji-config set commit_strategy split)`

   **If `$COMMIT_STRATEGY` is `split`:** Use the saved preference — split into two commits (code first, docs second). Tell the user: `Using saved preference: split commits. (Change with koji-config set commit_strategy together)`

   **If `$COMMIT_STRATEGY` is empty (no preference yet):** Ask using AskUserQuestion:

   > This wrap has both code and doc changes. How should I commit?

   Options:
   - A) One commit — everything together (recommended for most workflows)
   - B) Split — code commit first, then docs commit
   - C) One commit + remember — save this as my default for future wraps

   If A: stage everything, propose one commit.
   If B: split into two commits (code first, docs second).
   If C: run `koji-config set commit_strategy together`, then stage everything, propose one commit.

   **Override:** If the saved preference is `together` but the code and docs changes are clearly unrelated (e.g., code is a bug fix but docs are from a different task), use AskUserQuestion to suggest splitting for this one time. Do NOT change the saved preference.

   **Together**: Stage everything, propose one conventional commit, wait for approval, commit. **Done — one commit total.**
   **Split**: Execute exactly two commits in sequence:
     1. Stage **only code files** (`git add` each by name). Present the work commit message, wait for approval, commit.
     2. Stage **only doc files** (`git add` each by name). Commit with `docs(koji): update session logs`. This second commit does not need separate approval — it was approved as part of the split decision.
     **Done — two commits total.**

4. **After committing**, run `git status`. If the worktree is clean, move on. If there are unexpected leftover changes, **report them to the user** but do NOT create additional commits. Let the user decide in the next step or manually.

---

## Step 6 — Starter Prompt & Session Name

**Session name** — generate a short kebab-case name that describes **this session's work** (what was done, not what's next). Derive it from the session log entry you just wrote. Examples: `handoff-trim-agent-cleanup`, `auth-middleware-refactor`, `cso-audit-batch-1`.

Tell the user:

> **Session name:** `<suggested-name>`
> Rename this session: `claude -n "<suggested-name>"`

**Starter prompt** — generate a **3-5 sentence** briefing for the next session:
- Current project state (1 sentence)
- What was accomplished this session (1 sentence)
- The single most important thing to do next (1-2 sentences)
- Any blockers or things to watch out for (if applicable)

Output this clearly labeled as **"Starter Prompt for Next Session:"**

Finally, remind the user:
> Tip: Next session, run `/kick-off` to auto-load this context — no need to paste.

---

## Checklist

Before finishing, verify:
- [ ] `lessons.md` updated (if applicable)
- [ ] `AI_HANDOFF.md` updated (if state/rules changed)
- [ ] `$TODO_FILE` updated (if task state changed)
- [ ] Session entry appended to `agent-session.md`
- [ ] Archive rotation performed (if threshold reached)
- [ ] Permissions reviewed (if new ones in settings.local.json)
- [ ] Commit proposed (awaiting approval)
- [ ] Starter prompt generated
