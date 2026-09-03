# koji

AI 程式碼代理的儲存庫內記憶層。如同發酵的麴種——為任何專案植入結構化的工作階段延續性。

AI 程式碼代理會遺忘。每次新對話都從零開始——昨天的決策、修正與細節都不會延續。koji 把專案狀態寫入儲存庫中的純 markdown,讓下個工作階段(以及下一個代理)讀取它,從你中斷處繼續。

十個技能,涵蓋工作階段生命週期、文件漂移追蹤,以及跨模型對抗式規劃/審查。純 bash + markdown,無需建置步驟。

## 安裝

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
```

## 快速開始

```bash
> /koji-init       # 建立 .koji/ 與 TODO.md,詢問 2 個設定問題
> /kick-off        # 開始工作階段(第一次為空白上下文)
... 進行工作、記下筆記 ...
> /wrap            # 寫入工作階段日誌 + 教訓 + 交接,並提議提交
```

隔天:

```bash
> /kick-off        # 讀取上次工作階段 + 交接 + 焦點過濾的教訓
... 代理已掌握昨天的狀態,從你中斷處接續 ...
```

會寫入儲存庫的內容:

```
.koji/                       # 工作階段文件(已提交)
├── agent-session.md
├── AI_HANDOFF.md
├── lessons.md
├── CODEBASE_CONVENTIONS.md
└── sessions/                # 歸檔目錄
TODO.md                      # 任務追蹤
```

## 技能

**工作階段生命週期**

| 技能 | 功能 |
|------|------|
| `/koji-init` | 初始化:在任何專案中建立文件骨架和 `.koji.yaml` |
| `/kick-off` | 開始工作階段:載入交接、教訓、上次紀錄。`/kick-off <焦點>` 指定方向 |
| `/take-note` | 工作階段中途:儲存進度。`/take-note <註記>` 直接使用你的說明 |
| `/wrap` | 結束工作階段:更新教訓 + 交接 + 日誌、歸檔、提議提交 |
| `/inspect-doc-drift` | 掃描帶有 `covers:` frontmatter 的文件,檢查與所覆蓋程式碼的漂移狀況 |

**Duet 工作流程** — 跨模型代理協作。必須使用 `duet` 關鍵字才會觸發;一般的「來規劃一下」或「審查這個」不會觸發這些技能。

| 技能 | 功能 |
|------|------|
| `/duet-plan` | 多輪 Claude↔codex 規劃對話。達成共識後將計畫鎖定到 `$DOCS_PATH/plans/<slug>.md` |
| `/duet-impl` | 依照鎖定的計畫逐關卡實作,並以任務清單追蹤進度。每個 `<!-- gate: NAME -->` 由 codex 單一審查,最後執行 `/duet-review` |
| `/duet-review` | 雙審查者對抗式程式碼審查。Claude + codex 並行**背景執行**——你可以繼續做其他事——意見分歧時交叉審查,高信心修正提示你套用。範圍可為 `base..HEAD`、已暫存(staged)、或未提交的**工作目錄(working tree)** |

所有 duet 技能皆遵循 [代理自主原則](references/agent-autonomy.md):代理之間共同解決技術問題;只有在無法協商或涉及政策選擇時才會詢問使用者。

**Triangulate** — 使用者作為參與者的跨模型決策。

| 技能 | 功能 |
|------|------|
| `/triangulate` | Claude + codex 對同一個問題並行論述,每個聲音可進行網路與程式碼研究。你綜合判斷做出決定。可選擇儲存到 `.koji/plans/` 或 `.koji/research/`,或附加到既有計畫——根據專案目前進行中的項目以對話方式選擇 |

與 `/duet-*` 不同:duet 技能讓 AI 聲音達成共識;`/triangulate` 把**你**保留為第三個參考點與綜合者。

**計畫硬化** — 對鎖定計畫的自主跨模型審查(需要 gstack 與 codex)。

| 技能 | 功能 |
|------|------|
| `/plan-triangulate-review` | 在鎖定的計畫上內聯驅動 gstack 的 `/plan-eng-review`;對每項發現先分流,只有真正有爭議的才跑一輪 Claude↔codex 論述(達成共識即自動鎖定,硬性 3 輪上限),最後以一份勘誤(erratum)批准。設計上保持精簡——不是扇出。需以 `triangulate-review` 意圖叫用(非單獨的 `/triangulate`) |

## 設定

`.koji.yaml` 放在專案根目錄。所有欄位皆為選填。

```yaml
docs_dir: .koji              # 工作階段文件位置
template: default            # "default"（完整）或 "simple"（精簡）
archive:
  strategy: numbered         # "numbered"（archive-NN.md）或 "dated"（YYYY-MM/DD-slug.md）
  threshold: 5               # 達到此數量時歸檔
  keep: 1                    # 保留在活躍檔案中的數量
agents:                      # 工作階段條目的標籤
  - Claude
wrap:
  starter_prompt: true       # 為下個工作階段印出 starter prompt
  prompts: on                # off = /wrap 全程零提示（依其既定的自動策略）
  commit_prompt: on          # 預設跟隨 `prompts`；可單獨保留提交確認
  commit_gate: auto          # auto = 有的話跑 `npm run lint:check` | none | "<指令>"
duet:
  reviewer: codex            # codex | claude | claude-rounds+codex-final
  claude_reviewer_model: inherit   # inherit | fable | opus | sonnet
  codex_effort: xhigh        # xhigh | high（自然語言訊號仍可覆寫）
```

全域偏好設定（`commit_strategy` — `together` | `split` | `amend-if-same-session` — 與 `auto_update`）放在 `~/.config/koji/config.yaml`。

## 重要功能

**焦點過濾的 kick-off 上下文。** `/kick-off` 不會把所有東西都倒出來——它會從 `lessons.md` 拉出一組「廣泛召回」的候選教訓(凡是符合你的 kick-off 參數、上次工作階段的註記,或未完成 TODO 的項目,加上一個最近性基準),再判斷哪些真正與本次工作階段相關,忽略其餘雜訊。相關性的判斷由代理決定,而非 bash 關鍵字評分。可用 `YYYY-MM-DD — [領域1,領域2] — …` 標記項目以加強匹配。

**Load on Kick-Off。** 在 `agent-session.md` 中加入 `## Load on Kick-Off` 區段,列出工作階段開始時要載入上下文的文件。`/wrap` 會提議新增/移除以保持對齊——包含進行中的計畫,會在生命週期內自動加入 LOKO,在完成時自動移除。詳見 [`kick-off/SKILL.md`](kick-off/SKILL.md)。

**文件漂移偵測。** 任何文件都可以用 `covers:` frontmatter 標記它所描述的程式碼路徑。當被覆蓋路徑自文件最後編輯以來的提交數超過閾值時,`/kick-off` 會警告。`/inspect-doc-drift` 會稽核整個專案。完全確定性——不需要 LLM。

**Wrap 自主模式。** `wrap.prompts: off` 讓 `/wrap` 全程零提示跑完，採用它在無法提示時本來就會用的自動策略（新增照做、確定性的移除照做、判斷式移除只在項目已「established」時才動手）。`wrap.commit_gate` 會在 `/wrap` 提交前先跑你的提交閘門——`auto` 會在 `package.json` 有 `npm run lint:check` 時使用它；閘門失敗絕不默默提交，閘門不存在則略過、絕不致命。`commit_strategy: amend-if-same-session` 會把僅含文件的 wrap 併入你自己本工作階段、尚未推送的最後一次提交（`git commit --amend --trailer`，保留原標題），而不是在後面多掛一個 `docs(koji)` 提交。

**Duet 工作流程。** 不會卡住使用者的跨模型代理協作。`/duet-plan` 執行多輪 Claude↔codex 對話直到共識,鎖定計畫。`/duet-impl` 依關卡逐步走過計畫,每關 codex 審查,接著針對鎖定計畫中每一項明確承諾稽核累積 diff——這是與品質審查不同的契約驗證。`/duet-review` 進行雙審查者對抗式檢查,對於審查者間任何 medium/high 不一致皆觸發嚴重程度感知的交叉審查;硬性閘門、`-PRELIMINARY` 後綴,加上由 `/duet-impl` 內聯驅動時的呼叫端事後檢查,確保交叉審查不會被悄悄略過。三個技能皆以背景任務執行審查者——進行中你可以繼續工作。codex 預設使用 `xhigh` 推理強度;在叫用語句中用自然語言訊號可降回 high。`/duet-review` 的 Claude 端也會隨功夫調整深度：在 `/effort max`（或明確說「完整審查」、「扇出」、「深度審查」）時，會扇出成五個角度審查者（正確性、移除行為、跨檔呼叫、重用簡化、設計高度），由主代理綜整成單一發現集；較低功夫則跑單次整體審查，而說「快一點」、「省 token」即使在 max 下也會強制單次。

**審查者後端。** `duet.reviewer` 決定 duet 技能的對抗聲音：`codex`（預設）、`claude`，或 `claude-rounds+codex-final`。`claude` 會以一個全新上下文的 Claude 子代理——絕不是撰寫端工作階段的 fork——擔任審查者。它是配額耗盡時的逃生口，訊號也較弱：兩邊是同一個模型家族，所以「共識」代表兩個獨立上下文同意，而非兩家廠商。混合模式由 Claude 審查每一輪，每次嘗試鎖定花一次 codex 呼叫來把關——順利的情況下正好一次。配額規則：當 codex 在「非最終」的審查上撞到配額（或無法啟動）時，koji 會為該次審查改用全新上下文的 Claude 審查者，下一次再試 codex；只有最終審查會等 codex。

**程式碼契合（codebase fit）。** duet 技能會讓新程式碼契合「這個專案」既有的慣例——檔案結構、命名、慣用寫法、分層——而不只看正確性。`/duet-plan` 會在每份計畫中寫入一段 Codebase Fit Contract,`/duet-impl` 的關卡審查與 `/duet-review` 都帶有 `codebase-fit` 審查視角。共用的參考是 koji 文件目錄中的 `CODEBASE_CONVENTIONS.md`:一個中樞,它透過 `sources:` 清單「指向」（而非複製）專案自己的慣例文件——`CONTRIBUTING.md`、`AGENTS.md`、`.cursorrules`、`STYLE.md`——並從審查實際抓到的問題逐步累積標準範例索引與「已否決模式」紀錄。`/koji-init` 為新專案建立它,`/kick-off` 則把它回填到既有專案。

**死碼掃描(dead-code sweep)。** `/duet-review` 與 `/duet-impl` 的關卡審查者會主動標出 diff 讓哪些程式碼路徑變得不可達(`deadcode` finding)——被取代的 helper、結構上已死的分支、永遠不會進入的 match arm。內建例外處理:測試 scaffolding、生成程式碼、以及前向相容/遷移橋接程式碼會被略過,讓「加新路徑、保留舊路徑」的基底搭建階段順利通過。`/duet-impl` 的執行末段報告也會在 promise 稽核旁顯示一個程式碼增刪比(例如 `+2310 / −267 (ratio 8.6:1)`)——基底搭建 vs 重構的元訊號,搭配 deadcode 發現一起判讀。

**三角化(`/triangulate`)。** 當你想要多方論述但希望由「你」當綜合者(而不是讓代理收斂)時:Claude + codex 並行針對單一問題論述,各自可進行網路研究,呈現立場,你權衡與決定。可選擇儲存到 `.koji/plans/` 或 `.koji/research/`,或將綜合段落附加到既有計畫——根據專案目前進行中的項目以對話方式選擇。若要對「鎖定的」計畫做*自主*的逐項硬化,這個迴圈現在已成為獨立技能——**`/plan-triangulate-review`**(見下);單獨的 `/triangulate` 維持為純粹的單一問題引擎。

**計畫硬化(`/plan-triangulate-review`)。** 對「鎖定的」計畫做自主、精簡的跨模型硬化。內聯驅動 gstack 的 `/plan-eng-review`;對每項發現先分流——大多數只需讀原始碼就能反駁或記錄,只有真正有爭議的才進入論述(Claude↔codex,達成共識即自動鎖定,硬性 3 輪上限)。最後以一份勘誤批准已鎖定的決定、跨模型讓步與仍有分歧的項目。需以 `triangulate-review` 意圖叫用(非單獨的 `/triangulate`);需要 gstack 與 codex。參考執行在 4 次模型呼叫內硬化了一份鎖定的 ADR——是分流迴圈,不是扇出。

**離線(walk-away)工作階段。** `/duet-plan`、`/duet-impl` 與 `/plan-triangulate-review` 會在背景 AI 任務執行期間讓機器保持喚醒(`caffeinate` / `systemd-inhibit`),並在結束時釋放,讓你能啟動一段長時間執行後離開。(單獨的 `/triangulate` 是互動式的——它把每個決定交給你——因此跟 `/duet-review` 一樣略過喚醒。)僅這些流程採用(絕不包含一般的 `/kick-off`);採用引用計數,重疊執行共用同一個喚醒程序,且具擁有權安全:絕不會關閉你自己啟動的喚醒程序。`/duet-impl` 天生就適合無人值守:遇到卡住的關卡絕不凍結。某個關卡在用盡重試後仍無法通過時,會被記錄成 `deferred-findings.md` 中的延後項目——待你回來時一次全部呈現——並繼續往下走,而不是卡在彈窗提示上。而 codex 的配額回覆或啟動失敗也絕不會被誤讀為「零發現→通過」:最後一關之前的關卡會改用全新上下文的 Claude 審查者繼續往下走,只有最終的 `/duet-review` 關卡會退避（約 15 分鐘）並在 codex 的 5 小時視窗內恢復——配額耗盡只會讓流程變慢,絕不會默默記下一次不實的通過審查。

**計畫與研究工作文件。** `.koji/plans/`(已決定、待實作的工作)與 `.koji/research/`(調查發現,待驗證)。研究檔案以主題為定址單位——新發現會累積進現有主題檔案(`## Decisions` 段落由新到舊),而不是另開以工作階段命名的平行檔案。輕量的 YAML frontmatter(`status:` 欄位,依類型而定:plans 為 pending/in-progress/completed/archived,research 為 unvalidated/validated/archived)。`/kick-off` 會在工作階段開始時列出待辦項目;`/duet-impl` 會在執行結束時將計畫標記為 `completed`;`koji-plans-research --set-status <path> <new>` 可從命令列修改,`--set-next-step <path> "<text>"` 則改寫 `next-step:` 那一行;只要本工作階段動到某個進行中的計畫,`/wrap` 就會重新確認它的 `next-step`。漂移豁免(不是程式碼覆蓋文件)。

## 更詳細的文件

README 刻意保持簡短。詳細內容在各 SKILL.md 中:
- [`kick-off/SKILL.md`](kick-off/SKILL.md)、[`wrap/SKILL.md`](wrap/SKILL.md)、[`take-note/SKILL.md`](take-note/SKILL.md)、[`koji-init/SKILL.md`](koji-init/SKILL.md)、[`inspect-doc-drift/SKILL.md`](inspect-doc-drift/SKILL.md)
- [`duet-plan/SKILL.md`](duet-plan/SKILL.md)、[`duet-impl/SKILL.md`](duet-impl/SKILL.md)、[`duet-review/SKILL.md`](duet-review/SKILL.md)
- [`triangulate/SKILL.md`](triangulate/SKILL.md) — Claude + codex + 你 = 一個決策的三個參考點
- [`plan-triangulate-review/SKILL.md`](plan-triangulate-review/SKILL.md) — 對鎖定計畫的自主逐項硬化(驅動 `/plan-eng-review` + 逐項論述)
- [`references/agent-autonomy.md`](references/agent-autonomy.md) — duet 技能共用的自主原則
- [`references/reviewer-backend.md`](references/reviewer-backend.md) — 審查者後端對應表、唯讀條款、配額規則
- [`tests/run.sh`](tests/run.sh) — bash 輔助腳本的 fixture 測試器（`tests/run.sh [case]`）;不是安裝閘門

## 常見問題

**工作階段文件存放在哪裡?** 在每個專案的 `.koji/` 目錄中,提交到 git。`~/.config/koji/` 只儲存全域偏好設定。

**為什麼 `/kick-off` 會問我 bypass 金鑰的事?** 舊版 `/koji-init` 曾把 `permissions.defaultMode: bypassPermissions` 寫進 `.claude/settings.local.json`。自 Claude Code 2.1.257 起,這個鍵在專案層級已無效,所以 `/kick-off` 會提議移除它,而 `/wrap` 的權限整理現在改從使用者與受管設定讀取實際生效的模式。koji 絕不會寫入 `~/.claude/settings.json`。

**`/koji-init` 會覆蓋現有文件嗎?** 不會。若在 `docs/` 找到現有工作階段檔案,koji 會詢問要遷移還是保留原處。內容會被保留。

**與 gstack 衝突嗎?** 不會。技能名稱不同,設計為共存。

**會回傳資料嗎?** 沒有遙測,沒有分析。所有工作階段資料留在你的儲存庫中。

## 支援

- **Claude Code**（主要目標)
- 任何能讀取 markdown 技能檔案的 AI 代理

## 授權

MIT
