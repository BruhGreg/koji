---
description: "Multi-round Claude↔codex planning dialogue that reaches consensus on a plan, then locks it to $DOCS_PATH/plans/. Use ONLY when the user explicitly says 'duet plan', 'duet-plan', 'let's duet plan X', or similar — the 'duet' keyword is required. Do not invoke on casual 'let's plan' or 'help me plan' phrases (too generic). Agents debate autonomously; user is escalated only when consensus stalls at the round limit."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Agent
  - AskUserQuestion
---

# /duet-plan

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

Multi-round Claude↔codex planning dialogue. Each round, Claude drafts/updates a plan and codex critiques. The skill detects consensus via `VERDICT:` markers; when both agents emit `AGREE` in the same round, the plan is locked to `$DOCS_PATH/plans/<slug>.md`. Process artifacts (round drafts and critiques) stay in `/tmp` and are cleaned up at end of run.

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji duet-plan ==="
echo "Project: $PROJECT_NAME"
echo "Docs: $DOCS_PATH"
```

## Arguments / topic extraction

The topic is whatever the user provided. Examples of how to extract it:

| User said | Topic |
|---|---|
| "duet plan how we add OAuth" | "how we add OAuth" |
| "let's duet plan refactoring the auth module" | "refactoring the auth module" |
| "duet-plan: migrate from postgres 14 to 15" | "migrate from postgres 14 to 15" |
| "duet plan" (no topic) | ask user once via AskUserQuestion |

Flags:
- `--rounds N` — round limit (default 5)
- `--xhigh` — bump codex effort to xhigh (default high)
- `--slug <name>` — override auto-derived plan slug
- `--keep` — keep `/tmp/duet-plan-<sha>/` for debugging (default: cleaned)

## Step 1 — Setup

```bash
RUN_DIR=$(mktemp -d -t duet-plan-XXXXXX)
TOPIC="<topic from invocation>"
echo "$TOPIC" > "$RUN_DIR/topic.txt"

EFFORT="high"; [ "$XHIGH" = "1" ] && EFFORT="xhigh"
TIMEOUT=$([ "$XHIGH" = "1" ] && echo 1800 || echo 900)
ROUND_LIMIT="${ROUNDS:-5}"
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
PROMPT_TEMPLATES="$KOJI_SKILLS/duet-plan/references/prompt-templates.md"

# Brief project context for the prompts (1-line)
PROJECT_CONTEXT="(repo: $(basename "$PROJECT_ROOT"); branch: $(git branch --show-current 2>/dev/null || echo unknown))"

echo "Topic: $TOPIC"
echo "Run dir: $RUN_DIR"
echo "Round limit: $ROUND_LIMIT, effort: $EFFORT"
```

## Step 2 — Dialogue loop

Implement as a counter starting at 1. Repeat until consensus or round limit.

### Round 1 (initial)

#### 2a. Claude drafts initial plan (Agent tool, foreground)

Call the `Agent` tool with `subagent_type: general-purpose`. Prompt contains:
- The "CLAUDE — initial round" template from [references/prompt-templates.md](references/prompt-templates.md)
- `{topic}` filled in
- `{project_root}` and `{project_context}` filled in

Take the Agent's response, write it to `$RUN_DIR/round-1-claude.md`. The last line should be `VERDICT: AGREE` (or PARTIAL/DISAGREE).

#### 2b. Codex critiques (Bash, background)

```bash
ROUND=1
CLAUDE_FILE="$RUN_DIR/round-${ROUND}-claude.md"
CODEX_FILE="$RUN_DIR/round-${ROUND}-codex.md"

CODEX_PROMPT="$(awk '/^## CODEX — every round/,/^## CLAUDE — subsequent/' "$PROMPT_TEMPLATES" | sed -n '/^```/,/^```/p' | sed '1d;$d')

(template substitution: replace {topic}, {project_root}, {claude_plan}, {prior_critique_or_empty})"

# In practice the agent constructs this inline — example shape:
CODEX_PROMPT="You are critiquing a plan drafted by another agent (Claude)...

TOPIC: $TOPIC
REPOSITORY: $PROJECT_ROOT

Claude's current plan:

---
$(cat "$CLAUDE_FILE")
---

(no prior critique on round 1)

End with VERDICT line."

{
  if [ -n "$TO" ]; then
    "$TO" "$TIMEOUT" codex exec "$CODEX_PROMPT" \
      -C "$PROJECT_ROOT" -s read-only \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      < /dev/null > "$CODEX_FILE.raw" 2> "$CODEX_FILE.err"
  else
    codex exec "$CODEX_PROMPT" \
      -C "$PROJECT_ROOT" -s read-only \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      < /dev/null > "$CODEX_FILE.raw" 2> "$CODEX_FILE.err"
  fi
  echo $? > "$CODEX_FILE.exit"
} &
CODEX_PID=$!
wait $CODEX_PID

CODEX_EXIT=$(cat "$CODEX_FILE.exit")
if [ "$CODEX_EXIT" = "124" ]; then
  echo "WARN: codex timed out on round $ROUND. Treating as DISAGREE."
  echo "VERDICT: DISAGREE: codex timeout — no critique available" > "$CODEX_FILE"
elif [ "$CODEX_EXIT" != "0" ]; then
  echo "WARN: codex exit $CODEX_EXIT on round $ROUND. See $CODEX_FILE.err"
  echo "VERDICT: DISAGREE: codex failed to respond" > "$CODEX_FILE"
else
  cp "$CODEX_FILE.raw" "$CODEX_FILE"
fi
```

#### 2c. Check consensus

```bash
extract_verdict() {
  # Echoes one of: AGREE / PARTIAL / DISAGREE / UNKNOWN
  grep -iE '^[[:space:]]*VERDICT[[:space:]]*:' "$1" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*//I' \
    | awk '{print toupper($1)}' \
    | sed 's/:.*$//'
}

CLAUDE_V=$(extract_verdict "$CLAUDE_FILE")
CODEX_V=$(extract_verdict "$CODEX_FILE")
echo "Round $ROUND verdicts: claude=$CLAUDE_V codex=$CODEX_V"

if [ "$CLAUDE_V" = "AGREE" ] && [ "$CODEX_V" = "AGREE" ]; then
  echo "CONSENSUS REACHED at round $ROUND"
  CONSENSUS=1
else
  CONSENSUS=0
fi
```

### Round N (N > 1, when not yet consensus and ROUND ≤ ROUND_LIMIT)

#### 2d. Claude responds (Agent tool, foreground)

Call Agent with the "CLAUDE — subsequent rounds" template, filling in:
- `{topic}`
- `{claude_previous}` = contents of `$RUN_DIR/round-$((ROUND-1))-claude.md`
- `{codex_critique}` = contents of `$RUN_DIR/round-$((ROUND-1))-codex.md`

Write response to `$RUN_DIR/round-$ROUND-claude.md`.

#### 2e. Codex re-critiques

Same bash as 2b, but pass `{prior_critique_or_empty}` = contents of `$RUN_DIR/round-$((ROUND-1))-codex.md` so codex remembers what it said and can check if Claude addressed it.

#### 2f. Consensus check (same as 2c)

### Deadlock at round limit

When ROUND exceeds ROUND_LIMIT without consensus, surface to the user via `AskUserQuestion`. This is the autonomy-doc "deadlocked planning consensus" case.

```
Question: "Planning consensus not reached after $ROUND_LIMIT rounds. How to proceed?"
Body: include the last 2 rounds' verdicts and a 1-paragraph summary of the disagreement
Options:
  1. "Lock Claude's last plan as-is (override codex)"
  2. "Lock codex's recommended version (extract from last critique)"
  3. "Add 3 more rounds and try again"
  4. "Abort and discard"
```

## Step 3 — Lock the plan

When CONSENSUS=1 (or user picked option 1 or 2 above):

```bash
PLANS_DIR="$DOCS_PATH/plans"
~/.claude/skills/koji/bin/koji-duet-plan-lock \
  --plan "$RUN_DIR/round-${ROUND}-claude.md" \
  --topic "$TOPIC" \
  --rounds "$ROUND" \
  --claude-verdict "$CLAUDE_V" \
  --codex-verdict "$CODEX_V" \
  --plans-dir "$PLANS_DIR" \
  ${SLUG:+--slug "$SLUG"}
```

The helper prints the locked file path on stdout. Capture and report to user.

## Step 4 — Cleanup

```bash
if [ "${KEEP:-0}" = "1" ]; then
  echo "Process artifacts kept at: $RUN_DIR"
else
  rm -rf "$RUN_DIR"
  echo "Process artifacts cleaned up."
fi
```

## Step 5 — Report

Print a brief summary:

```
duet-plan: locked
Topic:   <topic>
Path:    <PLANS_DIR>/<slug>.md
Rounds:  <N> (limit was <LIMIT>)
Final verdicts: claude=<V>, codex=<V>
```

If the user wants to immediately continue with `/duet-impl`, mention the locked path so they can pass it in.

## Failure modes

| Symptom | Likely cause | Mitigation |
|---|---|---|
| Codex hangs (no output, no timeout) | `--enable web_search_cached` re-introduced, or stdin not closed | Skill explicitly drops both — verify bash blocks not modified. Kill PID and treat as DISAGREE for that round. |
| Codex exits 124 (timeout) | Round prompt got too long (cumulative context) | Skill writes prior rounds as files, not stuffs them all into one prompt. If still hitting limit: lower `--rounds` or use `high` instead of `xhigh`. |
| Claude (Agent) returns prose without VERDICT line | Prompt drift — agent forgot the marker | Re-invoke the Agent with an explicit reminder: "Your last response was missing the VERDICT line — re-output the same plan with the marker appended." Limit to 1 retry. |
| Plan locks to wrong slug | Auto-slug from topic | Use `--slug <name>` to override. Existing files get auto-suffixed (`-2`, `-3`). |
| `$DOCS_PATH` not set | `/koji-init` never run | Same failure mode as `/wrap` — surface and direct user to `/koji-init`. |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Round prompt templates: [references/prompt-templates.md](references/prompt-templates.md)
- Lock helper: [koji/bin/koji-duet-plan-lock](../bin/koji-duet-plan-lock)
- Downstream consumer: `/duet-impl` reads the locked plan and walks the gates
