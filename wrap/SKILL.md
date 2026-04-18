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

Review the session for any cases where the user corrected you, or where you discovered a non-obvious pattern or gotcha.

**Only log lessons that are worth keeping.** Apply this filter:

✅ **Worth adding:**
- User corrections that would repeat across sessions (e.g., "don't use X library, it breaks Y")
- Non-obvious project-specific gotchas that cost real time to rediscover (e.g., "the API returns 200 even on auth failure")
- Patterns not documented anywhere else (CLAUDE.md, codebase, framework docs)

❌ **Not worth adding:**
- Generic best practices any senior dev already knows ("write tests", "handle errors")
- One-off mistakes unlikely to recur (typos, wrong flag on a single command)
- Things already documented in CLAUDE.md or obvious from the codebase
- Restatements of framework/library documentation
- **Tool or agent knowledge** — how Claude Code hooks work, how koji skills behave, how git flags work. These belong in tool docs, not project lessons.
- **Decisions already encoded in config** — if you just wrote it into a skill file, `.koji.yaml`, `settings.json`, or `CLAUDE.md`, it's already persisted. Don't duplicate it as a lesson.
- **Workflow design choices** — "we decided X belongs in kick-off not wrap" is a design decision, not a lesson. It's in the skill file already.
- **Work done outside this project's workspace** — if you edited koji, gstack, or other external tools while working in this repo, those are not lessons for this project. They belong in those tools' own repos.

**The test:** Would a developer working on *this project's codebase* hit this problem again if they didn't read this lesson? If no — don't add it. Lessons are for project-specific landmines, not general knowledge.

**When in doubt, don't add it.** A short, high-signal lessons file is far more valuable than a long one full of noise. Most sessions should add zero lessons.

If any corrections or discoveries pass the filter:
1. Read `$DOCS_PATH/lessons.md`
2. Append new entries **at the top** (below the header comment), one per line:
   ```
   YYYY-MM-DD — [Claude] — what went wrong → rule to prevent it
   ```
3. Be specific and tactical — not generic advice. Include the concrete consequence.

If nothing passes the filter, skip this step.

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

## Step 2c — Suggest Load on Kick-Off additions (tag-driven, optional)

This step runs ONLY if both conditions hold:

1. The repo has at least one doc with a `<!-- koji:covers <paths> -->` header (check via `git grep -l '<!-- koji:covers' -- '*.md'` — if empty, skip this step silently)
2. The session's git diff overlaps with any tagged doc's covered paths

**Compute the session's touched paths:**

```bash
TOUCHED=$(git diff --name-only HEAD 2>/dev/null; git log --name-only --format= HEAD@{1}..HEAD 2>/dev/null | sort -u)
```

Fallback to `git diff --name-only` against any available base if `HEAD@{1}` isn't usable (e.g., fresh repo, detached HEAD). If nothing touched, skip.

**For each tagged doc:**

1. Parse its first `<!-- koji:covers <space-separated-paths> -->` header
2. Check if any touched path matches any covered path prefix
3. If yes, check whether the doc is ALREADY in the `## Load on Kick-Off` section of `agent-session.md` (by path match). If already listed, skip. If not listed, the doc is a suggestion candidate.

**If there are suggestion candidates, ask once** (not per-doc):

Use `AskUserQuestion`:

> Tagged docs covering touched paths in this session aren't in Load on Kick-Off:
>   - docs/AUTH_FLOW.md (covers backend/auth/ — 3 files changed)
>   - docs/AD_MONETIZATION.md (covers clients/lib/ads/ — 1 file changed)
>
> Add them to the Load on Kick-Off section in agent-session.md?

Options:
- **A) Add all** — append each candidate as a bullet under `## Load on Kick-Off`
- **B) Select some** — pick which to add
- **C) Skip** — don't add any

**If A or B, update `agent-session.md`:**

1. Check if a `## Load on Kick-Off` H2 section exists (should be above the first `## Session:` entry)
2. If not, create it immediately above the first `## Session:` heading (or at the bottom of the file if no session entries exist):
   ```markdown

   ## Load on Kick-Off

   ```
3. Append the chosen docs as bullets in path-form:
   ```markdown
   - docs/AUTH_FLOW.md
   ```
4. Report the change: `Added <N> doc(s) to Load on Kick-Off.`

If there are no candidates (no overlaps, or all overlapping docs already listed), skip this step silently — no prompt, no output.

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
