---
description: "Final-gate adversarial review. Runs Claude + codex reviewers in parallel, synthesizes findings, cross-reviews on disagreement, prompts on high-confidence auto-apply."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Agent
  - AskUserQuestion
---

# /duet-review

> Follows the [agent-autonomy principle](references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

Two-reviewer adversarial code review. **Reviewer A** is Claude (Agent subagent, fresh context); **Reviewer B** is codex (codex exec, `high` effort by default, `xhigh` on `--xhigh`). Both run in parallel, results are synthesized into a verdict, disagreements trigger a cross-review pass, and high-consensus mechanical fixes prompt the user with four choices (apply / hold / apply+remember-for-repo / apply+remember-for-session).

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji duet-review ==="
echo "Project: $PROJECT_NAME"
echo "Session: $SESSION_DIR"
```

## Arguments

- `--base <ref>` — base ref for diff (default: auto-detect origin/HEAD, then main, then master)
- `--staged` — review staged diff only (ignore base)
- `--xhigh` — bump codex reasoning effort from `high` to `xhigh` (2.5× tokens, 30-min timeout)
- `--no-auto-apply` — skip the 4-choice prompt; emit verdict only

---

## Step 1 — Scope the diff

Parse arguments. Auto-detect base if not supplied. Generate a diff to a tempfile:

```bash
RUN_DIR=$(mktemp -d -t duet-XXXXXX)
DIFF_FILE="$RUN_DIR/diff.patch"

# Parse args (BASE, STAGED, XHIGH, NO_AUTO are bash vars)
# ... arg parsing logic ...

if [ -z "$BASE" ] && [ "$STAGED" != "1" ]; then
  BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')
  [ -z "$BASE" ] && BASE=$(git for-each-ref --format='%(refname:short)' refs/heads/main refs/heads/master 2>/dev/null | head -1)
  [ -z "$BASE" ] && BASE="main"
fi

if [ "$STAGED" = "1" ]; then
  git diff --cached > "$DIFF_FILE"
  echo "Scope: staged diff"
else
  HEAD_SHA=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "ERROR: no commits to review"; exit 1; }
  git diff "$BASE...HEAD" > "$DIFF_FILE" 2>/dev/null
  echo "Scope: $BASE..HEAD ($HEAD_SHA)"
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE" | tr -d ' ')
echo "Diff: $DIFF_LINES lines → $DIFF_FILE"

if [ "$DIFF_LINES" = "0" ]; then
  echo "No diff to review. Exiting."
  exit 0
fi
```

If `DIFF_LINES > 5000`, confirm with the user via `AskUserQuestion` before proceeding (two reviewer passes get expensive).

---

## Step 2 — Launch reviewers in parallel

### 2a. Start codex (Reviewer B) in background

```bash
EFFORT="high"; [ "$XHIGH" = "1" ] && EFFORT="xhigh"
TIMEOUT=$([ "$XHIGH" = "1" ] && echo 1800 || echo 900)
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
PROMPT_FILE="$KOJI_SKILLS/duet-review/references/reviewer-prompt.md"

# Compose prompt inline (the prompt + diff together — codex reads it as one positional arg)
CODEX_PROMPT="$(cat "$PROMPT_FILE")

---

Now review the diff below. Output STRICT JSON only — no markdown fences, no preamble, no commentary. If no findings, output [].

DIFF:
$(cat "$DIFF_FILE")"

{
  if [ -n "$TO" ]; then
    "$TO" "$TIMEOUT" codex exec "$CODEX_PROMPT" \
      -C "$PROJECT_ROOT" -s read-only \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      < /dev/null > "$RUN_DIR/codex.raw" 2> "$RUN_DIR/codex.err"
  else
    codex exec "$CODEX_PROMPT" \
      -C "$PROJECT_ROOT" -s read-only \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      < /dev/null > "$RUN_DIR/codex.raw" 2> "$RUN_DIR/codex.err"
  fi
  echo $? > "$RUN_DIR/codex.exit"
} &
CODEX_PID=$!
echo "Codex started: PID=$CODEX_PID effort=$EFFORT timeout=${TIMEOUT}s"
```

**Codex hardening (already encoded above):**
- No `--enable web_search_cached` (confirmed silent-hang trigger)
- `< /dev/null` to prevent stdin hangs
- 30-min timeout on xhigh, 15-min on high
- Prompt passed as positional argument (not via `PROMPT=$(cat …)` subshell)
- `--json` is intentionally **omitted** here — the prompt itself requests JSON; `--json` mode is JSONL streaming which complicates output parsing

### 2b. Run Claude reviewer (Reviewer A) via Agent tool

Call the `Agent` tool, foreground:

- `subagent_type`: `general-purpose`
- `description`: `Duet review: Claude pass`
- `prompt`: the full reviewer-prompt.md text PLUS the diff, with the closing instruction:
  > *"Output ONLY a JSON array. No markdown fences, no preamble, no closing remarks. If no findings, output `[]`."*

The Agent returns its response inline. **The main agent (you) must:**

1. Extract the JSON array from the response (strip any preamble/postamble).
2. Write it to `$RUN_DIR/claude.json` using the Write tool.

If the response contains no parseable array, write `[]` to `$RUN_DIR/claude.json` and log a warning to the summary.

### 2c. Wait for codex, extract its JSON

```bash
wait $CODEX_PID
CODEX_EXIT=$(cat "$RUN_DIR/codex.exit")
echo "Codex finished: exit=$CODEX_EXIT"

if [ "$CODEX_EXIT" = "124" ]; then
  echo "WARN: codex timed out at ${TIMEOUT}s. Treating as empty findings."
  echo "[]" > "$RUN_DIR/codex.json"
elif [ "$CODEX_EXIT" != "0" ]; then
  echo "WARN: codex exit $CODEX_EXIT. See $RUN_DIR/codex.err"
  echo "[]" > "$RUN_DIR/codex.json"
else
  # Codex output is plain text; extract first JSON array
  python3 -c "
import re, json, sys
raw = open('$RUN_DIR/codex.raw').read()
m = re.search(r'\[.*\]', raw, re.DOTALL)
if m:
    try:
        json.loads(m.group(0))
        sys.stdout.write(m.group(0))
        sys.exit(0)
    except Exception:
        pass
sys.stdout.write('[]')
" > "$RUN_DIR/codex.json"
fi

echo "claude.json: $(wc -c < "$RUN_DIR/claude.json") bytes"
echo "codex.json:  $(wc -c < "$RUN_DIR/codex.json") bytes"
```

---

## Step 3 — Synthesize

```bash
~/.claude/skills/koji/bin/koji-duet-synthesize \
  --claude "$RUN_DIR/claude.json" \
  --codex  "$RUN_DIR/codex.json" \
  --base   "$BASE" \
  --head   "$HEAD_SHA" \
  --out    "$RUN_DIR/verdict.json"

VERDICT=$(python3 -c "import json; print(json.load(open('$RUN_DIR/verdict.json'))['verdict'])")
echo "Initial verdict: $VERDICT"
```

---

## Step 4 — Cross-review pass (only if VERDICT == CONTESTED)

When verdict is `CONTESTED`, the two reviewers disagree on what's high-severity. Run one more pass:

1. Extract `high_contested` from `$RUN_DIR/verdict.json`. Group by which reviewer flagged it (`agreed_by`).
2. Build two cross-review prompts:
   - **For Claude** (codex's contested high findings): "Reviewer codex flagged these high-severity issues you did not catch. For each: AGREE / DISAGREE / NEEDS-MORE-CONTEXT, with a one-line rationale."
   - **For codex** (Claude's contested high findings): same shape.
3. Run both prompts (Agent tool for Claude, codex exec for codex) — sequentially is fine; this pass is smaller.
4. Parse each response. A finding promoted to `AGREE` by the OTHER reviewer is now consensus.
5. Re-run `koji-duet-synthesize` with the updated finding sets (write `claude.cross.json` and `codex.cross.json`, then synthesize). If consensus emerges → verdict becomes `REJECT`. If still no overlap → verdict stays `CONTESTED`.

**Single pass only.** Do not loop. Looping invites fatigue-consensus where reviewers just agree to end the conversation.

---

## Step 5 — Auto-apply prompt (skip if `--no-auto-apply`)

Read `$RUN_DIR/verdict.json`. For each finding in `high_consensus` with `suggested_fix.type == "mechanical"` AND `suggested_fix.scope == "single-file"`:

### 5a. Check rule memory

```bash
REPO_RULES="$KOJI_STATE_DIR/repos/$(basename "$PROJECT_ROOT")-$SESSION_HASH/duet-rules.json"
SESSION_RULES="$SESSION_DIR/duet-rules.json"
mkdir -p "$(dirname "$REPO_RULES")" "$SESSION_DIR"

# Check if finding.category is already whitelisted at either scope
matches_rule() {
  local cat="$1" file="$2"
  [ -f "$file" ] || return 1
  python3 -c "
import json, sys
try:
    rules = json.load(open('$file'))
    cats = rules.get('auto_apply_categories', [])
    sys.exit(0 if '$cat' in cats else 1)
except Exception:
    sys.exit(1)
"
}
```

If `matches_rule $category $REPO_RULES` OR `matches_rule $category $SESSION_RULES` → auto-apply silently (use Edit tool with `suggested_fix.details`). Add to `auto_applied` list in the verdict.

### 5b. Otherwise, prompt with 4 choices

Use `AskUserQuestion`:

- **Question**: `"Apply fix for <category> at <file>:<line>?"`
- **Description body**: includes the finding's `description`, both reviewers' agreement, and the `suggested_fix.details`.
- **Options** (single-select, exactly 4):
  1. `Apply` — *"Apply this fix only, this time."*
  2. `Hold` — *"Skip; keep in summary for manual review."*
  3. `Apply + remember for repo` — *"Apply now, and auto-apply this category for this repo from now on."*
  4. `Apply + remember for session` — *"Apply now, and auto-apply this category for the rest of this koji session."*

### 5c. Persist rule choice if user picked 3 or 4

```bash
add_to_rules() {
  local cat="$1" file="$2"
  python3 - "$cat" "$file" <<'EOF'
import json, sys, os, pathlib
cat, path = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
data = {}
if p.exists():
    try: data = json.loads(p.read_text())
    except Exception: data = {}
cats = data.get("auto_apply_categories", [])
if cat not in cats:
    cats.append(cat)
data["auto_apply_categories"] = cats
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2))
EOF
}
```

- Choice 3 → `add_to_rules "$category" "$REPO_RULES"`
- Choice 4 → `add_to_rules "$category" "$SESSION_RULES"`

### 5d. Apply

For choices 1, 3, 4: invoke the Edit tool with `suggested_fix.details` to apply the fix. For choice 2: add to `user_held`. Update `$RUN_DIR/verdict.json` accordingly (move findings between `auto_applied` / `user_held`).

---

## Step 6 — Output

Print a markdown summary to the user:

```
duet-review verdict: <VERDICT>

Reviewers: claude (high effort) + codex (high effort)
Diff: <N> lines  base=<base>  head=<sha>

Consensus high (X):   <list — auto-applied / held by user / failed apply>
Contested high (Y):   <list>
Medium (Z):           <list>
Low (W):              <list>

Output JSON: <RUN_DIR>/verdict.json
Exit code: <0|1|2>
```

Then `exit $EXIT_CODE` where exit code comes from `verdict.json`.

---

## Failure modes

| Symptom | Likely cause | Mitigation |
|---|---|---|
| Codex hangs (no output, no timeout fire) | Stdin not closed, or `--enable web_search_cached` re-introduced | This skill explicitly drops both — verify the bash above wasn't modified. Kill `$CODEX_PID` manually. |
| Codex exits 124 | Hit the timeout. xhigh's 30-min wall isn't enough for very large diffs. | Re-run with smaller scope (`--base`), or `--no-auto-apply` to at least get the report. |
| Agent (Claude) returns prose instead of JSON | Reviewer prompt drift, or model decided to chat. | The prompt body explicitly demands strict JSON; the JSON extractor handles single arrays. If the array is missing → treat as `[]`. |
| Synthesize crashes | Malformed input (rare; both reviewers were instructed to emit strict JSON) | `koji-duet-synthesize` is defensive: bad input → empty findings → PASS verdict. |
| User chose "remember for repo" but rule doesn't trigger next session | Likely fingerprint mismatch on the OTHER reviewer (consensus didn't form again). Rules need consensus PLUS category match. | This is intentional — rule does not auto-apply on single-reviewer findings. |

## Related

- Autonomy principle: [references/agent-autonomy.md](references/agent-autonomy.md)
- Verdict JSON spec: [references/verdict-format.md](references/verdict-format.md)
- Reviewer prompt: [references/reviewer-prompt.md](references/reviewer-prompt.md)
- Synthesizer: [koji/bin/koji-duet-synthesize](../bin/koji-duet-synthesize)
- Cleanup: `/wrap` removes `$SESSION_DIR/duet-rules.json` (session-scoped rules expire at wrap)
