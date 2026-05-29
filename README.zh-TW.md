# koji

AI 程式碼代理的儲存庫內記憶層。如同發酵的麴種——為任何專案植入結構化的工作階段延續性。

AI 程式碼代理會遺忘。每次新對話都從零開始——昨天的決策、修正與細節都不會延續。koji 把專案狀態寫入儲存庫中的純 markdown,讓下個工作階段(以及下一個代理)讀取它,從你中斷處繼續。

九個技能,涵蓋工作階段生命週期、文件漂移追蹤,以及跨模型對抗式規劃/審查。純 bash + markdown,無需建置步驟。

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
| `/duet-review` | 雙審查者對抗式程式碼審查。Claude + codex 並行**背景執行**——你可以繼續做其他事——意見分歧時交叉審查,高信心修正提示你套用 |

所有 duet 技能皆遵循 [代理自主原則](references/agent-autonomy.md):代理之間共同解決技術問題;只有在無法協商或涉及政策選擇時才會詢問使用者。

**Triangulate** — 使用者作為參與者的跨模型決策。

| 技能 | 功能 |
|------|------|
| `/triangulate` | Claude + codex 對同一個問題並行論述,每個聲音可進行網路與程式碼研究。你綜合判斷做出決定。可選擇儲存到 `.koji/plans/` 或 `.koji/research/`,或附加到既有計畫——根據專案目前進行中的項目以對話方式選擇 |

與 `/duet-*` 不同:duet 技能讓 AI 聲音達成共識;`/triangulate` 把**你**保留為第三個參考點與綜合者。

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
```

全域偏好設定（`commit_strategy`、`auto_update`）放在 `~/.config/koji/config.yaml`。

## 重要功能

**焦點過濾的 kick-off 上下文。** `/kick-off` 不會把所有東西都倒出來——它會根據你的 kick-off 參數、上次工作階段的註記、未完成的 TODO 項目,以及前 3 名最近性基準,載入 `lessons.md` 的焦點過濾子集。可用 `YYYY-MM-DD — [領域1,領域2] — …` 標記項目以加強匹配。

**Load on Kick-Off。** 在 `agent-session.md` 中加入 `## Load on Kick-Off` 區段,列出工作階段開始時要載入上下文的文件。`/wrap` 會提議新增/移除以保持對齊——包含進行中的計畫,會在生命週期內自動加入 LOKO,在完成時自動移除。詳見 [`kick-off/SKILL.md`](kick-off/SKILL.md)。

**文件漂移偵測。** 任何文件都可以用 `covers:` frontmatter 標記它所描述的程式碼路徑。當被覆蓋路徑自文件最後編輯以來的提交數超過閾值時,`/kick-off` 會警告。`/inspect-doc-drift` 會稽核整個專案。完全確定性——不需要 LLM。

**Duet 工作流程。** 不會卡住使用者的跨模型代理協作。`/duet-plan` 執行多輪 Claude↔codex 對話直到共識,鎖定計畫。`/duet-impl` 依關卡逐步走過計畫,每關 codex 審查,接著針對鎖定計畫中每一項明確承諾稽核累積 diff——這是與品質審查不同的契約驗證。`/duet-review` 進行雙審查者對抗式檢查,對於審查者間任何 medium/high 不一致皆觸發嚴重程度感知的交叉審查;硬性閘門 + `-PRELIMINARY` 後綴確保交叉審查不會被悄悄略過。三個技能皆以背景任務執行審查者——進行中你可以繼續工作。codex 預設使用 `xhigh` 推理強度;在叫用語句中用自然語言訊號可降回 high。

**程式碼契合（codebase fit）。** duet 技能會讓新程式碼契合「這個專案」既有的慣例——檔案結構、命名、慣用寫法、分層——而不只看正確性。`/duet-plan` 會在每份計畫中寫入一段 Codebase Fit Contract,`/duet-impl` 的關卡審查與 `/duet-review` 都帶有 `codebase-fit` 審查視角。共用的參考是 koji 文件目錄中的 `CODEBASE_CONVENTIONS.md`:一個中樞,它透過 `sources:` 清單「指向」（而非複製）專案自己的慣例文件——`CONTRIBUTING.md`、`AGENTS.md`、`.cursorrules`、`STYLE.md`——並從審查實際抓到的問題逐步累積標準範例索引與「已否決模式」紀錄。`/koji-init` 為新專案建立它,`/kick-off` 則把它回填到既有專案。

**死碼掃描(dead-code sweep)。** `/duet-review` 與 `/duet-impl` 的關卡審查者會主動標出 diff 讓哪些程式碼路徑變得不可達(`deadcode` finding)——被取代的 helper、結構上已死的分支、永遠不會進入的 match arm。內建例外處理:測試 scaffolding、生成程式碼、以及前向相容/遷移橋接程式碼會被略過,讓「加新路徑、保留舊路徑」的基底搭建階段順利通過。`/duet-impl` 的執行末段報告也會在 promise 稽核旁顯示一個程式碼增刪比(例如 `+2310 / −267 (ratio 8.6:1)`)——基底搭建 vs 重構的元訊號,搭配 deadcode 發現一起判讀。

**三角化(`/triangulate`)。** 當你想要多方論述但希望由「你」當綜合者(而不是讓代理收斂)時:Claude + codex 並行針對單一問題論述,各自可進行網路研究,呈現立場,你權衡與決定。可選擇儲存到 `.koji/plans/` 或 `.koji/research/`,或將綜合段落附加到既有計畫——根據專案目前進行中的項目以對話方式選擇。它也能**與「逐項呈現發現」的計畫審查組合**(例如 `/plan-eng-review`):叫用審查時加上 `/triangulate`,每一項發現在你鎖定前都會先經過一次跨模型論述——並帶入「下游階段是否會吸收或翻轉此決定」的大局視角,還可選擇對審查的 outside voice 加跑一輪 red-team 反駁。

**離線(walk-away)工作階段。** `/duet-plan`、`/duet-impl` 與 `/triangulate` 會在背景 AI 任務執行期間讓機器保持喚醒(`caffeinate` / `systemd-inhibit`),並在結束時釋放——讓你能啟動一段長時間執行後離開。僅這些技能採用(絕不包含一般的 `/kick-off`);採用引用計數(巢狀執行共用同一個喚醒程序),且具擁有權安全:絕不會關閉你自己啟動的喚醒程序。

**計畫與研究工作文件。** `.koji/plans/`(已決定、待實作的工作)與 `.koji/research/`(調查發現,待驗證)。研究檔案以主題為定址單位——新發現會累積進現有主題檔案(`## Decisions` 段落由新到舊),而不是另開以工作階段命名的平行檔案。輕量的 YAML frontmatter(`status:` 欄位,依類型而定:plans 為 pending/in-progress/completed/archived,research 為 unvalidated/validated/archived)。`/kick-off` 會在工作階段開始時列出待辦項目;`/duet-impl` 會在執行結束時將計畫標記為 `completed`;`koji-plans-research --set-status <path> <new>` 可從命令列修改。漂移豁免(不是程式碼覆蓋文件)。

## 更詳細的文件

README 刻意保持簡短。詳細內容在各 SKILL.md 中:
- [`kick-off/SKILL.md`](kick-off/SKILL.md)、[`wrap/SKILL.md`](wrap/SKILL.md)、[`take-note/SKILL.md`](take-note/SKILL.md)、[`koji-init/SKILL.md`](koji-init/SKILL.md)、[`inspect-doc-drift/SKILL.md`](inspect-doc-drift/SKILL.md)
- [`duet-plan/SKILL.md`](duet-plan/SKILL.md)、[`duet-impl/SKILL.md`](duet-impl/SKILL.md)、[`duet-review/SKILL.md`](duet-review/SKILL.md)
- [`triangulate/SKILL.md`](triangulate/SKILL.md) — Claude + codex + 你 = 一個決策的三個參考點
- [`references/agent-autonomy.md`](references/agent-autonomy.md) — duet 技能共用的自主原則

## 常見問題

**工作階段文件存放在哪裡?** 在每個專案的 `.koji/` 目錄中,提交到 git。`~/.config/koji/` 只儲存全域偏好設定。

**`/koji-init` 會覆蓋現有文件嗎?** 不會。若在 `docs/` 找到現有工作階段檔案,koji 會詢問要遷移還是保留原處。內容會被保留。

**與 gstack 衝突嗎?** 不會。技能名稱不同,設計為共存。

**會回傳資料嗎?** 沒有遙測,沒有分析。所有工作階段資料留在你的儲存庫中。

## 支援

- **Claude Code**（主要目標)
- 任何能讀取 markdown 技能檔案的 AI 代理

## 授權

MIT
