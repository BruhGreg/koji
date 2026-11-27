# Reviewer Backend (duet skills)

Shared by `/duet-plan`, `/duet-impl`, `/duet-review` (and, for the outside-voice section, `/triangulate` and `/plan-triangulate-review`). Who reviews, at what effort, on which Claude model, is decided **at the start of every duet run** — one question, remembered — not in `.koji.yaml`. This file holds the parts that must not diverge across the skills: the setup tuple and its helpers, the resolution order, the dialog, the strategies, the outside voice, the agent definitions, the mapping table, the read-only clause, the slot rule, the malformed-reply rule, and the quota rule.

**`codex` in this file names a ROLE, not a CLI.** Strategy tokens (`codex`, `claude-then-codex`), records (`codex-quota-substituted`, `+codex-final`, `claude+codex-confirm`), slot files (`codex.json`, `round-N-codex.md`) and `CODEX_*` variables all mean *the outside voice* — a non-Claude model family. Since 0.11.0 two CLIs fill that role, **agy first, codex second** (see "The outside voice"). The tokens stay stable so saved setups and in-flight runs keep working; the provider record says which CLI really answered.

## The setup tuple

One string, four `|`-joined fields: `STRATEGY|CODEX_EFFORT|CLAUDE_EFFORT|CLAUDE_MODEL`, e.g. `both|max|max|inherit`.

| Field | Values | Default |
|---|---|---|
| `STRATEGY` | `both` · `claude-then-codex` · `codex` · `claude` | `codex` |
| `CODEX_EFFORT` | `max` · `xhigh` · `high` — the **outside voice's** effort: codex's `model_reasoning_effort`, agy's `--effort` (clamped to what the model offers) | `xhigh` |
| `CLAUDE_EFFORT` | `max` · `xhigh` · `high` · `inherit` — selects the reviewer agent definition (below) | `xhigh` |
| `CLAUDE_MODEL` | `inherit` · `fable` · `opus` · `sonnet` — the Agent tool's `model` param; `inherit` = omit it | `inherit` |

The run's copy lives at **`$RUN_DIR/duet-setup`** (one line). Every Bash block that needs a field reads it from there through the helper — never from a remembered shell variable, since each block is a fresh shell. The last pick lives globally at `koji-config get duet_setup` (`~/.config/koji/config.yaml`): budget is per user, not per project.

### Helpers

- **`koji-duet-setup`** — the only place tuple syntax is known. `validate <tuple>` (normalized tuple on stdout, exit 1 + reason on stderr), `defaults`, `merge <base> <overlay>` (overlay field wins when non-empty), `summary <tuple>` (one human line: `both families · outside max · claude max/inherit`), `field <tuple> <1-4>`. Every tuple source — saved pick, embedded phrase, user phrase, dialog answer — passes `validate` before it is written anywhere.
- **`koji-duet-backend <plan-round|impl-gate|review-b> "$RUN_DIR/duet-setup"`** — the mapping table (below). The file is authoritative: missing or invalid → exit 3, nothing on stdout, `run state lost` on stderr. Callers `|| exit 1`. Never default to codex on a lost file — that would silently turn a `both` run into a weaker review. Two more contexts resolve the outside-voice **provider**: `provider <record>` and `b-provider "$RUN_DIR"` (see "Provider resolver").
- **`koji-tree-snapshot capture|same <record>` · `stale "$RUN_DIR"`** — binds a review to one git tree object (see "Snapshot integrity"). It stages into a temporary copy of the index, so it never touches your staging or `.git/index.lock`; `/duet-impl`'s gates and its embedded final review use it.
- **`koji-duet-findings-check [--cross|--consult] <file>`** — exit 0 iff the file is a validated array (see "Malformed reply").

## Resolution order (Step 1 of each duet skill)

1. **Baseline** = `koji-config get duet_setup` if it validates, else `koji-duet-setup defaults`. An invalid saved pick is ignored with one stderr line.
2. **Phrase overlay** — koji reads intent, not flags. Fields the invocation phrase states ("with both reviewers", "outside at max", "claude reviewer on sonnet", "quick gates") form an overlay with empty unspecified fields; `EFFECTIVE=$(koji-duet-setup merge BASELINE OVERLAY)`. An effort stated once applies to both families unless the phrase splits it. A phrase that names a **provider** ("use codex", "codex first", "agy only") is not a tuple field: it sets the global `outside_order` (see "The outside voice"), and the reply says so.
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

1. *Strategy* (this order): **Both families every time** — most calls, strongest signal; impl gates cross-review what the two disagree on, plan rounds hand the drafter both critiques · **Claude reviews, outside voice confirms** — cheap rounds; one outside-voice call gates each lock or pass · **Outside voice only** — the default · **Claude only** — no outside voice; same-model caveat. (Tokens: `both`, `claude-then-codex`, `codex`, `claude`.) Which CLI is the outside voice is not a dialog question: it is `outside_order` (agy → codex), printed by the preflight.
2. *Effort, both families*: **max** / **xhigh** / **high**. The auto-added "Other" field accepts a split ("codex max, claude high") → mapped onto the two effort fields → `validate`.
3. *Claude reviewer model*: **inherit** / **fable** / **opus** / **sonnet**.

**Standalone `/duet-review`:** Reviewer A is always Claude and Reviewer B is the outside voice under every strategy but `claude`, so three of the four strategies are one behaviour there. Its first question is therefore *Reviewer B*: **outside voice (agy → codex)** / **Claude (same-model, quota escape hatch)**. Choosing Claude sets `STRATEGY=claude`; choosing the outside voice **keeps** a saved `both` / `claude-then-codex` strategy as-is (they already mean the outside voice here) and sets `codex` only when the saved strategy was `claude` — a review-time answer never silently erases the strategy a later `/duet-impl` will reuse. Effort and model as above. A saved `both` or `claude-then-codex` pick is shown in the Reuse line as "Reviewer B: outside voice".

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

## The outside voice — agy first, codex second

Two CLIs fill the outside-voice role at the same level: **agy** (Google Antigravity CLI) and **codex** (OpenAI). Both are a model family that is not Claude.

**Order.** `koji-config get outside_order`, default `agy,codex`, read at every dispatch (no state crosses a fresh shell) and printed by `koji-outside-preflight` at every run start. A phrase that names a provider ("use codex", "codex first", "agy only") sets it — `~/.claude/skills/koji/bin/koji-config set outside_order codex,agy`, or one provider alone (`codex`) — and the reply says so in one line: the order is a global preference, so it also holds for later runs until it is changed. A stray word is ignored with a warning and the valid providers are kept (`codex,gemini` → `codex`; the preflight's own `codex → agy` → `codex agy`); only a value with no valid provider falls back to the default. Phrases that set strategy or effort ("with both reviewers", "outside at max") still map onto the duet tuple; field 2 is the effort for whichever provider runs.

**One dispatch.** Every outside-voice call site runs the same line; only `X`, the kind and the prompt differ:

```bash
~/.claude/skills/koji/bin/koji-outside-exec "$TIMEOUT" "$EFFORT" "$PROJECT_ROOT" "$X.provider" --expect <kind> \
  < "$PROMPT_TXT" > "$X.raw" 2> "$X.err"
CE=$?; echo "$CE" > "$X.exit"
```

`--expect` is the site's output contract: `findings` (gate and review arrays), `cross` (cross-review verdicts), `consult` (consult replies), `verdict` (prose ending in a `VERDICT:` line: `/duet-plan` critiques and `/plan-triangulate-review` votes), `prose` (`/triangulate` positions). The wrapper checks each provider's reply with the same helpers the collection site uses. A reply that is empty, in the wrong shape, an error, a quota or a timeout sends the **same prompt** to the next provider — so the call site's own malformed-reply retry runs only when every provider failed, and it re-runs the whole order once.

**The provider record**, `$X.provider`, is always written. Line 1 is `<agy|codex|none> <effort|-> — <attempt summary>`, plus the model in brackets when the provider names one (`agy xhigh — ok (gemini-4-neon)`); the lines after it are notes (the effort clamp, a `⚠` tree change, a provider that is not installed or tried last). Each attempt's raw reply and stderr stay next to it as `$X.provider.<n>.<provider>.out` / `.err`, numbered per dispatch, so a retry never overwrites the reply that explains it. Every collection prints it: `sed 's/^/outside voice: /' "$X.provider"`. A decision — a `--b-backend` label, the consult's pinned provider — reads it through `koji-duet-backend provider` / `b-provider`, never an inline copy (`koji-selfcheck` forbids `read -r B_BACKEND _`). A display label may read line 1 with `read -r P _ < "$X.provider"` — never `awk '{print $1}'`, which the skill renderer strips to `'{print }'`.

**Provider resolver** — one helper, never an inline copy: `koji-duet-backend b-provider "$RUN_DIR"` for `--b-backend` and the Step 6 reports, `koji-duet-backend provider <record>` for one record (the `/duet-impl` merge and consult). `b-provider` precedence: the run's `duet-setup` must validate (else exit 3 — run state lost); `codex.unavailable` exists → `none` (a degraded run); role `claude` → `claude`; otherwise `provider "$RUN_DIR/codex.provider"`. `provider`: no record at all (a run started before 0.11.0) → `codex`; an empty or unknown token → `none`, with a warning — a record that proves no provider is never read as one.

**Exit codes**, beyond 78/79/124/125 below: **75** — a provider ran (or was skipped) but gave no usable reply; **127** — no outside voice is installed, record `none`. Both classify as `ERROR`; neither is ever `[]`. When every provider failed, the call site gets the LAST attempt's stdout, stderr and exit code, plus one `koji-outside: <p> failed: <reason>` line per attempt when that exit is non-zero (or the site is `prose`, which then exits 75), so an earlier provider's quota still classifies as `QUOTA` and a final review waits instead of degrading. `verdict` and `prose` sites classify a failed reply in `--prose` mode: a short refusal at exit 0 (`Error [429]: …`) is a `quota`, never a shape mismatch, and a prose site never shows it as a position.

**Timeout breaker.** A provider that timed out (124) leaves `.outside-timeout-<provider>` in the record's directory, and every later dispatch of that run **skips** it, with a note. `--only` still runs it (consult ownership), and a usable reply from it clears the file. When every provider left in the order is skipped, the wrapper exits 124 (record `none - — skipped: …`), so the call site degrades or substitutes at once. What it saves: each attempt has the full `$TIMEOUT` (900 s at `high`, 1800 s at `xhigh`/`max`), and a final review's quota back-off cycle (`QUOTA_BACKOFF`, 900 s) walks the order again. Only moving the hung provider last was not enough: with the other provider out of quota, every back-off cycle re-ran it for its full deadline.

**Fallback is not substitution.** Moving to the next provider inside one call shows in the record, is never written as `*-substituted`, and never counts toward `QUOTA_MAX_WAITS`. Claude substitution (non-final reviews) and back-off (final reviews) apply only to the wrapper's final state, after every provider in the order was tried.

**Consult ownership.** `/duet-impl`'s consult asks a reviewer to WITHDRAW or RECONFIRM its own HIGHs, so only the provider that raised them may withdraw them. The consult leg pins it: `--only "$P"`, with `P=$(koji-duet-backend provider <that attempt's provider record>)`. If that provider cannot answer, the reply fails and every HIGH is reconfirmed — the existing fail-closed rule. Under `both`, a HIGH the outside voice endorsed through the **cross leg** goes to `$P` only when the cross-leg record names the same provider; otherwise it is reconfirmed with no dispatch. When no HIGH is left to ask, the consult is not dispatched at all. Cross-review legs evaluate the *other* reviewer's findings, so they use the normal order and keep their own record (`codex.cross.provider`).

**agy specifics** (`bin/koji-agy-exec`; measured on agy 1.5.18):

- The prompt goes in as one stream-json message on stdin; `-p "<text>"` is argv-only.
- **Prompt size:** agy cuts one prompt at about 190 KB — the model gets the first part and `<truncated N bytes>`; a 157 KB prompt arrived whole. Above `KOJI_AGY_MAX_PROMPT` (default 160000 UTF-8 bytes of the composed prompt, measured before JSON escaping, which would double CJK text) koji **hands the prompt over as a file**: the caller's whole prompt goes to `.git/koji-agy.XXXXXX/task.md` in the repository, agy gets a short prompt that points at it, and the file is removed when the adapter exits. `.git` is inside agy's reading boundary (the repo; `allowNonWorkspaceAccess` is off) and invisible to `git status`, the tree fingerprint and the snapshot. A linked worktree or a submodule has a `.git` *file*: there agy is skipped (exit 75, a note), and the next provider answers. Plain stderr lines carry no byte counts, because the classifier reads them and a size like 164290 must never look like an HTTP 429.
- **Bypass is an explicit, global opt-in:** `koji-config set agy_bypass yes`. Only `yes` counts, and `koji-outside-preflight` and `setup` print the state. It is off by default because a review carries untrusted text — a PR diff, a web page — and the deny rules do not see `$(...)` or redirects.
  - **Off (the default).** No `--dangerously-skip-permissions`. One `--settings` object (agy accepts only one) pins `agentMode: ""` — agy's `default` mode; headless agy otherwise runs `auto`, which approves edits — plus `toolPermission: request-review` and `allowNonWorkspaceAccess: false`, next to the deny list. The guard clause says shell commands and web tools are not available, and asks for the exact reply `KOJI-NEEDS-TOOLS` when the task cannot be done with file reading and search alone. agy then reads files only. That sentinel, or any action that needs approval (which ends the run with an empty reply), is exit 75, and the next provider answers — so `/triangulate`, which asks for web research, gets codex. (Live, without the sentinel, agy answered a web-research prompt with a polite "I cannot complete this task", which a prose site would have shown as a position.) After the run koji checks that agy really stayed read-only: `init.permission_mode` must be `request-review` (it reports the `toolPermission` preset), and every completed tool step must be a tool that cannot change the repository or the machine (`read_file`, `view_file`, `grep_search`, `find_by_name`, `list_dir`, `manage_task`, `finish`, `wait`, `command_status`, `list_permissions`, `list_resources`, `read_resource`; live, a file read reports `read_file`). Otherwise the reply is discarded (75) with a `⚠` note. The second check is what catches a future agy that ignores `agentMode: ""`, allow rules from agy's own permission scopes, and subagents.
  - **Live, bypass off:** a file-reading review answered (exit 0; `permission_mode` `request-review`; the one completed step was `read_file`), and a web-research prompt gave `KOJI-NEEDS-TOOLS` (exit 75, so codex answers). The repository was unchanged.
  - **On.** agy may run shell tools, guarded by the session-only deny rules below and by a task-neutral guard clause that names what is blocked. A deny hit is a tool error the model works around, not a lost reply.
  - **How agy matches a rule** (live-probed on 1.5.18; the CLI docs do not say). Each part of a chain is checked on its own. `command(x y)` matches when the command's first words are exactly `x y`. `command(regex:A B)` matches word by word from the start: each space-separated piece is a whole-word pattern, more words may follow, and a rule never matches in the middle of a command. agy reads the rule text like a shell line: it drops a backslash (`\s` becomes `s`), a quote breaks the rule, and a `>` is dropped — so `.*>.*` matches every command. koji's rules therefore contain no backslash, quote or `>` (`[.]` is a literal dot), and the table test enforces it. The first 0.11.0 list broke all three; in a live test it blocked nothing.
  - **What the rules block:** file-writing tools; file-changing commands; programs run by a path (`./script`, `bin/x`); wrappers (`nohup`, `sudo`, `timeout`, `env`, `xargs` and similar); shells and interpreters, `awk` included; package managers, build and test tools; `curl`, `wget` and other network tools (agy has its own web tools); browser actions; MCP tools; state-changing git, including ref changes (`branch`/`tag` create, delete or move, `reflog expire`, `symbolic-ref`, `notes`, `replace`, `filter-branch`), `git -C`, `-c`, `--git-dir` and `git --no-pager <write>`; and `sed -i`, `sort -o`, `find -delete`/`-exec` at their common flag positions.
  - **Live table, bypass on** (real agy, the exact rule set, a scratch repo). Blocked: `./script.sh`, `bin/tool.sh`, `git branch -D x`, `git branch newbr`, `git tag v9`, `git commit`, `git --no-pager commit`, `git -P commit`, `git --no-pager branch -D y`, `git -C . commit`, `curl -d @f`, `sed -i.bak`, `sed -n -i`, `sort -o`, `awk`, `touch`, `git log && touch`, `find -delete` — HEAD, branches, tags and files unchanged. Ran, as they should: `git log`, `git branch -a`, `git branch --contains`, `git tag -l`, `git status`, `grep -c 'a<b>'`, `sed -n 1,2p`, `find -name`, `sort`, `cat | head`, `git --no-pager log`, `grep -rn`, `ls -la`.
  - **What it does not cover:** shell redirects (`echo x > f`, `>>`, `&>` — a rule cannot see them, so the guard clause asks the model not to write, and they ran in the live table); commands that use `$(...)`, backticks or similar (agy checks those against the whole line only — `echo $(touch f)` ran); flags past the spelled-out positions; and effects outside the repository or in ignored paths, which the snapshot check below cannot see either. It guards against accidents, not an adversary; an OS-level write sandbox is the follow-up.
- **Model rule:** only plain `gemini-<n>…` model ids pass — agy also serves Claude and GPT models, and the outside voice must never be Claude. A failed `/model` lookup skips agy rather than run an unpinned model.
- **Effort clamp:** koji's `max|xhigh|high` becomes the highest level the model offers at or below it — or, when it offers none that low, the lowest level above it, never silently the most expensive tier — with a note (`agy runs gemini-4-neon at xhigh — max is not offered by gemini-4-neon`). The effort never fails a run. The lookups read the last JSON object that carries `command`, so an update banner or pretty-printed JSON cannot read as "no model".
- **An empty reply is never a reply:** `SUCCESS` with a blank response (antigravity-cli#650) is exit 75.
- **Quota wording:** agy's own (`RESOURCE_EXHAUSTED`, `exhausted your capacity`, `rate-limit`, 429), read from the result's error and agy's stderr, becomes one `koji-agy-exec: agy quota exhausted: …` line, which the classifier's `quota` marker reads. The match is word-bounded, so a `RateLimiter` stack frame is not a quota; the shared classifier list stays phrase-only, because it also reads review text.

**Snapshot integrity.** A gate passes only on the tree it reviewed. `/duet-impl` binds each gate attempt to a git **tree object**: `koji-tree-snapshot capture` stages everything into a temporary copy of the index (yours, and its lock, are untouched), writes it as a tree and records `<tree> <HEAD>`; the attempt's diff is built from that object. At PASS, `koji-tree-snapshot same` computes the tree the same way and compares. A mismatch — or no record — is not a PASS: print the `⚠`, start a new attempt from a fresh diff, defer at the attempt cap. The PASS snapshot commits the reviewed tree object, never a fresh restage. This holds for every backend, Claude included.

Files marked `assume-unchanged` or `skip-worktree`, like ignored files, are outside the frozen tree, as they are outside `git add -A` — an edit to one during a review is not seen. Clearing the bits in the temporary index would instead leak those hidden local edits into diffs sent to the outside voice. A capture that cannot work at all (an unreadable file, a nested repository with no commit) prints git's reason and fails fast: `/duet-impl` probes once in Step 1, a gate whose capture fails twice dispatches no review (deferral `reviewed tree not recorded`), and Step 3b stops before the final review.

The final review gets the same binding. Run embedded (`EMBEDDED=1`), `/duet-review` captures `review.tree` in Step 1 and diffs from it; before each synthesizer call (Step 3, 4a-bis, 4c) `koji-tree-snapshot stale "$RUN_DIR"` compares again. A capture that fails stops the review before any reviewer starts. A moved tree **latches** `snapshot.stale` — it is never cleared — and `koji-duet-synthesize --snapshot-stale` forces `REJECT` with `snapshot_stale: true`; Step 5 applies nothing. `/duet-impl` backs this up from the caller's side: Step 3b freezes `final.tree`, and Step 3b-gate blocks a passing verdict whose tree moved (it catches an embedded review that was not bound). A standalone `/duet-review` does not bind a tree: it prints the `⚠` in its banner (the user may edit during a review); `/duet-plan` only warns. `koji-agy-exec` also fingerprints around its own attempt (`koji-tree-fingerprint --state`) and notes a change in the record — a diagnostic, not the guarantee.

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

Every array bound for a slot is checked with `koji-duet-findings-check` (default schema for findings; `--cross` for cross-review verdicts; `--consult` for consult replies). An outside-voice reply (agy or codex — `koji-outside-exec` already checked it against `--expect`) goes through `koji-codex-classify` first: any state other than `OK` → `rm -f` the slot (the classifier writes `[]` on `EMPTY`), and the quota rule below applies; on `OK` the extracted array is checked. A Claude reply is extracted from the Agent result and checked directly.

A failed check — no array, not a list, an entry without a valid severity, a verdict outside the label set — is a **malformed reply**: re-dispatch the same call once with the reminder *"Your last response was not a JSON array of the requested shape — re-output ONLY the array, `[]` if none."* (`/duet-plan`: *"…missing the VERDICT line — re-output the same critique with the marker appended."*). A second failure makes that reviewer **unavailable**. Never write `[]` for a reply you could not validate — `[]` means "reviewed, found nothing", and downstream reads it as PASS:

- `/duet-impl` gate → that family is unavailable for the attempt: single-family strategies record a deferral (`reviewer unavailable — malformed reply ×2`) and proceed to the next gate; `both` continues on the other family alone (record `both:claude-only` / `both:codex-only`) or, with neither, records the deferral.
- `/duet-review` B → `CODEX_UNAVAILABLE=1` (the degraded path); the `[]` written to the slot there is the degraded-run placeholder the Step 6 banner declares, not a finding count. Reviewer A angles → `[]` for that angle with a note (a fan-out degrades, never hangs).
- `/duet-plan` → the round records `VERDICT: DISAGREE: reviewer returned no VERDICT after retry` (cannot lock) and the deadlock prompt is surfaced.

## Harness mismatch — terminal, and the one failure substitution may NOT cover

`koji-outside-preflight` runs in every outside-voice skill's preamble — for every strategy, `claude` included — and exits
**78** when this session itself runs inside another agent's harness: `CODEX_THREAD_ID` or `CODEX_SANDBOX` (codex),
`ANTIGRAVITY_CONVERSATION_ID` or `ANTIGRAVITY_TRAJECTORY_ID` (an agy agent). It is checked at preamble time, before
any dispatch, because those are environment variables and therefore survive the fresh-shell boundary that a
`koji-detect` assignment would not. The list lives once, in `bin/koji-dispatch-lib`, shared by the preflight,
`koji-outside-exec` (before it looks at any provider) and both adapters, so the copies cannot drift.

78 is **not** a reviewer failure and the quota/error rule below does **not** apply to it. Inside another agent's
harness, Reviewer A — and every "fresh Claude" stand-in — is that agent's model, so any review the run produces is
the same family grading itself: precisely the two-placeholders-into-a-PASS outcome koji forbids. The run stops and
reports *"outside review unavailable: harness mismatch; no outside process started. Missing coverage."* There is no
escape hatch, by design. (Untested residual: whether the Antigravity IDE's own terminal sets the agent-session
variables. koji guards only the conversation/trajectory ids, not the IDE's `ANTIGRAVITY_LS_*`.)

A failed Bash block does not halt the agent, so stopping is the agent's job;
each skill carries that instruction in prose and `koji-selfcheck` pins it.

`koji-outside-exec` and the adapters re-check and return 78 as well, so a call site that somehow
bypassed the preamble still fails closed rather than dispatching.

### Exit 79 — the dispatch block is malformed

`koji-outside-exec` (and each adapter) returns **79** when the CALLER is wrong: an unrestored
`$TIMEOUT` or `$EFFORT`, an effort outside `max|xhigh|high`, a project root that
is not a directory, a missing provider record argument or one in a directory that does not exist, a missing or unknown
`--expect` value, an unknown `--only` value, or a prompt that is empty, unreadable or never EOFs. No call is made.

Like 78, it is **intercepted before `koji-codex-classify` at every collection
site — first pass and cross leg alike** — and it is never substituted: nothing
about a broken block is fixed by asking a different reviewer. The fix is the
block.

79 rather than 2 is deliberate. `codex exec --<bad-flag>` exits 2, and
`koji-timeout` exits 2 for a bad duration and **125** when the supervisor itself
cannot start. Carrying this meaning on 2 would let a codex flag rename, or a
full temp dir, hard-stop every run with the wrong diagnosis; on their own codes
they classify as `ERROR` and degrade the way any reviewer failure does.

## Quota / error rule — substitute on non-final reviews, wait on the final one

An outside-voice `QUOTA`, `ERROR` or `TIMEOUT` (from `koji-codex-classify`, on the wrapper's FINAL state — after every provider in `outside_order` was tried) on a **non-final** review is re-run **immediately** by the Claude backend with the same prompt, a visible `⚠`, and the round/gate backend file overwritten with `codex-quota-substituted` / `codex-error-substituted`. Substitution is per-review, not a mode switch: the **next** review tries the whole order again (a 5-hour window may have restored). A lock therefore always carries an outside-voice verdict unless the strategy is `claude`. Each back-off on a final review re-runs the whole order, so a final review waits only when no provider can answer.

| Review | Final? | On outside-voice QUOTA / ERROR / TIMEOUT |
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
- **`TIMEOUT`, exit 124, `.exit` files** — an `Agent` call has no wall clock here. A never-returning reviewer produces no wake-up of its own; it is declared unavailable when the orchestrator next acts (another notification, or the user's next message) with everything else in — fail closed per the malformed rule, never `[]`.
- **`model_reasoning_effort`** — codex's knob. Claude's effort is the agent definition (`koji-reviewer-<effort>`), plus the parent session's `/effort` under `inherit`.
- **`-s read-only`** — no sandbox; the read-only clause + tree fingerprint are the substitute.
