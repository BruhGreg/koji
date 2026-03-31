---
description: "End-of-session wrap. Updates lessons, AI handoff, session log, archives old sessions, proposes commit, and generates starter prompt."
user-invocable: true
disable-model-invocation: true
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

If `HAS_DOCS` is `false`, tell the user to run `/init-koji` first and stop.

Execute the following steps **strictly in order**. Do not skip steps. Do not batch steps.

---

## Step 1 — Lessons

Review the session for any cases where the user corrected you, or where you discovered a non-obvious pattern or gotcha.

If any corrections or discoveries occurred:
1. Read `$DOCS_PATH/lessons.md`
2. Append new entries **at the top** (below the header comment), one per line:
   ```
   YYYY-MM-DD — [Claude] — what went wrong → rule to prevent it
   ```
3. Be specific and tactical — not generic advice. Include the concrete consequence.

If nothing to log, skip this step.

---

## Step 2 — AI Handoff

If any task changed state (completed, blocked, scoped differently, new architectural decisions):

1. Read `$DOCS_PATH/AI_HANDOFF.md`
2. Update the relevant sections:
   - Mark completed tasks
   - Update "Next Agent's Tasks" or "Immediate Next Steps"
   - Add key architectural decisions if applicable
3. Do NOT rewrite unchanged sections. Only update what changed.

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

4. Read the session template:
   - First check `$DOCS_PATH/SESSION_TEMPLATE.md` (project-local override)
   - If not found, use `$KOJI_SKILLS/templates/$TEMPLATE/SESSION_TEMPLATE.md`
5. Append a new session entry at the **bottom** of `agent-session.md`, filling in all fields.
6. Use `[Claude]` as the agent tag (or the appropriate tag from `$AGENTS`).

---

## Step 4 — Commit Proposal

1. Run `git status` and `git diff --stat` to capture all changes.
2. Compose a conventional commit message:
   ```
   <type>(<scope>): <short description>

   [optional body]
   ```
   Common types: `feat`, `fix`, `refactor`, `test`, `chore`, `docs`
3. Present the commit message and ask: **"Commit with this message?"**
4. Do NOT auto-commit. Wait for explicit approval.

---

## Step 5 — Starter Prompt

Generate a **3-5 sentence** starter prompt for the next session:
- Current project state (1 sentence)
- What was accomplished this session (1 sentence)
- The single most important thing to do next (1-2 sentences)
- Any blockers or things to watch out for (if applicable)

Output this clearly labeled as **"Starter Prompt for Next Session:"**

---

## Checklist

Before finishing, verify:
- [ ] `lessons.md` updated (if applicable)
- [ ] `AI_HANDOFF.md` updated (if task state changed)
- [ ] Session entry appended to `agent-session.md`
- [ ] Archive rotation performed (if threshold reached)
- [ ] Commit proposed (awaiting approval)
- [ ] Starter prompt generated
