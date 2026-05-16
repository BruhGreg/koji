---
description: "Two-reviewer adversarial review: Claude + codex in parallel, synthesize, cross-review on disagreement, prompt on auto-apply. Invocation requires the 'duet' keyword."
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

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

## When to invoke

Use ONLY when the user explicitly types `/duet-review`, says "duet review", "duet-review", "let's duet review this diff", or similar — the `duet` keyword is required. Do NOT invoke on casual "review this" or "code review" phrases — gstack `/review` handles those.

Two-reviewer adversarial code review. **Reviewer A** is Claude (Agent subagent, fresh context); **Reviewer B** is codex (codex exec, `xhigh` effort by default — drop to `high` only via natural-language signal per the Arguments note). Both run in parallel; results are synthesized into a verdict; reviewer-exclusive findings at severity ≥ medium trigger a cross-review pass with severity-aware AGREE labels; high-consensus mechanical fixes prompt the user with four choices (apply / hold / apply+remember-for-repo / apply+remember-for-session).

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
- `--no-auto-apply` — skip the 4-choice prompt; emit verdict only

**Codex effort: default xhigh, opt down by saying so.** Codex runs at `xhigh` (~30-min timeout, ~2.5× tokens). Drop to `high` ONLY when the user's invocation phrase signals lighter effort — e.g., "quick review", "lighter pass", "use high effort", "save tokens", "fast check". Don't downgrade for "the diff looks small" or similar heuristics; only on explicit user signal. Claude inherits the parent session's effort level — set `/effort max` once before running if you want max-tier Claude reviewer.

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

## Step 2 — Launch reviewers in parallel (both backgrounded)

Both reviewers run as **background tasks**. After launching them, briefly tell the user that the reviewers are running and that they can keep working on other things; you'll resume when both background tasks notify completion. Do NOT block on either reviewer mid-flow.

### 2a. Start codex (Reviewer B) in background

```bash
# Default codex effort: xhigh. Agent sets EFFORT=high TIMEOUT=900 BEFORE this
# block only when the user's invocation phrase signals lighter effort (see
# "Codex effort" note in Arguments above).
EFFORT="${EFFORT:-xhigh}"
TIMEOUT="${TIMEOUT:-1800}"
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
PROMPT_FILE="$KOJI_SKILLS/duet-review/references/reviewer-prompt.md"

# Compose prompt inline (the prompt + diff together — codex reads it as one positional arg)
CODEX_PROMPT="$(cat "$PROMPT_FILE")

---

Now review the diff below. Output STRICT JSON only — no markdown fences, no preamble, no commentary. If no findings, output [].

DIFF:
$(cat "$DIFF_FILE")"

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
```

Run this Bash block with **`run_in_background: true`**. The harness returns immediately with a task ID; you (the main agent) will be notified when the command completes. The output file path the harness gives you can also be polled if needed, but the notification is the primary signal.

### 2b. Run Claude reviewer (Reviewer A) via Agent tool — also backgrounded

Call the `Agent` tool with **`run_in_background: true`**:

- `subagent_type`: `general-purpose`
- `description`: `Duet review: Claude pass`
- `prompt`: the full reviewer-prompt.md text PLUS the diff, with the closing instruction:
  > *"Output ONLY a JSON array. No markdown fences, no preamble, no closing remarks. If no findings, output `[]`."*
- `run_in_background`: `true`

The Agent tool returns immediately with an agent ID; you'll be notified when the subagent completes.

### 2c. Tell the user, then go

After both reviewers are launched, tell the user something like:

> *"duet-review running — codex + Claude reviewer both launched in background. I'll come back with the verdict when both complete; in the meantime you can continue with anything else."*

Then **return control**. Do NOT poll, sleep, or proactively check on progress. The harness will re-invoke you with the notification messages.

### 2d. On notification: collect outputs

When the codex Bash notification arrives, extract its JSON:

```bash
CODEX_EXIT=$(cat "$RUN_DIR/codex.exit")
if [ "$CODEX_EXIT" = "124" ]; then
  echo "WARN: codex timed out at ${TIMEOUT}s. Treating as empty findings."
  echo "[]" > "$RUN_DIR/codex.json"
elif [ "$CODEX_EXIT" != "0" ]; then
  echo "WARN: codex exit $CODEX_EXIT. See $RUN_DIR/codex.err"
  echo "[]" > "$RUN_DIR/codex.json"
else
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

echo "codex.json:  $(wc -c < "$RUN_DIR/codex.json") bytes"
```

When the Claude reviewer Agent notification arrives, extract the JSON array from its response and write to `$RUN_DIR/claude.json` via the Write tool. If the response contains no parseable array, write `[]` and note it in the summary.

**Proceed to Step 3 only after BOTH notifications have arrived and both `$RUN_DIR/claude.json` and `$RUN_DIR/codex.json` exist.** If one reviewer is still running when you're re-invoked by the other's notification, just confirm collection of the one that finished and return control again — the second notification will re-invoke you.

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
CROSS_REQUIRED=$(python3 -c "import json; print(str(json.load(open('$RUN_DIR/verdict.json'))['cross_review_required']).lower())")
echo "First-pass verdict: $VERDICT  (cross_review_required=$CROSS_REQUIRED)"
```

**The synthesizer's stdout also signals this** — when `cross_review_required=true && cross_review_done=false`, the printed verdict carries a `-PRELIMINARY` suffix (e.g. `CONTESTED-PRELIMINARY`, `PASS-WITH-NOTES-PRELIMINARY`). After Step 4 re-runs synthesize with `--cross-review-done`, the suffix drops to the clean `<verdict>`. **If you see `-PRELIMINARY`, your NEXT action is Step 4 — dispatch the cross-review calls. Do NOT skip to Step 5 or Step 6. Step 5 will refuse to run while cross-review is pending.**

---

## Step 4 — Cross-review pass (hard-gated on `cross_review_required`)

The synthesizer sets `cross_review_required = true` whenever ANY reviewer-exclusive finding has severity ≥ medium (lows skip — "not a style committee"). If the flag is `false`, skip this step entirely. If `true`, the orchestrator MUST run this step before Step 5 will accept the verdict.

### 4a. Build the two cross-review payloads

Read `$RUN_DIR/verdict.json` and partition the contested/solo findings by who flagged them:

```bash
python3 - <<'PY' "$RUN_DIR/verdict.json" "$RUN_DIR/codex-cross-targets.json" "$RUN_DIR/claude-cross-targets.json"
import json, sys
src, codex_out, claude_out = sys.argv[1], sys.argv[2], sys.argv[3]
v = json.load(open(src))
# Codex cross-reviews CLAUDE's solo findings; Claude cross-reviews CODEX's.
solo_claude = [f for f in v["high_contested"] + v["medium"] + v["low"]
               if f.get("agreed_by") == ["claude"] and f.get("severity") in ("high","medium")]
solo_codex  = [f for f in v["high_contested"] + v["medium"] + v["low"]
               if f.get("agreed_by") == ["codex"]  and f.get("severity") in ("high","medium")]
json.dump(solo_claude, open(codex_out, "w"))
json.dump(solo_codex,  open(claude_out, "w"))
print(f"Codex will review {len(solo_claude)} Claude findings; "
      f"Claude will review {len(solo_codex)} codex findings")
PY
```

### 4a-bis. Early-exit if both targets are empty

Defensive: if the partition above produced zero targets on BOTH sides, skip Step 4b/4c entirely and flip `cross_review_done` directly (no point dispatching two expensive cross-review subprocesses to assess empty arrays). This case shouldn't normally happen — if `cross_review_required=true`, the synthesizer guarantees ≥ 1 solo high/medium finding — but stale verdict state could trigger it.

```bash
codex_target_count=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/codex-cross-targets.json'))))")
claude_target_count=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/claude-cross-targets.json'))))")
if [ "$codex_target_count" = "0" ] && [ "$claude_target_count" = "0" ]; then
  echo "WARN: cross_review_required but both target sets are empty. Marking done and skipping dispatch."
  echo '[]' > "$RUN_DIR/codex.cross.json"
  echo '[]' > "$RUN_DIR/claude.cross.json"
  ~/.claude/skills/koji/bin/koji-duet-synthesize \
    --claude "$RUN_DIR/claude.json" \
    --codex  "$RUN_DIR/codex.json" \
    --claude-cross "$RUN_DIR/claude.cross.json" \
    --codex-cross  "$RUN_DIR/codex.cross.json" \
    --cross-review-done \
    --base "$BASE" --head "$HEAD_SHA" \
    --out  "$RUN_DIR/verdict.json"
  # Skip the rest of Step 4; proceed to Step 5.
fi
```

### 4b. Dispatch both cross-reviews in parallel (background)

Both use **severity-aware AGREE labels** — plain AGREE/DISAGREE loses signal when a reviewer accepts the bug but disputes whether it ships:

- `AGREE-HIGH` — yes, ship-blocking
- `AGREE-MEDIUM` — yes, should-fix but not blocking
- `AGREE-LOW` — yes, nit only
- `DISAGREE` — false positive
- `NEEDS-MORE-CONTEXT` — can't tell from what was shown

**Codex cross-review (Bash, background)** — codex reads `$RUN_DIR/codex-cross-targets.json` (Claude's solo findings) and emits a JSON array of `{fingerprint, verdict, rationale}`:

```bash
CROSS_PROMPT="You are codex. Another reviewer (Claude) flagged the following findings on this diff that you did not catch in your first-pass review. For each, return your assessment using these severity-aware labels:

  AGREE-HIGH     | yes, ship-blocking
  AGREE-MEDIUM   | yes, should fix but not blocking
  AGREE-LOW      | yes, nit
  DISAGREE       | false positive — explain why
  NEEDS-MORE-CONTEXT | can't tell from what was shown

DIFF:
$(cat "$DIFF_FILE")

CLAUDE'S FINDINGS TO ASSESS (JSON):
$(cat "$RUN_DIR/codex-cross-targets.json")

Output STRICT JSON only — array of {\"fingerprint\": \"...\", \"verdict\": \"AGREE-HIGH\"|..., \"rationale\": \"one line\"}. No markdown fences. Empty array if nothing to assess."

if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec "$CROSS_PROMPT" \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < /dev/null > "$RUN_DIR/codex.cross.raw" 2> "$RUN_DIR/codex.cross.err"
else
  codex exec "$CROSS_PROMPT" \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < /dev/null > "$RUN_DIR/codex.cross.raw" 2> "$RUN_DIR/codex.cross.err"
fi
echo $? > "$RUN_DIR/codex.cross.exit"
```

Run with **`run_in_background: true`**.

**Claude cross-review (Agent, background)** — call the `Agent` tool with `run_in_background: true`. Prompt:

```
You are a code reviewer. Another reviewer (codex) flagged the following findings on this diff that you did not catch in your first-pass review. For each, return your assessment using these labels: AGREE-HIGH / AGREE-MEDIUM / AGREE-LOW / DISAGREE / NEEDS-MORE-CONTEXT.

DIFF FILE PATH: <DIFF_FILE>

CODEX'S FINDINGS TO ASSESS (JSON): <contents of $RUN_DIR/claude-cross-targets.json>

Output STRICT JSON ONLY — array of {fingerprint, verdict, rationale}. No markdown fences, no commentary. Empty array if nothing to assess.
```

### 4c. Collect both responses, re-synthesize

When BOTH notifications arrive, extract JSON arrays and write to `$RUN_DIR/codex.cross.json` and `$RUN_DIR/claude.cross.json` (same JSON-extraction pattern as Step 2d). Then re-run the synthesizer with the new inputs:

```bash
~/.claude/skills/koji/bin/koji-duet-synthesize \
  --claude "$RUN_DIR/claude.json" \
  --codex  "$RUN_DIR/codex.json" \
  --claude-cross "$RUN_DIR/claude.cross.json" \
  --codex-cross  "$RUN_DIR/codex.cross.json" \
  --cross-review-done \
  --base "$BASE" --head "$HEAD_SHA" \
  --out  "$RUN_DIR/verdict.json"

FINAL_VERDICT=$(python3 -c "import json; print(json.load(open('$RUN_DIR/verdict.json'))['verdict'])")
echo "Post-cross-review verdict: $FINAL_VERDICT"
```

**Single pass only.** Do not loop (fatigue-consensus). After this step, `cross_review_done = true` regardless of outcome (REJECT/CONTESTED both stay valid).

### 4d. Failure-mode fallback

If either cross-review times out or returns unparseable JSON, write `[]` for that side and proceed — original solo findings stay solo (safe degradation).

---

## Step 5 — Auto-apply prompt (skip if `--no-auto-apply`)

**Gate:** Step 5 refuses to run if `cross_review_required == true && cross_review_done == false`. Check before proceeding:

```bash
GATE=$(python3 -c "
import json
v = json.load(open('$RUN_DIR/verdict.json'))
if v['cross_review_required'] and not v['cross_review_done']:
    print('BLOCKED')
else:
    print('OK')
")
if [ "$GATE" = "BLOCKED" ]; then
  echo "ERROR: cross_review_required is true but cross_review_done is false."
  echo "       Go back to Step 4 — do NOT print a summary or apply fixes yet."
  exit 1
fi
```

Forces Step 4 to run when required, preventing stale CONTESTED summaries.

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

**Gate (same as Step 5):** refuse to print a summary if `cross_review_required && !cross_review_done`. Re-use the gate check from Step 5.

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

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Verdict JSON spec: [references/verdict-format.md](references/verdict-format.md)
- Reviewer prompt: [references/reviewer-prompt.md](references/reviewer-prompt.md)
- Synthesizer: [koji/bin/koji-duet-synthesize](../bin/koji-duet-synthesize)
- Cleanup: `/wrap` removes `$SESSION_DIR/duet-rules.json` (session-scoped rules expire at wrap)
