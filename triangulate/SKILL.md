---
description: "Multi-side debate on one question — Claude + codex argue in parallel, iterate across rounds as needed to converge. You synthesize the call. Web research per voice."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Agent
  - WebSearch
  - WebFetch
  - AskUserQuestion
---

# /triangulate

Three reference points → one decision. Claude voice + codex voice + **you**. Each AI runs in parallel with web + codebase research, presents its position, and you synthesize the call. **Multi-round when one pass isn't enough** — after the first synthesis you can dispatch another round (each voice gets the other's adversarial counter-prompt) until you've converged.

Family relationship to `/duet-plan`: same multi-side debate pattern, but `/duet-plan` lets the agents detect `VERDICT: AGREE` and locks a plan file, while `/triangulate` keeps **you** as the synthesizer — user inside the loop, not just approver.

## When to invoke

Use when the user types `/triangulate`, says "let's triangulate this", "triangulate X", or similar. The word "triangulate" is rare enough to be a reliable trigger on its own — no `duet` keyword guard needed.

Examples:
- "let's triangulate the error struct shape"
- "/triangulate should we use enum or string-kind hybrid"
- "triangulate the click-nav hook design"

Don't auto-invoke on generic "let's decide" / "help me think this through" — those should keep using `/duet-plan` (for multi-round consensus) or just normal conversation.

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji triangulate ==="
echo "Project: $PROJECT_NAME"
```

If codex is not on PATH, warn and continue in Claude-only mode (degraded — true triangulation needs both AI voices):

```bash
if ! command -v codex >/dev/null 2>&1; then
  echo "WARN: codex not found on PATH. Running in Claude-only mode (no triangulation)."
  NO_CODEX=1
fi
```

## Arguments / question extraction

The question is whatever the user provided after the skill name:

| User said | Question |
|---|---|
| "triangulate how to shape the SimError struct" | "how to shape the SimError struct" |
| "let's triangulate the click-nav hook design" | "the click-nav hook design" |
| "/triangulate should we use enum or hybrid" | "should we use enum or hybrid" |
| "/triangulate" (no question) | ask user once via AskUserQuestion |

Flags (all optional — most users never need any):
- `--stances=<a>,<b>` — assign opposing stances to each voice (e.g., `convention,principled`). Default: both voices get the same prompt and form their own takes from their own priors.
- `--rounds N` — max rounds (default 1). The user opts into additional rounds via prompt after each synthesis.
- `--no-codex` — Claude only (degraded — not really triangulation, but useful when codex is unavailable).
- `--keep` — keep `/tmp/triangulate-<sha>/` for debugging (default: cleaned at end of run).

**Codex effort: default xhigh, opt down by saying so.** Codex runs at `xhigh` (~30-min timeout, ~2.5× tokens). Drop to `high` ONLY when the user's invocation phrase signals lighter effort — e.g., "quick triangulate", "lighter pass", "use high effort", "save tokens", "fast pass". Don't downgrade for "the question seems simple" or similar heuristics; only on explicit user signal. Claude inherits the parent session's effort level — set `/effort max` once before running if you want max-tier Claude.
- `--no-save` — in-session only; skip persistence entirely (no fold-in, no prompt, no file write).
- `--save-as plans/<slug>.md` or `--save-as research/<slug>.md` — explicit override; skip the judgment and write a new file directly.
- `--update <path>` — explicit override; skip the judgment and append a synthesis section to an existing plan/research file.
- `--no-anchor` — force the save prompt even when recent context shows a clear anchor doc (use when the synthesis should be saved separately from the doc it looks like it belongs to).

**Persistence is context-driven by default** — Step 5 folds the synthesis into the doc it is clearly a sub-decision of (its *anchor*), or prompts where to save when there is no such doc. The flags above are escape hatches when you already know.

## Step 1 — Setup

```bash
RUN_DIR=$(mktemp -d -t triangulate-XXXXXX)
QUESTION="<question from invocation>"
echo "$QUESTION" > "$RUN_DIR/question.txt"

# ROUND must be initialized in Step 1 — Step 2b's NO_CODEX placeholder uses
# it (would otherwise write `round--codex.md`) and Step 4 increments it.
ROUND=1

# Default codex effort: xhigh. Agent sets EFFORT=high TIMEOUT=900 BEFORE this
# block only when the user's invocation phrase signals lighter effort (see
# "Codex effort" note in Flags above).
EFFORT="${EFFORT:-xhigh}"
TIMEOUT="${TIMEOUT:-1800}"
ROUND_LIMIT="${ROUNDS:-1}"
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# Optional opposing stances
STANCE_CLAUDE=""
STANCE_CODEX=""
if [ -n "${STANCES:-}" ]; then
  STANCE_CLAUDE="${STANCES%,*}"
  STANCE_CODEX="${STANCES#*,}"
  echo "Stances: Claude=$STANCE_CLAUDE, codex=$STANCE_CODEX"
fi

PROJECT_CONTEXT="(repo: $(basename "$PROJECT_ROOT"); branch: $(git branch --show-current 2>/dev/null || echo unknown))"

echo "Question: $QUESTION"
echo "Run dir: $RUN_DIR"
echo "Round limit: $ROUND_LIMIT, effort: $EFFORT"
```

## Step 2 — Round 1 dispatch (both voices in parallel, background)

Both voices run as **background tasks** so the user can keep working. After launching, briefly tell the user what's running and return control. Resume when the harness re-invokes with completion notifications.

### 2a. Claude voice (Agent tool, background)

Call the `Agent` tool with `run_in_background: true`:

- `subagent_type`: `general-purpose`
- `description`: `Triangulate round 1: Claude voice`
- `prompt`: see template below
- `run_in_background`: `true`

Claude voice prompt (substitute `{question}`, `{project_root}`, `{project_context}`, and optionally `{stance}`):

```
You are one of two AI voices being asked the same question in parallel. The
other voice is codex (a different model with different training and priors).
The user will read both perspectives and synthesize the call — you do NOT need
to reach consensus with codex. Argue from your strongest reasoning.

QUESTION: {question}
REPOSITORY: {project_root}
{project_context}

{IF stance: Your assigned stance: argue strongly for the "{stance}" position.
Make the strongest case you can; do not hedge.}
{IF no stance: Pick the angle from which your answer feels most clear — and
commit to it. Don't try to cover every consideration; trust the other voice
to bring the angles you skip. Bring your strongest reasoning from one
viewpoint, not a balanced survey. Don't hedge.}

You may:
- Read files in the repo (Read tool)
- Search the web (WebSearch, WebFetch) for community best practice, framework
  docs, prior art
- Dispatch sub-agents for deep investigation if needed

Output structure (markdown):

## Position
<your recommendation in one paragraph>

## Reasoning
<bullet points or short prose, including any evidence from research/code>

## Tradeoffs
<honest acknowledgment of downsides>

## What I'd want the other voice to defend
<one question or angle you'd push the other voice on — used as adversarial
prompt if the user asks for another round>

Be specific. The user is the synthesizer; give them material to weigh, not
mush to defer to.
```

**Do NOT return control yet** — Step 2b still has to dispatch codex (or write the NO_CODEX placeholder). Proceed to Step 2b before any user-facing "I'll come back with the synthesis" message; otherwise the second voice never starts.

When the Claude Agent completion notification eventually arrives, write the result to `$RUN_DIR/round-${ROUND}-claude.md` via the Write tool.

### 2b. Codex voice (Bash, background)

**Skip this step entirely if `$NO_CODEX` is set** (codex not on PATH, or user passed `--no-codex`). In that case, write a placeholder file so the synthesis step has something to read:

```bash
if [ "${NO_CODEX:-0}" = "1" ]; then
  CODEX_FILE="$RUN_DIR/round-${ROUND}-codex.md"
  printf '## Position\n\n(codex unavailable — Claude-only triangulation; this is degraded mode, the user is the second perspective)\n' > "$CODEX_FILE"
  echo "0" > "$CODEX_FILE.exit"
  echo "Skipped codex dispatch (NO_CODEX=1). Synthesis will use Claude position + user judgment only."
  # Skip the rest of Step 2b.
fi
```

Otherwise dispatch normally:

```bash
ROUND=1
CLAUDE_FILE="$RUN_DIR/round-${ROUND}-claude.md"
CODEX_FILE="$RUN_DIR/round-${ROUND}-codex.md"

# Build STANCE_LINE outside the prompt — inline `$(…echo "Don't hedge"…)`
# substitution explodes on the apostrophe inside the double-quoted prompt.
if [ -n "$STANCE_CODEX" ]; then
  STANCE_LINE="Your assigned stance: argue strongly for the \"$STANCE_CODEX\" position. Make the strongest case you can; do not hedge."
else
  STANCE_LINE="Pick the angle from which your answer feels most clear — and commit to it. Do not try to cover every consideration; trust the other voice to bring the angles you skip. Bring your strongest reasoning from one viewpoint, not a balanced survey. Do not hedge."
fi

CODEX_PROMPT="You are one of two AI voices being asked the same question in parallel. The other voice is Claude (a different model with different training and priors). The user will read both perspectives and synthesize the call — you do NOT need to reach consensus with Claude. Argue from your strongest reasoning.

QUESTION: $QUESTION
REPOSITORY: $PROJECT_ROOT
$PROJECT_CONTEXT

$STANCE_LINE

You may read files in the repo and search the web as needed.

Output structure (markdown):

## Position
<your recommendation in one paragraph>

## Reasoning
<bullet points or short prose, including any evidence from research/code>

## Tradeoffs
<honest acknowledgment of downsides>

## What I would want the other voice to defend
<one question or angle you would push the other voice on>"

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
```

Run this Bash block with **`run_in_background: true`** (only when `NO_CODEX` is unset). The two background tasks (Claude and codex) run truly in parallel — no sequential dependency in round 1.

**Only now (after both tasks have been created — Claude Agent + codex Bash, OR Claude Agent + NO_CODEX placeholder)** tell the user: *"Round ${ROUND}: Claude + codex dispatched in parallel. Each will research and present a position. I'll come back with the synthesis when both finish."* Then return control.

When the codex notification arrives (or immediately, in `NO_CODEX` mode where the placeholder file was already written):

```bash
CODEX_EXIT=$(cat "$CODEX_FILE.exit")
if [ "$CODEX_EXIT" = "124" ]; then
  echo "WARN: codex timed out. Treating as empty position."
  printf '## Position\n(codex timeout — no position available)\n' > "$CODEX_FILE"
elif [ "$CODEX_EXIT" != "0" ]; then
  echo "WARN: codex exit $CODEX_EXIT. See $CODEX_FILE.err"
  printf '## Position\n(codex failed to respond)\n' > "$CODEX_FILE"
else
  cp "$CODEX_FILE.raw" "$CODEX_FILE"
fi
```

**Proceed to Step 3 only after BOTH files exist.** In normal mode that means waiting for both notifications (Claude's Agent + codex's Bash). In `NO_CODEX` mode the codex placeholder file was written synchronously, so you only wait for Claude. If one task is still running when you're re-invoked by the other's notification, confirm collection of the finished one and return control again — the second notification re-invokes you.

## Step 3 — Synthesis

Read both files. Present to the user:

```
=== Claude's position ===
<truncated to ~30 lines or first H2 sections; full text at $RUN_DIR/round-1-claude.md>

=== Codex's position ===
<same truncation; full text at $RUN_DIR/round-1-codex.md>
```

Then write a **one-paragraph synthesis** identifying:

- **Convergences:** where do both voices agree?
- **Tensions:** where do they disagree, and what's the crux?
- **Recommendation:** which way does the synthesis point, given the evidence? (Don't be neutral when the evidence isn't — but flag your confidence honestly.)

Then `AskUserQuestion` — always fire when callable; do NOT skip just because synthesis looks unambiguous. The user makes the call, not the synthesizer.

> **What's the call?**

Options (single-select):

- **Lock the decision** — synthesis is enough; proceed to Step 5 persistence.
- **Another round** — re-dispatch both voices with each one's "what I'd want the other voice to defend" question as adversarial prompt. (Only show if `ROUND < ROUND_LIMIT` or after a +rounds increase below.)
- **Add a round and increase limit** — bump `ROUND_LIMIT` by 2 and dispatch another round. (Show when current round limit would be hit by "Another round.")
- **Abort** — drop the whole thing, no decision. Skip Step 5.

## Step 4 — Round N (N > 1)

If user picked "Another round":

1. **Increment ROUND first** — `ROUND=$((ROUND + 1))` — and rebind the round-specific filenames:
   ```bash
   ROUND=$((ROUND + 1))
   CLAUDE_FILE="$RUN_DIR/round-${ROUND}-claude.md"
   CODEX_FILE="$RUN_DIR/round-${ROUND}-codex.md"
   ```
   Without this, round-N writes would clobber round-1 artifacts and persistence/synthesis would read the wrong positions.
2. Re-dispatch both voices with:
   - The original question
   - Its previous position (`$RUN_DIR/round-$((ROUND-1))-{claude,codex}.md`)
   - The OTHER voice's previous position
   - The OTHER voice's "what I'd want you to defend" question as adversarial prompt
3. Same parallel-background pattern as Step 2 (write to the NEW `$CLAUDE_FILE`/`$CODEX_FILE` paths).
4. Same synthesis + AskUserQuestion at end (Step 3 reads `round-${ROUND}-*.md` rather than hard-coded round-1 paths).
5. Step 5 persistence also reads the latest round's positions.

## Step 5 — Persistence (context-anchored)

After the user picks "Lock the decision" in Step 3, the synthesis needs a home. There is exactly one judgment, and you answer it from your own **recent context** — not from a disk scan:

> **Is this triangulation a sub-decision of an existing doc?**

- **Yes — there is a clear anchor doc.** Signals: a review (e.g. `/plan-eng-review`) surfaced this question *from* a specific doc; the conversation has been iterating on a specific plan/research doc; the user explicitly tied the question to a doc. → **Branch A.**
- **No, or unclear.** Signals: no doc is in play; a doc merely *exists* in `.koji/plans/` but this synthesis is not a sub-decision of it; the question is topically near a doc without being part of it; two or more docs are plausible and none clearly wins. → **Branch B.**

The bar for "anchored" is high — only a doc your recent context **clearly names**. Any doubt resolves to Branch B. This is deliberate: Branch B always prompts, so an unanchored synthesis is never silently dropped — the worst case is one prompt you did not strictly need, never a lost decision.

**Flags override the judgment** — handle these first, before either branch:

- `--no-save` → skip persistence entirely. Print `Synthesis: in-session only (--no-save).` and go to Step 6.
- `--no-anchor` → go straight to Branch B, even if context looks anchored.
- `--save-as plans/<slug>.md` | `research/<slug>.md` → skip the judgment; run the **Save-as-new write** block below directly.
- `--update <path>` → skip the judgment; run the **Update-existing write** block below directly.

### Branch A — anchored: fold into the doc

No prompt — the destination is already settled by context. Append the synthesis to the anchor doc. Set `ANCHOR` to the path you identified from recent context:

```bash
ANCHOR="<anchor doc path — from your reading of recent context>"
case "$ANCHOR" in /*) ABS="$ANCHOR" ;; *) ABS="$PROJECT_ROOT/$ANCHOR" ;; esac
TODAY=$(date +%Y-%m-%d)

# Validate the anchor before appending. It came from context-reading, which can
# MISJUDGE — an unchecked append would corrupt whatever file it named (a source
# file, CLAUDE.md, …). Same guard as the --update block: reject traversal,
# require an existing file under $PLANS_DIR or $RESEARCH_DIR. Any failure →
# fall back to Branch B; the synthesis is never appended blind.
ANCHOR_OK=1
case "$ABS" in *"/.."*|*"/./"*|*"/..") ANCHOR_OK=0 ;; esac
if [ "$ANCHOR_OK" = "1" ] && [ -f "$ABS" ]; then
  ABS_REAL="$(cd "$(dirname "$ABS")" 2>/dev/null && pwd -P)/$(basename "$ABS")"
  PLANS_REAL="$(cd "$PLANS_DIR" 2>/dev/null && pwd -P)"
  RESEARCH_REAL="$(cd "$RESEARCH_DIR" 2>/dev/null && pwd -P)"
  case "$ABS_REAL" in
    "$PLANS_REAL"/*|"$RESEARCH_REAL"/*) ABS="$ABS_REAL" ;;
    *) ANCHOR_OK=0 ;;
  esac
else
  ANCHOR_OK=0
fi

if [ "$ANCHOR_OK" != "1" ]; then
  echo "Anchor '$ANCHOR' is not an existing doc under \$PLANS_DIR/\$RESEARCH_DIR — fall back to Branch B."
else
  # Append one H2 section at end of file. Existing frontmatter, headings,
  # and prose are left untouched.
  {
    printf '\n\n---\n\n'
    printf '## Triangulated decision: %s — %s\n\n' "$TODAY" "$QUESTION"
    printf '%s\n\n' "$SYNTHESIS_PARAGRAPH"
    printf '<details><summary>Voice positions</summary>\n\n'
    printf '### Claude\n\n'
    cat "$RUN_DIR/round-${ROUND}-claude.md"
    printf '\n\n### Codex\n\n'
    cat "$RUN_DIR/round-${ROUND}-codex.md"
    printf '\n\n</details>\n'
  } >> "$ABS"
  echo "Folded synthesis into: ${ABS#"$PROJECT_ROOT/"}"
fi
```

The anchor is **validated, not trusted** — it came from context-reading, which can misjudge. It must be an existing file under `$PLANS_DIR` or `$RESEARCH_DIR` (where plans and research docs live); a traversal segment, a missing file, or any path outside those trees fails the check. On failure the block reports falling back — execute **Branch B** instead, so the synthesis still gets a home. On success, report the destination; do **not** ask.

### Branch B — unanchored: ask where to save

No doc clearly owns this synthesis, so where it goes is a genuinely open question — fire one `AskUserQuestion`. **This prompt is unconditional**: it always fires in Branch B. An unanchored synthesis is never disposed of without the user getting a say.

**Before the prompt fires — run the topic-overlap scan** per [`../references/research-capture-eval.md`](../references/research-capture-eval.md) (Topic-overlap check + Naming convention sections):

1. `ls -1 "$RESEARCH_DIR"/*.md 2>/dev/null` — list existing topic-files.
2. For each existing file, read the first ~10 lines to identify the topic (frontmatter + H1 + opening paragraph).
3. Compare against this triangulation's synthesis + `$QUESTION`. Judge overlap.
4. Set `OVERLAP_TARGET` to the strongest overlap candidate's slug (filename without `.md`), or empty if no strong overlap.
5. Set `CONTENT_AREA_SLUG` to the agent-derived content-area name for the new-file case (1-3 words, names the *thing being studied*, NOT the question/event — see the reference's Naming convention).

> Save this synthesis?

**When `OVERLAP_TARGET` is non-empty (four options, single-select):**

- **Append to `<OVERLAP_TARGET>`** *(Recommended when overlap is strong)* — prepend a new `### YYYY-MM-DD` subsection to the existing topic-file's `## Decisions`. If multiple candidates overlap, this goes to the strongest; mention the others in the option description.
- **Save as new research: `<CONTENT_AREA_SLUG>`** — fresh topic-file with the accumulating structure; add a cross-ref to `<OVERLAP_TARGET>`.
- **Save as new plan** — write `$PLANS_DIR/<CONTENT_AREA_SLUG>.md` with `pending` status.
- **Don't save** — synthesis lives in conversation memory only.

**When `OVERLAP_TARGET` is empty (three options):**

- **Save as new research: `<CONTENT_AREA_SLUG>`** — fresh topic-file with the accumulating structure.
- **Save as new plan** — write `$PLANS_DIR/<CONTENT_AREA_SLUG>.md`.
- **Don't save** — conversation memory only.

There is no "update an existing doc" option here for an arbitrary anchor: if the synthesis belonged to an existing doc, that doc would be the anchor and you would be in Branch A. The **Append** option above is specifically for accumulating into an existing research topic-file.

**Default highlight + body shape.** Consult the reference doc: when the triangulation's research signals fire (multi-source investigation, alternatives with tradeoffs, preserved uncertainty, a validation path), pre-select the research option (**Append** when overlap exists, otherwise **Save as new research**) and use the reference's body structure. When the synthesis is a clean decision with no remaining uncertainty, pre-select **"Don't save"**. This sets only the default highlight — the prompt still fires, and the user still chooses.

On **"Save as new plan/research"**, set `SAVE_AS` and run the **Save-as-new write** block below:

```bash
# CONTENT_AREA_SLUG is agent-derived per the reference's Naming convention:
# 1-3 word content area, kebab-case, names the thing being studied — NOT
# the question/event/session that produced the finding. Fallback to regex
# over $QUESTION only if agent extraction was skipped.
if [ -z "${CONTENT_AREA_SLUG:-}" ]; then
  CONTENT_AREA_SLUG=$(printf '%s' "$QUESTION" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60 | sed 's/-$//')
  [ -n "$CONTENT_AREA_SLUG" ] || CONTENT_AREA_SLUG="triangulated-decision"
fi
# Then set SAVE_AS for the chosen kind:
#   "Save as new plan"     → SAVE_AS="plans/$CONTENT_AREA_SLUG.md"
#   "Save as new research" → SAVE_AS="research/$CONTENT_AREA_SLUG.md"
```

On **"Append to `<OVERLAP_TARGET>`"** → set `APPEND_TARGET="$RESEARCH_DIR/$OVERLAP_TARGET.md"` and run the **Append-to-topic-file write** block below.

On **"Don't save"** → nothing to write; go to Step 6.

**Non-interactive fallback — ONLY when `AskUserQuestion` is not callable** in this runtime (the tool is absent from the available tool list, or the session is in a spawned/headless mode that lacks prompt support). Do NOT use this branch just because the save choice looks obvious — if `AskUserQuestion` is callable, fire it. When the fallback applies, print one line and go to Step 6 without saving:

> Synthesis: in-session only (non-interactive — no save prompt). Re-run with --save-as plans/<slug>.md or --update <path> to persist.

---

### Save-as-new write (`--save-as`, or Branch B "save as new")

```bash
# Resolve target directory and frontmatter based on kind prefix.
case "$SAVE_AS" in
  plans/*.md)
    KIND="plan"
    REL_PATH="$SAVE_AS"
    TARGET_DIR="$PLANS_DIR"
    STATUS="pending"
    TARGET_FIELD="implementation"
    ;;
  research/*.md)
    KIND="research"
    REL_PATH="$SAVE_AS"
    TARGET_DIR="$RESEARCH_DIR"
    STATUS="unvalidated"
    TARGET_FIELD="validation"
    ;;
  *)
    echo "ERROR: --save-as must be 'plans/<slug>.md' or 'research/<slug>.md'"
    exit 1
    ;;
esac

# Path validation: reject absolute paths, parent escapes, nested subdirs.
case "$REL_PATH" in
  /*|*/../*|*/./*) echo "ERROR: --save-as path may not escape or nest"; exit 1 ;;
esac
case "$REL_PATH" in
  */*/*) echo "ERROR: --save-as: nested subdirs not supported (use a flat <slug>.md)"; exit 1 ;;
esac

SLUG="${REL_PATH#*/}"; SLUG="${SLUG%.md}"
mkdir -p "$TARGET_DIR"

# Auto-suffix on conflict.
OUT="$TARGET_DIR/$SLUG.md"
N=2
while [ -e "$OUT" ]; do
  OUT="$TARGET_DIR/${SLUG}-${N}.md"
  N=$((N + 1))
done

TODAY=$(date +%Y-%m-%d)
{
  printf -- '---\n'
  printf 'status: %s\n' "$STATUS"
  printf 'origin-session: %s\n' "$TODAY"
  printf 'target: %s\n' "$TARGET_FIELD"
  printf -- '---\n\n'
  printf '<!-- triangulated decision from /triangulate -->\n\n'
  printf '# %s\n\n' "$QUESTION"
  printf '## Synthesis\n\n%s\n\n' "$SYNTHESIS_PARAGRAPH"
  printf '## Voice positions\n\n'
  printf '### Claude\n\n'
  cat "$RUN_DIR/round-${ROUND}-claude.md"
  printf '\n\n### Codex\n\n'
  cat "$RUN_DIR/round-${ROUND}-codex.md"
} > "$OUT"

echo "Saved synthesis to: $OUT"
```

### Append-to-topic-file write (Branch B "Append to <OVERLAP_TARGET>")

When the user picks **Append to `<OVERLAP_TARGET>`** in Branch B, accumulate the new finding into the existing topic-file's `## Decisions` section rather than spawning a new file.

```bash
APPEND_TARGET="$RESEARCH_DIR/$OVERLAP_TARGET.md"
if [ ! -f "$APPEND_TARGET" ]; then
  echo "WARN: append target $APPEND_TARGET vanished — falling back to new-file write"
  SAVE_AS="research/$CONTENT_AREA_SLUG.md"
  # Re-enter the Save-as-new write block above with the fallback SAVE_AS.
fi

TODAY=$(date +%Y-%m-%d)

# $ONE_LINE_SUMMARY = one-line headline of this finding (≤80 chars,
# agent-derived from $SYNTHESIS_PARAGRAPH). Falls back to $QUESTION if unset.
ONE_LINE_SUMMARY="${ONE_LINE_SUMMARY:-$QUESTION}"

# Build the new dated subsection.
NEW_SECTION=$(cat <<EOF

### $TODAY — $ONE_LINE_SUMMARY

$SYNTHESIS_PARAGRAPH

<details><summary>Voice positions</summary>

#### Claude

$(cat "$RUN_DIR/round-${ROUND}-claude.md")

#### Codex

$(cat "$RUN_DIR/round-${ROUND}-codex.md")

</details>
EOF
)

# Two structural cases:
#   (1) File already has "## Decisions" → insert NEW_SECTION right after that heading
#       (so the new subsection lands at the TOP of Decisions — newest first).
#   (2) File has no "## Decisions" → append "## Decisions" + NEW_SECTION at EOF
#       (an older-format file gets upgraded; H1 + earlier prose stays untouched).
if grep -q '^## Decisions[[:space:]]*$' "$APPEND_TARGET"; then
  awk -v newsec="$NEW_SECTION" '
    /^## Decisions[[:space:]]*$/ && !done {
      print
      print newsec
      done = 1
      next
    }
    { print }
  ' "$APPEND_TARGET" > "$APPEND_TARGET.tmp" && mv "$APPEND_TARGET.tmp" "$APPEND_TARGET"
else
  {
    printf '\n## Decisions\n%s\n' "$NEW_SECTION"
  } >> "$APPEND_TARGET"
fi

echo "Research appended: ${APPEND_TARGET#"$PROJECT_ROOT/"} (## Decisions)"
```

Frontmatter is preserved unchanged on append — `origin-session` tracks file creation; the dated subsection inside `## Decisions` tracks each finding. If the new finding resolves or surfaces open questions, the agent SHOULD also edit the file's `## Open questions` section accordingly. If it surfaces a related topic, append a one-line entry to `## Cross-refs`.

### Update-existing write (`--update` flag)

```bash
# Resolve and validate. Canonicalize before the prefix check — otherwise
# `--update plans/../setup.md` would pass the literal `"$PLANS_DIR"/*` check,
# pass `[ -f ]`, and append synthesis to an arbitrary repo file.
UPDATE_PATH="<path from the --update flag>"
case "$UPDATE_PATH" in
  /*) ABS="$UPDATE_PATH" ;;
  *)  ABS="$PROJECT_ROOT/$UPDATE_PATH" ;;
esac
# Reject parent-escape segments before canonicalizing (cheap pre-check;
# also catches paths whose canonical form would happen to land back inside
# but were constructed adversarially).
case "$ABS" in
  *"/.."*|*"/./"*|*"/..") echo "ERROR: --update path may not contain '..' or '.' segments"; exit 1 ;;
esac
# Canonicalize the parent dir + basename so the prefix check is against the
# real on-disk path, not the literal user string.
if [ ! -f "$ABS" ]; then
  echo "ERROR: --update target does not exist: $ABS"
  exit 1
fi
ABS_REAL="$(cd "$(dirname "$ABS")" 2>/dev/null && pwd -P)/$(basename "$ABS")"
PLANS_REAL="$(cd "$PLANS_DIR" 2>/dev/null && pwd -P)"
RESEARCH_REAL="$(cd "$RESEARCH_DIR" 2>/dev/null && pwd -P)"
case "$ABS_REAL" in
  "$PLANS_REAL"/*|"$RESEARCH_REAL"/*) ;;
  *)
    echo "ERROR: --update target must be under \$PLANS_DIR or \$RESEARCH_DIR (resolved: $ABS_REAL)"
    exit 1
    ;;
esac
ABS="$ABS_REAL"
if [ ! -f "$ABS" ]; then
  echo "ERROR: --update target does not exist: $ABS"
  exit 1
fi

TODAY=$(date +%Y-%m-%d)

# Append a new H2 section at end of file (after a separator). Existing content
# is untouched — frontmatter, headings, prose all preserved verbatim.
{
  printf '\n\n---\n\n'
  printf '## Triangulated decision: %s — %s\n\n' "$TODAY" "$QUESTION"
  printf '%s\n\n' "$SYNTHESIS_PARAGRAPH"
  printf '<details><summary>Voice positions</summary>\n\n'
  printf '### Claude\n\n'
  cat "$RUN_DIR/round-${ROUND}-claude.md"
  printf '\n\n### Codex\n\n'
  cat "$RUN_DIR/round-${ROUND}-codex.md"
  printf '\n\n</details>\n'
} >> "$ABS"

echo "Appended synthesis to: ${ABS#"$PROJECT_ROOT/"}"
```

### Path validation rules

- `plans/<slug>.md` / `research/<slug>.md` — the prefix is a kind marker, NOT a literal subpath. Resolved as `$PLANS_DIR/<slug>.md` / `$RESEARCH_DIR/<slug>.md`.
- Reject absolute, parent-escape, and nested subdirs (enforced in bash above).
- For `--update`, the resolved path must already exist under `$PLANS_DIR`/`$RESEARCH_DIR`.
- Slug auto-derives kebab-case, ≤60 chars, fallback `triangulated-decision`.

## Step 6 — Cleanup

```bash
if [ "${KEEP:-0}" = "1" ]; then
  echo "Process artifacts kept at: $RUN_DIR"
else
  rm -rf "$RUN_DIR"
fi
```

## Step 7 — Report

```
triangulate: <locked | aborted>
Question: <question>
Voices:   Claude + codex (effort: <high|xhigh>)
Rounds:   <N>
Saved to: <folded into <anchor> | <new plan/research file> | in-session only>
```

## Failure modes

| Symptom | Cause | Mitigation |
|---|---|---|
| Codex hangs (no output, no timeout fire) | Stdin not closed, or web-search flag re-introduced | Skill omits `--enable web_search_cached` (confirmed silent-hang trigger) and uses `< /dev/null`. Codex's built-in research happens through its agent loop, not the cache flag. Kill PID; treat as empty position. |
| Codex exits 124 (timeout) | Web research took too long, or xhigh ran past 30 min | Re-run with `--rounds 1` only, or invoke with a "use high effort" / "lighter pass" phrase to opt down from the xhigh default. Round prompts are kept small (single question, no cumulative round context). |
| Both voices produce nearly-identical positions | Question framing didn't differentiate them, despite the default "pick an angle and commit" nudge | Re-run with `--stances=convention,principled` (or other opposing pair) — the harder forcing function when the soft nudge isn't enough. |
| Voices each ran heavy web research, total wallclock too slow | Both did `--search` independently | Acceptable for foundational decisions (the whole point is depth). For faster runs, invoke with a "use high effort" / "lighter pass" phrase to opt down, and set `--rounds 1`. |
| `--save-as plans/foo/bar.md` rejected | Nested subdirs not supported in v1 | Use a flat slug: `--save-as plans/foo-bar.md`. |

## Related

- `/duet-plan` — multi-round agent consensus (closer to "let the agents figure it out and lock a plan")
- `/duet-review` — two-AI code review (closer to "vet a diff with cross-model perspectives")
- `.koji/plans/` and `.koji/research/` — destination directories for `--save-as`
- Plans/research status workflow: `bin/koji-plans-research`
