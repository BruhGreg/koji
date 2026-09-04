# Reviewer Backend (duet skills)

Shared by `/duet-plan`, `/duet-impl`, `/duet-review`. Who reviews, at what effort, on which Claude model, is decided **at the start of every duet run** — one question, remembered — not in `.koji.yaml`. This file holds the parts that must not diverge across the three skills: the setup tuple and its helpers, the resolution order, the dialog, the strategies, the agent definitions, the mapping table, the read-only clause, the slot rule, the malformed-reply rule, and the quota rule.

## The setup tuple

One string, four `|`-joined fields: `STRATEGY|CODEX_EFFORT|CLAUDE_EFFORT|CLAUDE_MODEL`, e.g. `both|max|max|inherit`.

| Field | Values | Default |
|---|---|---|
| `STRATEGY` | `both` · `claude-then-codex` · `codex` · `claude` | `codex` |
| `CODEX_EFFORT` | `max` · `xhigh` · `high` — feeds codex's `model_reasoning_effort` | `xhigh` |
| `CLAUDE_EFFORT` | `max` · `xhigh` · `high` · `inherit` — selects the reviewer agent definition (below) | `xhigh` |
| `CLAUDE_MODEL` | `inherit` · `fable` · `opus` · `sonnet` — the Agent tool's `model` param; `inherit` = omit it | `inherit` |

The run's copy lives at **`$RUN_DIR/duet-setup`** (one line). Every Bash block that needs a field reads it from there through the helper — never from a remembered shell variable, since each block is a fresh shell. The last pick lives globally at `koji-config get duet_setup` (`~/.config/koji/config.yaml`): budget is per user, not per project.

### Helpers

- **`koji-duet-setup`** — the only place tuple syntax is known. `validate <tuple>` (normalized tuple on stdout, exit 1 + reason on stderr), `defaults`, `merge <base> <overlay>` (overlay field wins when non-empty), `summary <tuple>` (one human line: `both families · codex max · claude max/inherit`), `field <tuple> <1-4>`. Every tuple source — saved pick, embedded phrase, user phrase, dialog answer — passes `validate` before it is written anywhere.
- **`koji-duet-backend <plan-round|impl-gate|review-b> "$RUN_DIR/duet-setup"`** — the mapping table (below). The file is authoritative: missing or invalid → exit 3, nothing on stdout, `run state lost` on stderr. Callers `|| exit 1`. Never default to codex on a lost file — that would silently turn a `both` run into a weaker review.
- **`koji-duet-findings-check [--cross|--consult] <file>`** — exit 0 iff the file is a validated array (see "Malformed reply").

## Resolution order (Step 1 of each duet skill)

1. **Baseline** = `koji-config get duet_setup` if it validates, else `koji-duet-setup defaults`. An invalid saved pick is ignored with one stderr line.
2. **Phrase overlay** — koji reads intent, not flags. Fields the invocation phrase states ("with both reviewers", "codex at max", "claude reviewer on sonnet", "quick gates") form an overlay with empty unspecified fields; `EFFECTIVE=$(koji-duet-setup merge BASELINE OVERLAY)`. An effort stated once applies to both families unless the phrase splits it.
3. **Embedded call** — `/duet-impl` hands the tuple to its final `/duet-review` in the `Skill` invocation phrase (`duet setup: <tuple>`). The embedded review validates it, uses it verbatim, never prompts, never saves.
4. **Phrase fixed the strategy** → use `EFFECTIVE`; no prompt.
5. **A saved pick existed** → one `AskUserQuestion`, one question: *"Duet setup: `<summary of EFFECTIVE>` — reuse?"* Options **Reuse** / **Change**. The line shows the effective tuple, phrase overlays included, so an explicit field is never silently lost.
6. **No saved pick, or Change** → the dialog below. Answers overlay `EFFECTIVE`.
7. **`AskUserQuestion` not callable** (headless runtime) → `EFFECTIVE`; print `Duet setup: <summary> (no prompt available)`.

Then, in one Bash block:

```bash
TUPLE=$(~/.claude/skills/koji/bin/koji-duet-setup validate "$EFFECTIVE") || exit 1
~/.claude/skills/koji/bin/koji-config set duet_setup "$TUPLE"     # skip in the embedded case — the parent saved it
printf '%s\n' "$TUPLE" > "$RUN_DIR/duet-setup"
echo "Duet setup: $(~/.claude/skills/koji/bin/koji-duet-setup summary "$TUPLE")"
```

## The dialog — one `AskUserQuestion` call, three questions

**`/duet-plan` and `/duet-impl`:**

1. *Strategy* (this order): **Both families every time** — most calls, strongest signal; impl gates cross-review what the two disagree on, plan rounds hand the drafter both critiques · **Claude reviews, codex confirms** — cheap rounds; one codex call gates each lock or pass · **Codex only** — today's default · **Claude only** — zero codex; same-model caveat.
2. *Effort, both families*: **max** / **xhigh** / **high**. The auto-added "Other" field accepts a split ("codex max, claude high") → mapped onto the two effort fields → `validate`.
3. *Claude reviewer model*: **inherit** / **fable** / **opus** / **sonnet**.

**Standalone `/duet-review`:** Reviewer A is always Claude and Reviewer B is codex under every strategy but `claude`, so three of the four strategies are one behaviour there. Its first question is therefore *Reviewer B*: **codex** / **Claude (same-model, quota escape hatch)**. Choosing Claude sets `STRATEGY=claude`; choosing codex **keeps** a saved `both` / `claude-then-codex` strategy as-is (they already mean codex here) and sets `codex` only when the saved strategy was `claude` — a review-time answer never silently erases the strategy a later `/duet-impl` will reuse. Effort and model as above. A saved `both` or `claude-then-codex` pick is shown in the Reuse line as "Reviewer B: codex".

**Effort drives fan-out.** `/duet-review`'s `REVIEW_MODE` follows the tuple's Claude effort: `max` → `fanout` (five angle reviewers); `xhigh` / `high` → `single`; `inherit` → the session-effort rule (`/effort max` → fanout). The phrase still overrides both ways ("full review" / "all angles" → fanout; "quick" / "save tokens" → single). The budget question and the 5× fan-out cost are one decision.

## Strategies — what each means per skill

| `STRATEGY` | `/duet-plan` round | `/duet-impl` gate (1..N-1) | `/duet-review` (final) |
|---|---|---|---|
| `codex` | codex critiques | codex reviews | A = Claude, B = codex |
| `claude` | fresh Claude critiques; two Claude contexts agreeing is the lock | fresh Claude reviews | A = Claude, B = fresh Claude (same-model caveat) |
| `claude-then-codex` | fresh Claude critiques every round; the round that would lock is gated by one codex call in the same round (`+codex-final` record) | fresh Claude reviews; a clean Claude verdict is confirmed by one codex call on the same snapshot before the gate passes (`claude+codex-confirm` record) | A = Claude, B = codex |
| `both` | codex and a fresh Claude critique in parallel; the drafter gets both; lock needs both AGREE | codex and a fresh Claude review in parallel; findings merge through `koji-duet-synthesize`; one cross-review pass on what they disagree on | A = Claude, B = codex (natively two-family) |

Plan rounds under `both` do **not** cross-review critic disagreements — the drafter reconciles. Cross-review is a findings-with-fingerprints mechanism (impl gates, final review).

## Mapping table — `koji-duet-backend <context> <setup-file>`

Prints one of `codex`, `claude`, `both`. Single source of truth for the three skills; do not re-derive it in a SKILL.md.

| `STRATEGY` | `plan-round` | `impl-gate` | `review-b` |
|---|---|---|---|
| `codex` | codex | codex | codex |
| `claude` | claude | claude | claude |
| `claude-then-codex` | claude | claude | codex |
| `both` | both | both | codex |
| (no file, no `$DUET_STRATEGY`) | codex | codex | codex |

`review-b` never returns `both`: `/duet-review` is natively two-family. Under `claude-then-codex` the confirm step is not a helper decision — `/duet-impl` 2d triggers it from the strategy and the backend record.

## The Claude backend — what it is

A **fresh `Agent` context, never a fork**. A fork inherits the author's conversation and therefore the author's blind spots; a fresh subagent with only the prompt in front of it is the closest thing to a second reviewer the same model family can offer.

### Agent definitions and the dispatch rule

Claude reasoning effort is set in an agent definition's frontmatter, not on the Agent call. koji ships three: `agents/koji-reviewer-high.md`, `-xhigh.md`, `-max.md` (`effort: <x>`, no model, no tool restriction). `setup` links them into `~/.claude/agents/` and verifies them; a running session must restart to see new agent types.

**Every Claude *reviewer* Agent call in the three skills** is a literal `Agent` tool call with:

- `subagent_type`: `koji-reviewer-$CLAUDE_EFFORT` when `CLAUDE_EFFORT != inherit`; otherwise `general-purpose`
- `model`: **omitted** when `CLAUDE_MODEL` is `inherit`; otherwise its value (`fable` / `opus` / `sonnet`)
- `run_in_background`: `true`
- `prompt`: the **same filled template the codex path uses**, followed by the read-only clause below

If the call fails because the agent type is unknown (definitions not installed): print `⚠ koji-reviewer-<x> not installed — run koji setup; falling back to general-purpose (inherit effort)`, `touch "$RUN_DIR/claude-effort-fallback"`, and re-dispatch with `general-purpose`. Reports print `claude <effort>/<model>` from the tuple plus ` (fell back to inherit — agents not installed)` when that file exists.

Applies to: `/duet-plan` 2b Claude critic; `/duet-impl` 2c Claude leg, `both`-mode cross leg, consult leg; `/duet-review` 2a Claude B leg, 2b Reviewer A (single and all five angles), 4b both cross legs. **Not** the `/duet-plan` drafter (2a/2d) and **not** the `/duet-impl` promise auditor (3a) — those stay `general-purpose`.

Same-model caveat (printed by `/duet-review` Step 6 and `/duet-impl` Step 6 whenever a review had no codex component): consensus between two Claude contexts is two independent readings, not two model families. The disagreement signal is weaker, and exact-fingerprint agreement — which feeds `high_consensus`, the auto-apply-eligible bucket — inflates. `claude` is a quota escape hatch, not the recommended default.

### Read-only clause (verbatim — append to every Claude-backend prompt)

> You are a REVIEWER, not an implementer. Read anything you need under the repository, but do NOT modify it: no Edit, no Write, no file creation, no state-mutating `git`, no build/format/fix commands. Editing here would corrupt the diff under review and invalidate the verdict. Your entire output is the review text in the format requested above.

Codex's `-s read-only` is an enforced sandbox; this clause is an instruction, and the reviewer agents hold Edit/Write. So every Claude-backend site also **fingerprints the tree** with `~/.claude/skills/koji/bin/koji-tree-fingerprint` before dispatch (written to a `.fp` file next to the slot — each Bash block is a fresh shell) and compares on collection. A mismatch prints:

> ⚠ working tree changed while a read-only reviewer was in flight (reviewer or concurrent work) — review snapshot may be stale

and adds a note to the run's header. It is deliberately **unattributed**: `/duet-review` lets the user keep working during a review, so movement is not proof the reviewer edited.

## Output contracts — identical for every backend

| Skill | The reviewer must emit | Parsed by | Slot file |
|---|---|---|---|
| `/duet-plan` | prose critique ending in `VERDICT: AGREE \| PARTIAL[:…] \| DISAGREE[:…]` | `koji-duet-verdict` | `$RUN_DIR/round-N-codex.md` (+ `round-N-claude-critique.md` under `both`) |
| `/duet-impl` gate | strict JSON array of findings (`gate-review-prompt.md` schema) | `python3 json.load` in 2d | `$RUN_DIR/findings-<gate>-attempt-<n>.json` (family slots `…-claude.json` / `…-codex.json` under `both`) |
| `/duet-review` B | strict JSON array of findings (`reviewer-prompt.md` schema) | `koji-duet-synthesize --codex` | `$RUN_DIR/codex.json` (cross leg: `codex.cross.json`) |

**Slot rule.** For a single-family review (`codex`, `claude`, `claude-then-codex`), whichever backend runs writes the one slot the downstream reader consumes, so `koji-duet-verdict`, `koji-duet-synthesize` and `/duet-impl`'s 2d never learn which backend ran. Under `both`, the two families run in parallel and **must not share a file**: each writes its own family slot — `/duet-plan` `round-N-codex.md` (codex) + `round-N-claude-critique.md` (Claude); `/duet-impl` `findings-<gate>-attempt-<n>-codex.json` + `…-claude.json` — and a merge step writes the downstream slot. `/duet-review` is natively two-slot (`claude.json` / `codex.json`). Slot names (`codex.json`, `agreed_by: ["codex"]`, `reviewers: ["claude","codex"]`) are **slot identifiers**, A/B, kept stable for compatibility; the backend record (`round-N-backend.txt`, `gate-<g>-attempt-<n>-backend.txt`, `verdict.json`'s `reviewer_backends`) says who actually filled what. **A slot file exists only when it holds a validated array** — a failed check never leaves a file in the slot.

## Malformed reply — retry once, then fail closed

Every array bound for a slot is checked with `koji-duet-findings-check` (default schema for findings; `--cross` for cross-review verdicts; `--consult` for consult replies). A codex reply goes through `koji-codex-classify` first: any state other than `OK` → `rm -f` the slot (the classifier writes `[]` on `EMPTY`), and the quota rule below applies; on `OK` the extracted array is checked. A Claude reply is extracted from the Agent result and checked directly.

A failed check — no array, not a list, an entry without a valid severity, a verdict outside the label set — is a **malformed reply**: re-dispatch the same call once with the reminder *"Your last response was not a JSON array of the requested shape — re-output ONLY the array, `[]` if none."* (`/duet-plan`: *"…missing the VERDICT line — re-output the same critique with the marker appended."*). A second failure makes that reviewer **unavailable**. Never write `[]` for a reply you could not validate — `[]` means "reviewed, found nothing", and downstream reads it as PASS:

- `/duet-impl` gate → that family is unavailable for the attempt: single-family strategies record a deferral (`reviewer unavailable — malformed reply ×2`) and proceed to the next gate; `both` continues on the other family alone (record `both:claude-only` / `both:codex-only`) or, with neither, records the deferral.
- `/duet-review` B → `CODEX_UNAVAILABLE=1` (the degraded path); the `[]` written to the slot there is the degraded-run placeholder the Step 6 banner declares, not a finding count. Reviewer A angles → `[]` for that angle with a note (a fan-out degrades, never hangs).
- `/duet-plan` → the round records `VERDICT: DISAGREE: reviewer returned no VERDICT after retry` (cannot lock) and the deadlock prompt is surfaced.

## Quota / error rule — substitute on non-final reviews, wait on the final one

A codex `QUOTA`, `ERROR` or `TIMEOUT` (from `koji-codex-classify`) on a **non-final** review is re-run **immediately** by the Claude backend with the same prompt, a visible `⚠`, and the round/gate backend file overwritten with `codex-quota-substituted` / `codex-error-substituted`. Substitution is per-review, not a mode switch: the **next** review tries codex again (the 5-hour window may have restored). A lock therefore always carries a codex verdict unless the strategy is `claude`.

| Review | Final? | On codex QUOTA / ERROR / TIMEOUT |
|---|---|---|
| `/duet-plan` ordinary round (`codex`, `claude-then-codex` substituted round) | no | substitute Claude for this round |
| `/duet-plan` ordinary round under `both` | no | the Claude critique fills the slot too; record `both:codex-unavailable`; no second Claude critic. If that round would lock, the existing lock gate fires (record ≠ codex) |
| `/duet-plan` lock gate (the round that would lock) | **yes** | `QUOTA` → back off `QUOTA_BACKOFF` up to `QUOTA_MAX_WAITS`, re-running the same prompt file; cap → the "Deadlock at round limit" prompt with a *wait and retry the lock gate* option. `ERROR`/`TIMEOUT` → the round records `DISAGREE`, no lock. Never substitute. |
| `/duet-impl` gate, `codex` leg | no | substitute Claude for this gate |
| `/duet-impl` gate, `both` | no | the Claude leg is already reviewing: proceed on it alone, record `both:claude-only` (the record names the family that reviewed), skip the cross-review |
| `/duet-impl` gate, `claude-then-codex` confirm step | no | Claude confirming Claude is nothing: record `claude+codex-unavailable`, pass on the Claude verdict alone with a visible `⚠`; Step 6 names the gate |
| `/duet-impl` gate N (embedded `/duet-review`) | **yes** | back off and resume; cap → degraded banner |
| standalone `/duet-review` | **yes** | back off and resume; cap → degraded banner |

`/duet-plan`'s codex output is **prose**, so it classifies with `koji-codex-classify … --prose` (OK iff exit 0 and a `VERDICT:` line, checked before any quota-marker scan). Without `--prose` a healthy critique that *discusses* quota is labeled `QUOTA` — this happened in the wild.

## Resume semantics

`$RUN_DIR` layout: `duet-setup` plus the per-round / per-gate-attempt backend records. A run dir with no `duet-setup` cannot resume (`koji-duet-backend` exits 3 — run state lost); a missing backend record means **codex**. `/duet-impl`'s `claude+codex-confirm` record is a durable pending state: re-entering 2c with it runs the codex leg on the attempt's preserved diff and prompt, never Claude again. `/duet-plan` has no resume feature (`KEEP` only skips Step 5 cleanup).

## What does NOT apply to a Claude backend

- **`koji-codex-classify`** — never run it on Claude output. Its `[…]` grab and its substring quota scan over review text (`quota`, `429`, `rate limit`) would turn a review *about* rate-limiting code into a phantom `QUOTA` and an endless back-off. Extract the array from the `Agent` result and run `koji-duet-findings-check`.
- **`TIMEOUT`, `$TO`, exit 124, `.exit` files** — an `Agent` call has no wall clock here. A never-returning reviewer produces no wake-up of its own; it is declared unavailable when the orchestrator next acts (another notification, or the user's next message) with everything else in — fail closed per the malformed rule, never `[]`.
- **`model_reasoning_effort`** — codex's knob. Claude's effort is the agent definition (`koji-reviewer-<effort>`), plus the parent session's `/effort` under `inherit`.
- **`-s read-only`** — no sandbox; the read-only clause + tree fingerprint are the substitute.
