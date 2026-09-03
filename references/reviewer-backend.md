# Reviewer Backend (duet skills)

Shared by `/duet-plan`, `/duet-impl`, `/duet-review`. The adversarial voice in a duet is **codex by default**; `.koji.yaml` can swap in a fresh-context Claude subagent. This file holds the parts that must not diverge across the three skills: the mapping table, the read-only clause, the output contracts, the slot rule, and the quota rule.

```yaml
# .koji.yaml
duet:
  reviewer: codex                 # codex | claude | claude-rounds+codex-final
  claude_reviewer_model: inherit  # inherit | fable | opus | sonnet
  codex_effort: xhigh             # xhigh | high — default EFFORT; NL signals still override
```

`koji-detect` validates these (`DUET_REVIEWER`, `DUET_CLAUDE_MODEL`, `DUET_CODEX_EFFORT`); a typo warns on stderr and falls back to the default, so a misspelt key can never silently change who reviews.

## Mapping table — `koji-duet-backend <context>`

The helper `~/.claude/skills/koji/bin/koji-duet-backend` is the single source of truth. It is **stateless**: it reads `$DUET_REVIEWER` and a context name, and prints `codex` or `claude`.

| `duet.reviewer` | `plan-round` (duet-plan rounds) | `impl-gate` (duet-impl gates 1..N-1) | `review-b` (duet-review Reviewer B) |
|---|---|---|---|
| `codex` (default) | codex | codex | codex |
| `claude` | claude | claude | claude |
| `claude-rounds+codex-final` | claude | claude | **codex** |
| anything else | codex | codex | codex |

`/duet-review` is always a *final* review — it is the end-of-run pass `/duet-impl` embeds, and on its own it is the cross-model check — so the hybrid value resolves to codex there. The embedded `/duet-review` re-sources `koji-detect` in its own preamble and resolves its Reviewer B itself; callers never pass the backend through the invocation phrase.

### The hybrid rule (`claude-rounds+codex-final`) — stateless

Claude reviews every round. **Every round that would lock** (drafter `AGREE` + reviewer `AGREE`, where the reviewer was Claude) is gated by **one codex call in the same round number**: the Claude critique is archived to `round-N-claude-critique.md`, the slot is removed, and the codex leg runs on the same draft. Codex `AGREE` → lock. Codex `PARTIAL`/`DISAGREE` → `ROUND++`; the next round's backend is resolved by the helper again (Claude under hybrid), and the drafter revises against codex's critique. Clean case: exactly one codex call per plan. Messy case: one codex call per lock attempt. There is no phase file and no mode switch — the only state is `round-N-backend.txt`, which every round writes before dispatch.

Under `reviewer: claude` the lock gate never fires: two Claude contexts agreeing is the lock (`CONSENSUS REACHED at round N (claude-only)`).

## The Claude backend — what it is

A **fresh `Agent` context, never a fork**. A fork inherits the author's conversation and therefore the author's blind spots; a fresh `general-purpose` subagent with only the prompt in front of it is the closest thing to a second reviewer the same model family can offer. Every Claude-backend dispatch in the three skills is a literal `Agent` tool call with:

- `subagent_type`: `general-purpose`
- `run_in_background`: `true`
- `model`: **omitted** when `$DUET_CLAUDE_MODEL` is `inherit`; otherwise its value (`fable` / `opus` / `sonnet` — the `Agent` tool's own enum)
- `prompt`: the **same template the codex path fills**, followed by the read-only clause below

Same-model caveat (surfaced in `/duet-review`'s Step 6 header whenever Reviewer B is Claude): consensus between two Claude contexts is two independent readings, not two model families. The disagreement signal is weaker, and exact-fingerprint agreement — which feeds `high_consensus`, the auto-apply-eligible bucket — inflates. Cross-model review has caught control-flow bugs same-model review missed; `claude` is a quota escape hatch, not the recommended default.

### Read-only clause (verbatim — append to every Claude-backend prompt)

> You are a REVIEWER, not an implementer. Read anything you need under the repository, but do NOT modify it: no Edit, no Write, no file creation, no state-mutating `git`, no build/format/fix commands. Editing here would corrupt the diff under review and invalidate the verdict. Your entire output is the review text in the format requested above.

Codex's `-s read-only` is an enforced sandbox; this clause is an instruction, and a `general-purpose` subagent holds Edit/Write. So every Claude-backend site also **fingerprints the tree** with `~/.claude/skills/koji/bin/koji-tree-fingerprint` before dispatch (written to a `.fp` file next to the slot — each Bash block is a fresh shell) and compares on collection. A mismatch prints:

> ⚠ working tree changed while a read-only reviewer was in flight (reviewer or concurrent work) — review snapshot may be stale

and adds a note to the run's header. It is deliberately **unattributed**: `/duet-review` lets the user keep working during a review, so movement is not proof the reviewer edited.

## Output contracts — identical for both backends

| Skill | The reviewer must emit | Parsed by | Slot file (both backends write here) |
|---|---|---|---|
| `/duet-plan` | prose critique ending in `VERDICT: AGREE \| PARTIAL[:…] \| DISAGREE[:…]` | `koji-duet-verdict` | `$RUN_DIR/round-N-codex.md` |
| `/duet-impl` gate | strict JSON array of findings (`gate-review-prompt.md` schema) | `python3 json.load` in 2d | `$RUN_DIR/findings-<gate>-attempt-<n>.json` |
| `/duet-review` B | strict JSON array of findings (`reviewer-prompt.md` schema) | `koji-duet-synthesize --codex` | `$RUN_DIR/codex.json` (cross leg: `codex.cross.json`) |

**Same-file-slot rule.** A Claude-backend reviewer writes to exactly the path the codex leg writes, so `koji-duet-verdict`, `koji-duet-synthesize`, and `/duet-impl`'s 2d never learn which backend ran. Slot names (`codex.json`, `agreed_by: ["codex"]`, `reviewers: ["claude","codex"]`) are **slot identifiers**, A/B, kept stable for compatibility; `verdict.json`'s `reviewer_backends` field (`koji-duet-synthesize --b-backend`) carries the actual backend per slot.

**Malformed reply (no array / no `VERDICT:` line) → retry once with an explicit format reminder → then fail closed.** Never write `[]` for a reply you could not parse — `[]` means "reviewed, found nothing", and downstream reads it as PASS:

- `/duet-impl` gate → recorded deferral (`reviewer unavailable — malformed reply ×2`), proceed to the next gate.
- `/duet-review` B → `CODEX_UNAVAILABLE=1` (the existing degraded path, wording generalized to Reviewer B); the `[]` written to the slot there is the degraded-run placeholder the Step 6 banner declares, not a finding count.
- `/duet-plan` → the round records `VERDICT: DISAGREE: reviewer returned no VERDICT after retry` (cannot lock) and the deadlock prompt is surfaced — the reviewer is unavailable, so the user decides.

## Quota / error rule — substitute on non-final reviews, wait on the final one

A codex `QUOTA`, `ERROR` or `TIMEOUT` (from `koji-codex-classify`) on a **non-final** review is re-run **immediately** by the Claude backend with the same prompt, a visible `⚠`, and the round/gate backend file overwritten with `codex-quota-substituted` / `codex-error-substituted`. Substitution is per-review, not a mode switch: the **next** review tries codex again (the 5-hour window may have restored). A lock therefore always carries a codex verdict unless `reviewer: claude` was chosen.

| Review | Final? | On codex QUOTA / ERROR / TIMEOUT |
|---|---|---|
| `/duet-plan` ordinary round | no | substitute Claude for this round |
| `/duet-plan` lock gate (the round that would lock) | **yes** | `QUOTA` → back off `QUOTA_BACKOFF` up to `QUOTA_MAX_WAITS`, re-running the same prompt file; cap → the "Deadlock at round limit" prompt with a *wait and retry the lock gate* option. `ERROR`/`TIMEOUT` → the round records `DISAGREE`, no lock. Never substitute. |
| `/duet-impl` gates 1..N-1 | no | substitute Claude for this gate |
| `/duet-impl` gate N (embedded `/duet-review`) | **yes** | v0.7.4 behavior: back off and resume; cap → degraded banner |
| standalone `/duet-review` | **yes** | v0.7.4 behavior: back off and resume; cap → degraded banner |

`/duet-plan`'s codex output is **prose**, so it classifies with `koji-codex-classify … --prose` (OK iff exit 0 and a `VERDICT:` line, checked before any quota-marker scan). Without `--prose` a healthy critique that *discusses* quota is labeled `QUOTA` — this happened in the wild.

## Resume semantics

`$RUN_DIR` layout is unchanged from v0.7.x. A run started under an older koji has no `round-N-backend.txt`; a missing backend file means **codex**. `/duet-plan` has no resume feature (`KEEP` only skips Step 5 cleanup) — a crash mid-lock-gate leaves the slot removed and `round-N-claude-critique.md` archived; a re-run starts fresh.

## What does NOT apply to a Claude backend

- **`koji-codex-classify`** — never run it on Claude output. Its `[…]` grab and its substring quota scan over review text (`quota`, `429`, `rate limit`) would turn a review *about* rate-limiting code into a phantom `QUOTA` and an endless back-off. Parse the `Agent` result directly.
- **`TIMEOUT`, `$TO`, exit 124, `.exit` files** — an `Agent` call has no wall clock here. A never-returning reviewer is handled the way `/duet-review` already handles a dead fan-out angle: once everything else is in, treat it as unavailable (fail closed per the malformed rule), never as `[]`.
- **`EFFORT` / `model_reasoning_effort`** — meaningless for Claude. The analogue is `duet.claude_reviewer_model` plus the parent session's `/effort`.
- **`-s read-only`** — no sandbox; the read-only clause + tree fingerprint are the substitute.
