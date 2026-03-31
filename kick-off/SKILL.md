---
description: "Start a new session with context. Reads the last session entry and AI handoff to bootstrap the agent, or takes a custom focus as argument."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# Kick Off

Run the preamble to detect project configuration:

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji kick-off ==="
echo "Project: $PROJECT_NAME"
echo "Has session log: $HAS_SESSION_LOG"
echo "Has handoff: $HAS_HANDOFF"
echo "Has lessons: $HAS_LESSONS"
```

If `HAS_SESSION_LOG` is `false` or `HAS_HANDOFF` is `false`, tell the user to run `/koji-init` first and stop.

---

## Workflow

### 1. Check for user-provided focus

If the user typed text after `/kick-off` (e.g., `/kick-off build the news landing page`), use that as the **session focus** — skip reading the last session's starter prompt and use the user's intent instead. Still read handoff and lessons for context.

If no args provided, proceed to step 2.

### 2. Read context (always)

Read these files and internalize the content — do NOT dump them back to the user:

1. `$DOCS_PATH/AI_HANDOFF.md` — current project state, roadmap, decisions, blockers
2. `$DOCS_PATH/lessons.md` — recent corrections and gotchas (focus on the top 10 entries)
3. `$DOCS_PATH/agent-session.md` — read the **last** session entry for continuity (what was done, notes for next session)

### 3. Brief the user

Output a concise briefing (not a wall of text):

> **Session start — $PROJECT_NAME**
>
> Last session: [1-line summary of what was done]
> Handoff says: [1-line summary of the most important next task]
> Watching out for: [1-line gotcha from lessons, if relevant — otherwise skip]
>
> **Focus:** [user's arg if provided, OR the "Notes for Next Session" from the last entry]
>
> Ready to go. What's first?

Keep it tight — 4-5 lines max. The user already knows their project; they need a quick refresh, not a lecture.
