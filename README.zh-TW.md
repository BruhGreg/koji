# koji

AI 程式碼代理的工作階段管理工具。如同發酵的麴種——為任何專案植入結構化的工作階段延續性。

koji 讓你的 AI 代理擁有跨工作階段的記憶：經驗教訓、專案狀態交接，以及自動歸檔的工作階段日誌。九個技能,一次安裝。純 bash + markdown,無需建置步驟。

## 安裝

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
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
| `/duet-impl` | 依照鎖定的計畫逐關卡實作。每個 `<!-- gate: NAME -->` 由 codex 單一審查,最後執行 `/duet-review` |
| `/duet-review` | 雙審查者對抗式程式碼審查。Claude + codex 並行**背景執行**——你可以繼續做其他事——意見分歧時交叉審查,高信心修正提示你套用 |

所有 duet 技能皆遵循 [代理自主原則](references/agent-autonomy.md):代理之間共同解決技術問題;只有在無法協商或涉及政策選擇時才會詢問使用者。

**Triangulate** — 使用者作為參與者的跨模型決策。

| 技能 | 功能 |
|------|------|
| `/triangulate` | Claude + codex 對同一個問題並行論述,每個聲音可進行網路與程式碼研究。你綜合判斷做出決定。可選擇儲存到 `.koji/plans/` 或 `.koji/research/`,或附加到既有計畫——根據專案目前進行中的項目以對話方式選擇 |

與 `/duet-*` 不同:duet 技能讓 AI 聲音達成共識;`/triangulate` 把**你**保留為第三個參考點與綜合者。

## 快速開始

```
> /koji-init
```

詢問兩個問題（模板樣式 + 歸檔策略),然後建立:

```
.koji/                  # 工作階段文件
├── agent-session.md    # 工作階段歷史
├── AI_HANDOFF.md       # 給下一個代理的專案狀態
├── lessons.md          # 修正與發現
└── sessions/           # 歸檔目錄
TODO.md                 # 任務追蹤（由 /wrap 首次使用時建立）
```

使用 `/kick-off` 開始工作階段,`/wrap` 結束,`/take-note` 在工作階段中途記錄。

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

**Load on Kick-Off。** 在 `agent-session.md` 中加入 `## Load on Kick-Off` 區段,列出工作階段開始時要載入上下文的文件。`/wrap` 會提議新增/移除以保持對齊。詳見 [`kick-off/SKILL.md`](kick-off/SKILL.md)。

**文件漂移偵測。** 任何文件都可以用 `covers:` frontmatter 標記它所描述的程式碼路徑。當被覆蓋路徑自文件最後編輯以來的提交數超過閾值時,`/kick-off` 會警告。`/inspect-doc-drift` 會稽核整個專案。完全確定性——不需要 LLM。

**Duet 工作流程。** 不會卡住使用者的跨模型代理協作。`/duet-plan` 執行多輪 Claude↔codex 對話直到共識,鎖定計畫。`/duet-impl` 依關卡逐步走過計畫,每關 codex 審查。`/duet-review` 進行雙審查者對抗式檢查,對於審查者間任何 medium/high 不一致皆觸發嚴重程度感知的交叉審查;硬性閘門 + `-PRELIMINARY` 後綴確保交叉審查不會被悄悄略過。三個技能皆以背景任務執行審查者——進行中你可以繼續工作。codex 預設使用 `xhigh` 推理強度;在叫用語句中用自然語言訊號可降回 high。

**三角化(`/triangulate`)。** 當你想要多方論述但希望由「你」當綜合者(而不是讓代理收斂)時:Claude + codex 並行針對單一問題論述,各自可進行網路研究,呈現立場,你權衡與決定。可選擇儲存到 `.koji/plans/` 或 `.koji/research/`,或將綜合段落附加到既有計畫——根據專案目前進行中的項目以對話方式選擇。

**計畫與研究工作文件。** `.koji/plans/`(已決定、待實作的工作)與 `.koji/research/`(調查發現,待驗證)。輕量的 YAML frontmatter(`status:` 欄位,依類型而定:plans 為 pending/in-progress/completed/archived,research 為 unvalidated/validated/archived)。`/kick-off` 會在工作階段開始時列出待辦項目;`/wrap` 會對本工作階段觸碰過的檔案詢問狀態更新,並每個工作階段詢問一次是否要建立新項目。`koji-plans-research --set-status <path> <new>` 可從命令列修改。漂移豁免(不是程式碼覆蓋文件)。

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
