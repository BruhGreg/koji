---
description: "Mid-session progress save. Updates the current session entry in agent-session.md with progress so far, without committing or archiving."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
---

# Take Note

Run the preamble to detect project configuration:

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji take-note ==="
echo "Project: $PROJECT_NAME"
echo "Session log: $DOCS_PATH/agent-session.md"
echo "Has session log: $HAS_SESSION_LOG"
```

If `HAS_SESSION_LOG` is `false`, tell the user to run `/koji-init` first and stop.

---

## Workflow

1. Read `$DOCS_PATH/agent-session.md`
2. Find the **most recent** (last) session entry
3. Update it **in-place**:
   - Update Summary — append `[in progress]` if the session is ongoing
   - Update Key Achievements with work completed so far
   - Update Notes for Next Session with current state and remaining work
4. If there is no session entry yet, create one using the session template (check `$DOCS_PATH/SESSION_TEMPLATE.md` first, then `$KOJI_SKILLS/templates/$TEMPLATE/SESSION_TEMPLATE.md`)
5. Also update `$DOCS_PATH/AI_HANDOFF.md` if roadmap items changed state

**Important:**
- Do NOT create a new session entry (unless none exists)
- Do NOT commit
- Do NOT perform archive rotation
- This is a lightweight save — fast and non-disruptive
