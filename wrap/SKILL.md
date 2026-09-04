---
description: "End-of-session wrap. Updates lessons, AI handoff, session log, archives old sessions, commits, and generates starter prompt. No prompts."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
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
echo "Commit gate: $WRAP_COMMIT_GATE"
```

`/wrap` runs without prompts. Every step below applies its auto policy and prints the one-line summary that policy defines; there is no interactive branch. One exception: the commit-strategy question in Step 5 (sub-step 6), asked until a preference is saved — a policy choice that persists, not a per-wrap confirmation.

If `HAS_DOCS` is `false`, tell the user to run `/koji-init` first and stop.

Execute the following steps **strictly in order**. Do not skip steps. Do not batch steps.

---

## Step 1 — Lessons

**Default action: SKIP.** Most sessions add zero lessons — that's the success path. Every weak entry buries real future-time-savers underneath it. Before considering an addition, read the most recent 5–10 entries in `$DOCS_PATH/lessons.md` — that file is the calibration target.

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

### Anti-examples — skip these shapes

- Import/namespace collisions, framework exceptions, single-use design choices, taste preferences, tool/agent knowledge, decisions already in config/code, workflow design choices, and changes made to *other* repos. All fail the gates above — the analyzer/exception/code itself is the persistence layer.

### If — and only if — a candidate clears all three gates AND passes the user-test:

1. Read `$DOCS_PATH/lessons.md`.
2. Append the new entry **at the top** (below the header comment), one per line:
   ```
   YYYY-MM-DD — [tag1,tag2] — what went wrong → rule to prevent it
   ```
   Tags are optional but recommended — they sharpen `--lessons-relevant` scoring at `/kick-off`. The `[Agent]` field has been dropped; the parser doesn't use it and it just adds noise to every entry.
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

**Run the completion-reconcile check first** — it is deterministic and runs even when you think nothing changed, so shipped work can no longer silently miss the archive:

```bash
if [ "$HAS_TODO" = "true" ] && [ "$TODO_COMPLETED" = "archive" ]; then
  UNARCHIVED=$(grep -nE '^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+(\[[xX]\]|✅|DONE[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2})' "$TODO_PATH" 2>/dev/null | grep -viE '\[archived[^]]*\][[:space:]]*$' || true)
  UNARCHIVED_COUNT=$(printf '%s' "$UNARCHIVED" | grep -c '[^[:space:]]' || true)
  [ "${UNARCHIVED_COUNT:-0}" -gt 0 ] && printf '%s\n' "$UNARCHIVED"
  echo "Unarchived completed items: ${UNARCHIVED_COUNT:-0}"
fi
```

`archive` mode moves a completed item *out* to `COMPLETED_TASKS.md`, so a done-marked list item still in `$TODO_FILE` without a trailing `[archived]` tag is unreconciled. (`inline` mode keeps completed items in-file by design, so the check no-ops — and koji's own default is `inline`.)

The grep is a **best-effort hint, not the authority**: it catches checkbox-style markers (`- [x]`, `1. [x]`, `✅`, `DONE <date>`) but will miss prose-status TODOs (e.g. the default template's `**Status**: Done`) and isn't section-aware. So in `archive` mode the floor is an explicit check, not the count:

- **In `archive` mode you may not finish this step without confirming archival from your own memory of what shipped this session** — not just the grep. Close with one line: `archived N` or `nothing to archive`.
- Each item you archive (grep-flagged or found yourself): write its summary per the `archive` rule below, or — if it isn't truly done (e.g. merged-vs-still-on-`develop` ambiguity) — log a one-line defer reason. Ignore anything already under a `## Completed` / `## Done` heading — that's the archive area, not unreconciled work.
- Skip the rest of this step only when there's genuinely no completed work **and** nothing else task-related changed this session. Otherwise continue below — `inline` mode skips the archive reconcile but still marks completed items and updates tasks. (In `archive` mode, still emit the one-line confirmation above before skipping.)

**If task-related changes exist:**

1. **If `$HAS_TODO` is `true`:** Read `$TODO_PATH` and update it:
   - Mark completed items
   - Add new tasks or tech debt discovered during the session
   - For completed tasks:
     - **If `$TODO_COMPLETED` is `inline`:** move to `## Completed` section, add `(YYYY-MM-DD)`
     - **If `$TODO_COMPLETED` is `archive`:** author a summary into `$DOCS_PATH/COMPLETED_TASKS.md` (create if needed, with header: `> Archive of completed work. For active work, see [TODO.md](../TODO.md).`), then **remove the item from `$TODO_FILE`** — *unless* it belongs to an open milestone batch whose done items give context to the still-open ones; then keep it inline and append the exact literal `[archived]` at the **end** of its line (no date or text inside the brackets — those go in the summary; the reconcile check only honors a trailing `[archived]`). Author the summary (mechanism, gates, the numbers that matter, a plan pointer) — don't just copy the TODO line.
   - Do NOT rewrite unchanged sections.

2. **If `$HAS_TODO` is `false`:** This project doesn't have a TODO file yet. Create one at the **project root** (`$PROJECT_ROOT/$TODO_FILE`):
   - Copy the template from `$KOJI_SKILLS/templates/$TEMPLATE/$TODO_FILE` to `$PROJECT_ROOT/$TODO_FILE`
   - Populate it with the tasks from this session (completed items, new items, discovered debt)
   - If `$DOCS_PATH/AI_HANDOFF.md` contains roadmap items, task lists, or "Blocked On" sections, migrate them into the new TODO file and remove them from the handoff (keeps handoff under ~80 lines)
   - Update `AI_HANDOFF.md` header to link to the new TODO file
   - Tell the user: `Created $TODO_FILE at project root — task tracking is now separate from the handoff.`

**Flip status on shipped work — run this whenever a plan or research doc's work shipped this session, even if no TODO line changed** (a plan can ship without a TODO edit). Step 2c *reads* plan status but never *sets* it — close that gap here:

- `~/.claude/skills/koji/bin/koji-plans-research --filter active` lists active plans **and** research (tab-separated; field 1 is the path, field 2 is `plan` or `research`).
- For each **plan** whose work shipped: `~/.claude/skills/koji/bin/koji-plans-research --set-status <path> completed`. Whether it shipped is your judgment; the helper does the write; the file stays in place (the archive points *at* it — only the `status:` field flips).
- For each **research** doc whose validation condition clearly fired this session: `~/.claude/skills/koji/bin/koji-plans-research --set-status <path> validated`. If it's ambiguous, leave it and note it. No auto-validation on a hunch.

**Re-check each still-active plan's `next-step` (v0.8.0).** A `next-step:` line survives wraps untouched by default, so a step that was actually done this session keeps being rendered at every `/kick-off` until someone notices. Run this after the status flips:

```bash
ACTIVE_PLANS=$(~/.claude/skills/koji/bin/koji-plans-research --filter active-plan 2>/dev/null || true)
SESSION_START=$(cat "$SESSION_START_FILE" 2>/dev/null || true)
if [ -n "$SESSION_START" ] && git rev-parse --verify "$SESSION_START" >/dev/null 2>&1; then
  SESSION_SUBJECTS=$(git log --format=%s "$SESSION_START..HEAD" 2>/dev/null || true)
  TOUCHED=$( (git diff --name-only "$SESSION_START..HEAD" 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | sort -u)
else
  SESSION_SUBJECTS=""
  TOUCHED=$(git diff --name-only HEAD 2>/dev/null)
fi
printf '%s\n' "$ACTIVE_PLANS" | cut -f1,7
```

(Step 2c recomputes `SESSION_START`/`TOUCHED` for itself — each Bash block is a fresh shell; the duplication is deliberate.) Each record is tab-separated; field 1 is the plan path, field 7 its `next-step` (`-` when empty). A plan is a **candidate** when any of these hold — plans matching none are never prompted:

- its path is in `TOUCHED` (the plan file itself was edited this session), or
- its slug (file name without `.md`) appears in a `SESSION_SUBJECTS` line, or
- you can tell from this session's work that the step the `next-step` describes was done or has changed — you have the session in working memory, the same signal Pass B relies on.

Skip candidates whose `next-step` is `-`. For each remaining candidate, show the current `next-step` and decide **keep** or **rewrite**:

Rewrite only on a concrete signal that the step was done or superseded (a commit subject, a TODO you just completed, a status you just flipped). When in doubt, keep.

Write through the helper — never edit frontmatter by hand:

```bash
~/.claude/skills/koji/bin/koji-plans-research --set-next-step "<path>" "<one line>"
```

The text must be one line; the helper stores it as a quoted scalar (so `#` and `:` survive `--get`) and refuses a file with no frontmatter (exit 3 — leave that one alone and note it). Close with one line, `next-step: rewrote N, kept M`, or print nothing when there were no candidates.

---

## Step 2c — Update Load on Kick-Off (tag-driven, optional)

The goal: keep `## Load on Kick-Off` aligned with where the project is going. Three passes, one consolidated proposal:

- **Pass A** — deterministic floor: tagged docs whose `covers:` overlaps files touched this session (A.1), plus active plans not yet in LOKO (A.2).
- **Pass B** — Claude-judgment: tagged docs whose theme matches this session's work or the next-session mission.
- **Pass C** — review existing entries: currently-loaded docs that have stopped being relevant.

A and B propose **adds**. C proposes **removes**. All three feed one proposal — adds and removes flow together so the list doesn't grow unbounded across sessions.

**Gate — skip the whole step if there's nothing to consider:**

```bash
TAGGED_EXISTS=$(git grep -l -E '^[[:space:]]*covers[[:space:]]*:' -- '*.md' 2>/dev/null | head -1)
ACTIVE_PLAN_COUNT=$(~/.claude/skills/koji/bin/koji-plans-research --count active-plan 2>/dev/null || echo 0)
LOKO_HAS_BULLETS=$(awk '/^## Load on Kick-Off[[:space:]]*$/{f=1;next} f && /^## /{exit} f && /^[[:space:]]*[-*][[:space:]]+/{print;exit}' "$DOCS_PATH/agent-session.md" 2>/dev/null)
```

If `TAGGED_EXISTS` empty AND `ACTIVE_PLAN_COUNT` is `0` AND `LOKO_HAS_BULLETS` empty → nothing to add, nothing to review. If the repo has any tracked `.md` files, print the one-line nudge below; otherwise skip silently. Exit.

Otherwise, run only the passes whose preconditions hold:

- **Pass A.1** (covers-driven adds) runs when `TAGGED_EXISTS` is non-empty.
- **Pass A.2** (active-plan adds) runs when `ACTIVE_PLAN_COUNT > 0`.
- **Pass B** (judgment adds) runs when `TAGGED_EXISTS` is non-empty (judgment adds remain covers-based).
- **Pass C** (removes) runs when `LOKO_HAS_BULLETS` is non-empty.

The nudge (only fires in the all-empty case above, and only when tracked `.md` files exist):

> Note: no docs are tagged with `covers:` yet. Run `/inspect-doc-drift` to tag docs so `/wrap` can auto-suggest context for future sessions.

**Load the doc-status reports:**

```bash
TAGGED_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --scan-tagged 2>/dev/null || true)
LOKO_REPORT=$(~/.claude/skills/koji/bin/koji-doc-status --load-on-kickoff 2>/dev/null || true)
```

Each record is tab-separated: `<path>\t<status>\t<drift>\t<last_commit>\t<covers>\t<missing>`. For Pass A/B, **skip rows with `status ∈ {malformed, exempt}`** in `TAGGED_REPORT` — malformed has no usable covers; exempt declared `covers: none` (re-suggesting would contradict intent). Pass C scores everything in `LOKO_REPORT` (including exempt and untagged — those are docs the user opted into).

**Compute session context:**

The session boundary lives in `$SESSION_START_FILE` (resolved by `koji-detect` to `~/.config/koji/sessions/<project>-<hash>/start` — global state, never in the repo). Read it — do NOT use `HEAD@{1}`, which is reflog movement (branch switches, rebases, amends all break it).

```bash
SESSION_START=$(cat "$SESSION_START_FILE" 2>/dev/null || true)
if [ -n "$SESSION_START" ] && git rev-parse --verify "$SESSION_START" >/dev/null 2>&1; then
  TOUCHED=$( (git diff --name-only "$SESSION_START..HEAD" 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | sort -u)
else
  # Sentinel missing (/wrap without prior /kick-off) OR session-start commit was rewritten (rebase orphan). Degrade to working-tree only.
  TOUCHED=$(git diff --name-only HEAD 2>/dev/null)
fi
```

`$SESSION_START` (when set) is also used by Pass B below for `git log "$SESSION_START..HEAD"` subjects.

---

### Pass A — reactive adds (deterministic floor)

Two deterministic sub-rules. Both feed the same Pass A candidate set and flow through the consolidated proposal together.

**A.1 — covers-driven (tagged docs)**

For each tagged doc:

1. Take its `covers` paths (column 5 of `TAGGED_REPORT`).
2. Check if any touched file matches any covered path prefix.
3. If yes AND the doc is NOT already listed in `## Load on Kick-Off`, mark it a **Pass A candidate**.

Label each candidate with the reason: `covers <path> — <N> files changed`.

**A.2 — active plans (status-driven)**

Fetch active plans (only when `ACTIVE_PLAN_COUNT > 0` per the gate above):

```bash
ACTIVE_PLANS_RECORDS=$(~/.claude/skills/koji/bin/koji-plans-research --filter active-plan 2>/dev/null || true)
```

Each record is tab-separated: `<path>\t<kind>\t<status>\t<status_source>\t<origin>\t<target>\t<next_step>`. For each record, check whether `<path>` is already listed in `## Load on Kick-Off`. Use the same path-matching Pass C uses for removes (handles both `[label](path)` and plain-path bullet forms, including the `/`-prefixed root-relative form). If NOT already listed, mark as a **Pass A candidate**. Label:

> `active plan (status: <pending|in-progress>)`

A.2 surfaces plans that `/duet-plan`, `/plan-eng-review`, or any other planning skill produced but never auto-flowed into LOKO — so the next session loads them via the existing LOKO read mechanism instead of relying on `/kick-off` Tier 2 keyword-matching or the Tier 1 small-set safety net.

### Pass B — judgment adds (session + next-session themes)

Pass B runs **unless** the session is genuinely empty (no commits this session, no lessons added, no next-session signals, generated starter prompt is placeholder-only). In practice Pass B fires on almost every real `/wrap` invocation — wrap already has session context in Claude's memory by the time this step runs.

**Signals available to Claude for Pass B:**

- **This session's work**: commits made during this session (`git log "$SESSION_START..HEAD"` subjects when `$SESSION_START` is set; otherwise rely on lessons + Claude's working memory), lessons appended to `lessons.md` this wrap, and Claude's context of what was discussed / attempted / changed (already in Claude's working memory — no re-read needed).
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

- Bullet survived ≥ 2 wraps and is absent from every active-log session body — the "added 3 wraps ago, never used again" pattern.
- Mark as **deterministic** removal candidate. **Overrides the reactive keep-on-touch decision below** — session-mention beats code-touch as a use signal.
- Treat as a self-tagged temp marker (deterministic, auto-applies in auto mode).

Skip Pre-check 2 if any of:

- Fewer than 2 total `## Session:` entries exist across the active log AND archive files (cold start; no signal yet). Count via `~/.claude/skills/koji/bin/koji-doc-status --count-sessions`. The active-log-only count would die under default `archive.keep=1` because rotation leaves at most 1 entry in the active log post-archive.
- The helper returns no rows (LOKO empty or helper errored).
- The doc was already flagged by the temp-doc pre-check above (no double-tagging).

**Pre-check 3 — completed plans (runs after the session-mention pre-check, before scoring):**

For each LOKO entry whose path starts with `$PLANS_DIR/`, query its current status:

```bash
PLAN_RECORD=$(~/.claude/skills/koji/bin/koji-plans-research --get "<path>" 2>/dev/null || true)
```

Parse the tab-separated record (`<path>\t<kind>\t<status>\t<status_source>\t...`). If `<kind>` is `plan` AND `<status>` is `completed`, mark as **deterministic** removal. Label:

> `<path> — plan completed, no longer relevant`

The `status: completed` field is an explicit author-controlled signal (the same way self-tagged temp markers are author-controlled). Treating it as deterministic lets the auto-mode fallback apply the removal without confirmation — symmetric with how Pass A.2 auto-adds active plans.

Skip Pre-check 3 if `LOKO_REPORT` is empty or has zero entries under `$PLANS_DIR/`.

**Score each candidate against this-session + next-session signals** (same signals as Pass B):

- **Reactive**: did its `covers:` paths intersect with `TOUCHED` this session? If yes → keep (theme is active). **Exception:** if Pre-check 2 already flagged this doc as `established + unmentioned`, the reactive keep is overridden — the session-mention signal beats the code-touch signal.
- **Theme-based (Claude-judgment)**: does the doc's purpose match the session's work or the next-session mission per `TODO.md` / Notes for Next Session / starter prompt / conversation context? If yes → keep.
- For untagged or exempt entries (`covers: none` or no `covers:`) **that are NOT self-tagged temp and NOT flagged by Pre-check 2**: default-keep. Only mark for removal if Claude judges the doc clearly off-theme for both this session AND next session — these were manually opted in, so bias hard toward keeping. (Self-tagged temp and session-stale docs skip this default-keep bias per the pre-checks above.)

**Conservative guards — skip suggesting removal if any hold:**

1. **Just-added this session**: doc path is in Pass A's or Pass B's candidate set (don't add and remove in the same wrap).
2. **Drift status is `stale` or `orphan`**: user may have it in LOKO specifically because they want to fix it next session. Leave alone. (**Exception:** doesn't apply to docs flagged by Pre-check 1 (self-tagged temp) or Pre-check 2 (`established + unmentioned`) — both signals are stronger than the "might want to fix" assumption. If two wraps have passed without any session mention, that "might want to fix" signal is stale too.)
3. **Covers next-session mission**: if any of the doc's `covers:` paths fall inside the next-session scope (per starter prompt / Notes / TODO items), keep — Claude judgment.

**Deferred guard (known gap)**: "manually re-added in last 3 sessions" not implemented — bouncing-back docs get re-suggested each wrap until pinned. Revisit if it bites.

**Pass C candidates that survive the guards** become **remove suggestions**. Tag each removal with the strongest signal that fires:

- **Deterministic** — any of:
  - Covers paths untouched ≥ N commits, where N defaults to the drift threshold.
  - Self-tagged temp marker found (Pre-check 1).
  - `presence=established` AND `mentioned=no` (Pre-check 2 — session-mention staleness).
  - LOKO entry is a plan file with `status: completed` (Pre-check 3).
- **Judgment** — off-theme per Claude, no deterministic backing. Carry the doc's `presence` (new/recent/established) into the tag — the auto-mode fallback uses it.

The auto-mode fallback below treats deterministic vs judgment differently, and inside judgment, `presence` decides auto-apply vs advisory.

If Pass C produces zero remove candidates after guards, that's fine — proceed with adds-only.

---

### Consolidated proposal

Merge Pass A + Pass B (adds) and Pass C (removes). If both lists are empty, skip silently — no prompt, no output.

**Render the proposal as text first:**

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

**Apply the auto policy** — no prompt. The proposal text already printed; decide what to apply automatically:

- **Adds**: apply automatically. Pass A is deterministic; Pass B already errs toward skipping. Low downside.
- **Removes — deterministic** (untouched ≥ threshold, OR self-tagged temp marker found, OR `established + unmentioned`, OR plan with `status: completed`): apply automatically. All four are author/usage-based signals strong enough to act on without confirmation.
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

(The single summary line emitted earlier — `Updated ## Load on Kick-Off: +X, -Y. To revert: …` — is the only post-apply output. Do not emit a second per-bullet "Report" block here. One line, then move on.)

### Cold-start behavior

The gates above (top of Step 2c) handle every combination of `TAGGED_EXISTS` × `LOKO_HAS_BULLETS` × session-emptiness. Net effect on a fresh koji install: the step no-ops silently until there's enough signal to act on.

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

6. **Template hygiene when writing an entry.** Strip the template's HTML comments (`<!-- … -->`) — they are instructions to you, not entry content. Under `### Test Results`, when nothing was run (docs-only session, nothing user-reachable changed), write a single `- n/a — <reason>` line instead of leaving checkboxes or padding a "no GUI smoke — …" sentence. This convention holds for every project template, including ones scaffolded before it was written down.

7. **Placeholder gate (v0.8.0).** An entry that still carries template placeholders is not finalized. After writing a new entry (or finalizing an `[in progress]` one), check **only the entry you just wrote** — never the whole log, or one leaked `[Description]` in an old entry would block every future wrap:

   ```bash
   SESSION_LOG="$DOCS_PATH/agent-session.md"
   TEMPLATE_USED="$DOCS_PATH/SESSION_TEMPLATE.md"
   [ -f "$TEMPLATE_USED" ] || TEMPLATE_USED="$KOJI_SKILLS/templates/$TEMPLATE/SESSION_TEMPLATE.md"
   LAST_START=$(grep -n '^## Session:' "$SESSION_LOG" | tail -1 | cut -d: -f1)
   if [ -z "$LAST_START" ]; then
     echo "placeholder gate: no '## Session:' heading in $SESSION_LOG — the entry was not written; go back to sub-step 4."
   else
     ENTRY_TMP=$(mktemp)
     tail -n "+$LAST_START" "$SESSION_LOG" > "$ENTRY_TMP"
     ~/.claude/skills/koji/bin/koji-session-placeholders "$TEMPLATE_USED" "$ENTRY_TMP" > "$ENTRY_TMP.left" 2> "$ENTRY_TMP.err"
     GATE_RC=$?
     case "$GATE_RC" in
       0) echo "placeholders: none" ;;
       1) echo "Session entry still has placeholder \"$(head -1 "$ENTRY_TMP.left")\" — fill it before wrap can continue."
          cat "$ENTRY_TMP.left" ;;
       *) echo "placeholder gate unavailable (exit $GATE_RC): $(cat "$ENTRY_TMP.err")" ;;   # a helper/template problem, not a placeholder — do not treat as a block
     esac
     rm -f "$ENTRY_TMP" "$ENTRY_TMP.left" "$ENTRY_TMP.err"
   fi
   ```

   The helper prints every `[…]` token from the template that survives verbatim in the entry — checkbox marks and the `[<agent>]` tags in `$AGENTS` excluded — so it works against a project's own `SESSION_TEMPLATE.md` too. That is how a project adds an obligation that must be answered every session: a line such as `**AI-lens**: [angle | none | n/a (reason)]` in its template makes wrap refuse to finalize until the bracket is replaced. If anything is printed, **stop here**: fill the field from this session's context and re-run the check. Only a field you genuinely cannot know halts the wrap — say which one and why, and do not proceed to Step 4.

---

## Step 4 — Permission Hygiene

Resolve the *effective* permission mode with the helper — not by reading the project files yourself. Since Claude Code 2.1.257, `permissions.defaultMode: bypassPermissions` (and `auto`) set in `.claude/settings.json` or `.claude/settings.local.json` **does not take effect**; only user settings (`~/.claude/settings.json`), managed settings, or the `--permission-mode` CLI flag can set it. The old two-file check inspected exactly the files that can no longer set bypass and ignored the ones that can — and older `/koji-init` wrote the now-inert key into the local file, so a stale mirror is common.

```bash
source <(~/.claude/skills/koji/bin/koji-permission-mode)
echo "Effective mode: $EFFECTIVE_MODE (source: $MODE_SOURCE) | bypass: $EFFECTIVE_BYPASS | Claude Code: $CLAUDE_VERSION"
if [ -n "$INERT_LOCAL_MODE" ]; then echo "note: .claude/settings.local.json sets defaultMode=$INERT_LOCAL_MODE — inert since Claude Code 2.1.257 (/kick-off offers cleanup)"; fi
if [ -n "$INERT_PROJECT_MODE" ]; then echo "note: .claude/settings.json sets defaultMode=$INERT_PROJECT_MODE — inert since Claude Code 2.1.257 (/kick-off offers cleanup)"; fi
```

The helper walks managed → local → project → user in Claude Code's own precedence, skips the inert project-scope values, honors `disableBypassPermissionsMode` / `disableAutoMode`, and reads the **main checkout's** `.claude/` when you are in a worktree (`SETTINGS_ROOT` — Claude Code writes `settings.local.json` there, not in the worktree). `APPROXIMATE=true` is always set: a `--permission-mode` / `--dangerously-skip-permissions` launch flag is invisible to any settings scan, so this is the best file-based answer, not a guarantee.

**Bypass short-circuit.** If `EFFECTIVE_BYPASS` is `true`, skip the rest of Step 4 silently (the inert notes above are the only output). Bypass-mode entries are session noise (auto-allowed tool calls), not curated grants — promoting them would bloat `settings.json` with machine-specific cruft. Move to Step 5. An inert project-scope key alone does **not** short-circuit — that was the bug. `auto` mode does not short-circuit either: under auto, entries in `settings.local.json` are still the user's own "always allow" clicks, which the filter below should see.

If `SETTINGS_ROOT` differs from `PROJECT_ROOT` (you are in a linked worktree), print one line — `permission hygiene: skipped in worktree; settings live in <SETTINGS_ROOT>` — and move to Step 5: the promoted `settings.json` would live in another checkout, and this wrap could not commit it.

Otherwise, if `$SETTINGS_ROOT/.claude/settings.local.json` exists (treat missing/unreadable files as having no fields set):

1. Read `settings.local.json` (session-accumulated permissions)
2. Read `settings.json` (committed permissions)
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

   **Grey area** (potentially useful but not obviously safe — never promoted automatically, never asked about):
   - Broader `Bash` patterns that aren't standard dev commands (e.g., `Bash(curl:*)`, `Bash(docker:*)`)
   - Commands that touch external services (e.g., `Bash(gh:*)`, `Bash(ssh:*)`)
   - Permissions that are project-specific but not machine-specific (e.g., `Bash(./scripts/deploy.sh)`)
   - Batch similar perms into one group and infer from existing approved/denied patterns in `settings.json`; anything genuinely new and ambiguous stays grey.

5. **If there are auto-promoted permissions**, briefly list them (one line summary, not a full list):

   > Promoted 4 permissions to settings.json (git, npm, koji scripts). Run `cat .claude/settings.json` to review.

6. **Grey-area items that can't be inferred** are never asked about: leave them in `settings.local.json` un-promoted and name them in the one-liner — `Skipped 2 grey-area permissions: Bash(docker compose:*), Bash(gh:*)`. Auto-promote still applies; only the judgment call is withheld.

7. Merge auto-promoted + user-approved into `settings.json`, preserving existing entries. Do not duplicate.
8. If nothing new to promote, skip this step entirely — no output.

---

## Step 5 — Commit Proposal

**Important:** Steps 1-4 above only edit files. No commits happen until this step.

1. Run `git status` and `git diff --stat` to capture **all** changes (session work, wrap doc updates, and permission changes).
2. Classify every changed file as either **code** (session work) or **docs** (koji files: `$DOCS_PATH/lessons.md`, `$DOCS_PATH/AI_HANDOFF.md`, `$TODO_PATH`, `$DOCS_PATH/COMPLETED_TASKS.md`, `$DOCS_PATH/agent-session.md`, `$DOCS_PATH/SESSION_TEMPLATE.md`, `$DOCS_PATH/$ARCHIVE_DIR/**`, `$PLANS_DIR/**`, `$RESEARCH_DIR/**`, `.claude/settings.json`).
3. **Amend eligibility** — compute once, before choosing a strategy:

   ```bash
   source <(~/.claude/skills/koji/bin/koji-amendable)
   echo "Amendable: $AMENDABLE ($REASON) | HEAD: \"$HEAD_SUBJECT\" ($((HEAD_AGE_SECONDS / 60)) min ago)"
   ```

   `AMENDABLE=true` means HEAD is your own, single-parent commit, made after this session's `/kick-off` sentinel, and not known to be pushed (as of the last fetch). Folding the wrap docs into the work commit they belong to is the same-session case — "I committed the work five minutes ago; the session log goes with it." It is an *option*, never a default. When `AMENDABLE` is `false`, never offer it; `REASON` says why (`pushed`, `other-author`, `no-sentinel`, `merge-commit`, …). The exact command, when amending:

   ```bash
   git commit --amend --no-edit --trailer "Wrap-Folded-In: <one line — e.g. session log, handoff, TODO>"
   ```

   `--no-edit --trailer` keeps the subject, body and existing trailers (`Co-Authored-By`, `Claude-Session`) intact — appending a paragraph by hand detaches them. If `git commit --trailer` is unsupported (git < 2.32), use `git commit --amend --no-edit` and mention the fold in the session log instead; never rewrite the message by hand.

4. **Commit gate** — runs once, after staging and before any commit, in every strategy below. Resolve the command:

   ```bash
   case "${WRAP_COMMIT_GATE:-auto}" in   # empty (fresh shell, koji-detect not re-sourced) must mean auto, never "no gate"
     none) GATE="" ;;
     auto) if [ -f "$PROJECT_ROOT/package.json" ] && grep -q '"lint:check"' "$PROJECT_ROOT/package.json"; then GATE="npm run lint:check"; else GATE=""; fi ;;
     *)    GATE="$WRAP_COMMIT_GATE" ;;
   esac
   echo "Commit gate: ${GATE:-none}"
   ```

   `auto` picks only `lint:check` (check-only by convention — a bare `lint` script is often `--fix` and mutates the tree). Anything mutating or slow must be configured explicitly (`.koji.yaml` → `wrap: { commit_gate: "<command>" }`). Test suites never run by default. If `GATE` is empty, skip to the strategy.

   Otherwise run it against the working tree (the staged files are what gets linted in practice — a check-only gate reads the tree):

   ```bash
   GATE_LOG=$(mktemp)
   TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
   if [ -z "$TO" ]; then echo "note: no timeout binary — gate runs uncapped"; fi
   TREE_BEFORE=$(git -C "$PROJECT_ROOT" diff --binary | cksum)
   if [ -n "$TO" ]; then
     (cd "$PROJECT_ROOT" && "$TO" 300 bash -c "$GATE") > "$GATE_LOG" 2>&1
   else
     (cd "$PROJECT_ROOT" && bash -c "$GATE") > "$GATE_LOG" 2>&1
   fi
   GATE_EXIT=$?
   TREE_AFTER=$(git -C "$PROJECT_ROOT" diff --binary | cksum)
   if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then GATE_TOUCHED=no; else GATE_TOUCHED=yes; fi
   echo "Gate exit: $GATE_EXIT | gate modified tracked files: $GATE_TOUCHED"
   ```

   (`git diff --binary | cksum` fingerprints unstaged changes to *tracked* files only, so a linter writing an untracked `.eslintcache` is not mistaken for a formatter.) Decide:

   - `GATE_EXIT=0` and `GATE_TOUCHED=no` → **pass**. Print nothing more.
   - `GATE_EXIT=127` or the log tail shows `command not found` (any gate), or — **only when the gate is a Node command** (`auto`, or a configured command starting with `npm` / `npx` / `node` / `pnpm` / `yarn`) — the log tail shows `Cannot find module` / `ENOENT`, or `package.json` exists but `$PROJECT_ROOT/node_modules` does not → **gate unavailable — skipped**. One warning line; continue as if there were no gate. An unavailable gate never aborts a wrap (a fresh clone must not lose its session log to a missing `node_modules`). A failing `cargo test` or `make check` is never waved through on a Node heuristic.
   - `GATE_TOUCHED=yes` (the gate formatted files) → restage the same set and re-run the gate block **once**: `if [ -n "$(git -C "$PROJECT_ROOT" diff --cached --name-only)" ]; then git -C "$PROJECT_ROOT" diff --cached --name-only -z | xargs -0 git -C "$PROJECT_ROOT" add --; fi`. A second `yes`, or a non-zero exit, → **failed**.
   - Any other non-zero exit → **failed**. Show `tail -20 "$GATE_LOG"`, then **abort**: `Commit gate failed (exit $GATE_EXIT) — nothing committed; changes remain staged.` Skip to sub-step 7 and **skip sub-step 8 as well** — nothing was committed, so the session-start sentinel and per-session state stay in place for the wrap that eventually lands the commit. Autonomy never means committing a red tree.

   In the **Split** strategy the gate runs once, before the first commit — a check-only gate reads the whole tree, so per-commit runs add nothing.

5. **Commit rule.** No approval wait: apply the strategy (sub-step 6), print the message you used, commit. A failed gate still aborts (sub-step 4). **If `git commit` (or the amend) itself exits non-zero** — a hook, signing, or identity failure; Bash here is not `errexit`, so check `$?` — print its output, say `Commit failed (exit N) — nothing committed; changes remain staged.`, and treat it exactly like a failed gate: sub-step 7 reports it, sub-step 8 is skipped.

6. Determine the commit strategy:

   **If there are only doc changes (work was already committed):**
   - Stage all doc files, run the gate (sub-step 4).
   - **If `AMENDABLE=true`:** the docs belong with the commit you just made. When `$COMMIT_STRATEGY` is `amend-if-same-session` **and** `HEAD_AGE_SECONDS` < 43200 (12 h), amend and say: `Folded wrap docs into "<HEAD_SUBJECT>" (saved preference amend-if-same-session)`. Otherwise commit separately as `docs(koji): update session logs` and add one line: `HEAD was your unpushed same-session commit — to fold docs-only wraps in automatically: koji-config set commit_strategy amend-if-same-session`.
   - **If `AMENDABLE=false`:** commit `docs(koji): update session logs` (commit rule).

   **If there are only code changes (no docs were modified — unlikely during wrap):**
   - Stage all files, run the gate, commit a single conventional commit for the work (commit rule).

   **If there are both code changes AND doc changes (mixed worktree):**

   First, check `$COMMIT_STRATEGY` for a saved preference:

   **If `$COMMIT_STRATEGY` is `together` or `amend-if-same-session`:** stage everything, run the gate, one commit. Tell the user: `Using saved preference: single commit. (Change with koji-config set commit_strategy split)`. `amend-if-same-session` applies to docs-only wraps only — a mixed tree is **never** amended automatically, because that would fold unrelated new code into the previous commit.

   **If `$COMMIT_STRATEGY` is `split`:** Use the saved preference — split into two commits (code first, docs second). Tell the user: `Using saved preference: split commits. (Change with koji-config set commit_strategy together)`

   **If `$COMMIT_STRATEGY` is empty (no preference yet), or holds anything other than `together` / `split` / `amend-if-same-session`** (say so in one line and treat it as empty): this is the one question `/wrap` asks. It is a policy choice that persists — globally, in `~/.config/koji/config.yaml` — so it is asked once per machine, not once per wrap. Ask using `AskUserQuestion`:

   > This wrap has both code and doc changes. How should /wrap commit from now on?

   Options:
   - A) One commit — everything together (recommended for most workflows) → `koji-config set commit_strategy together`
   - B) Split — code commit first, then docs commit → `koji-config set commit_strategy split`
   - C) Amend the last commit this time only — fold everything into `"<HEAD_SUBJECT>"` (<N> min ago) — **only when `AMENDABLE=true`**; persists nothing, so the next wrap asks again (to make docs-only folds automatic: `koji-config set commit_strategy amend-if-same-session`)

   If A: save, then stage everything, run the gate, one commit.
   If B: save, then split into two commits (code first, docs second).
   If C: stage everything, run the gate, amend with the exact command from sub-step 3.

   **If `AskUserQuestion` is not callable** (headless runtime): use `together` for this wrap only and do **not** save it — print `commit strategy: together (no prompt available; not saved)` — so a later interactive wrap still asks.

   **Override:** If the saved preference is `together` but the code and docs changes are clearly unrelated (e.g., code is a bug fix but docs are from a different task), keep the preference and say so in one line. Never a prompt, never a change to the saved preference.

   **Together**: Stage everything, run the gate, commit one conventional commit (commit rule). **Done — one commit total.**
   **Split**: Execute exactly two commits in sequence:
     1. `git reset -q` first — the index may already hold everything (`/duet-impl` stages with `git add -A`), and a split that starts from a full index commits the docs into the "code" commit and leaves the second commit empty. Then stage **only code files** (`git add` each by name). Run the gate. Print the work commit message, commit.
     2. Stage **only doc files** (`git add` each by name). Commit with `docs(koji): update session logs`.
     **Done — two commits total.**

7. **After committing**, run `git status`. If the worktree is clean, move on. If there are unexpected leftover changes, **report them to the user** but do NOT create additional commits. Let the user decide in the next step or manually. If the gate aborted the commit, say so here again in one line.

8. **Delete the session-start sentinel and per-session state** so the next `/kick-off` creates a fresh boundary — **only when this wrap's commit landed** (or there was nothing to commit). If the gate aborted or the commit command itself failed (sub-steps 4–5), skip this step entirely: the boundary stays for the wrap that eventually lands it.
   ```bash
   rm -f "$SESSION_START_FILE"
   [ -n "$SESSION_DIR" ] && rm -f "$SESSION_DIR/duet-rules.json"
   rmdir "$SESSION_DIR" 2>/dev/null || true
   ```
   Idempotent. The `[ -n "$SESSION_DIR" ]` guard prevents `rm -f /duet-rules.json` if the variable is unset. `rmdir` is a no-op if other state lives in the dir — sibling skills writing to `$SESSION_DIR` should add their own cleanup line. Runs unconditionally at end of Step 5. Without a fresh `/kick-off`, the next `/wrap` degrades to working-tree-only diff (Pass A weakens).

---

## Step 6 — Starter Prompt & Session Name

**Session name** — derive a short kebab-case name from **the commit message you used in Step 5** (when Step 5 amended, from the amended commit's subject — `git log -1 --format=%s`): take the conventional-commit subject, drop the type+scope prefix (`feat(v0.5.8): `, `fix(koji): `, etc.), then kebab-case the remainder. The commit message has already distilled this session's work; re-deriving from the session log is duplicate work and usually produces a vaguer name.

Examples:
- `feat(v0.5.8): /duet-impl — N+1 review-pass formula` → `duet-impl-n-plus-1-review-pass-formula`
- `fix(v0.6.1): koji-doc-status BSD-awk newline crash` → `koji-doc-status-bsd-awk-newline-crash`
- `docs(koji): trim AI_HANDOFF` → `trim-ai-handoff`

**Fallback** — when Step 5 was skipped or aborted (no commit message exists), derive from the session log entry just written (the legacy path). Same kebab-case shape.

Tell the user:

> **Session name:** `<suggested-name>`
> Rename this session: `/rename <suggested-name>`

The `/rename <name>` slash command renames the *active* Claude Code session — no quit/restart needed (unlike `claude -n`, which is a launch flag that starts a NEW session under that name). As of Claude Code v2.x there is no programmatic rename available to skills (GH issue #50040 closed as duplicate, no hook or tool exposed), so this step prints the suggested name and the user types `/rename` to apply it. If/when upstream exposes a rename tool, this step can auto-apply.

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
- [ ] Active plans' `next-step` re-checked for candidates touched this session
- [ ] Session entry appended to `agent-session.md`, with no surviving template placeholders
- [ ] Archive rotation performed (if threshold reached)
- [ ] Permissions reviewed against the *effective* mode (helper, not the project files)
- [ ] Commit gate ran before any commit (or was `none` / unavailable — said so)
- [ ] Amend used only when `AMENDABLE=true`, never on a pushed or foreign commit
- [ ] Commit made (message printed; no approval wait)
- [ ] Starter prompt generated
