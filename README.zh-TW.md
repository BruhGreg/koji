# koji

AI 程式碼代理的工作階段管理工具。如同發酵的麴種——為任何專案植入結構化的工作階段延續性。

koji 讓你的 AI 代理擁有跨工作階段的記憶：經驗教訓、專案狀態交接，以及自動歸檔的工作階段日誌。安裝一次，隨處使用。

## 為什麼需要 koji

每次 AI 程式碼工作階段都是冷啟動。你的代理不知道昨天發生了什麼、犯了什麼錯、下一步該做什麼。你每次都得重新解釋上下文。

koji 用結構化的工作階段文件和三個指令解決這個問題：
- **`lessons.md`** — 僅追加的修正與注意事項日誌。你的代理會讀取它，不再重複犯錯。
- **`AI_HANDOFF.md`** — 專案狀態的即時快照。給下一個接手者的簡報文件。
- **`agent-session.md`** — 工作階段歷史，帶有自動歸檔。完整的稽核紀錄。
- **`TODO.md`** — 獨立於交接文件的任務追蹤。由 `/wrap` 首次使用時自動建立。

## 安裝

```bash
git clone --depth 1 https://github.com/BruhGreg/koji.git ~/.claude/skills/koji
cd ~/.claude/skills/koji && ./setup
```

完成。五個技能現已在 Claude Code 中可用：

| 技能 | 功能 |
|------|------|
| `/kick-off` | 開始工作階段：載入交接、教訓、上次紀錄——或 `/kick-off 建立新聞頁面` 指定焦點 |
| `/wrap` | 結束工作階段：更新教訓、交接、日誌、歸檔、提議提交、產生下次啟動提示 |
| `/take-note` | 工作階段中途：儲存進度——或 `/take-note 完成認證，接下來做測試` 附帶說明 |
| `/koji-init` | 初始化：在任何專案中建立文件骨架和 `.koji.yaml` |
| `/inspect-doc-drift` | 掃描帶有 `<!-- koji:covers -->` 標籤的文件，顯示文件與其所覆蓋程式碼的漂移狀況，並協助修復已過期的文件 |

## 快速開始

```
> /koji-init
```

koji 會問兩個問題（模板樣式 + 歸檔策略），然後建立：

```
.koji/
├── agent-session.md       # 工作階段歷史
├── AI_HANDOFF.md          # 給下一個代理的專案狀態
├── lessons.md             # 修正與發現
├── SESSION_TEMPLATE.md    # 條目格式參考
└── sessions/              # 歸檔目錄
TODO.md                    # 任務追蹤（由 /wrap 首次使用時建立）
```

另外在專案根目錄產生 `.koji.yaml` 作為設定檔。

每次工作階段開始時執行 `/kick-off`。結束時執行 `/wrap`。中途檢查點執行 `/take-note`。

### 技能參數

部分技能支援在指令後方附加文字來覆蓋預設行為：

```
/kick-off                          → 讀取上次工作階段，從交接處繼續
/kick-off 建立新聞頁面               → 跳過上次紀錄，專注於你的意圖

/take-note                         → 從對話上下文推斷進度
/take-note 完成認證，接下來做測試      → 直接使用你的備註
```

## 設定

`.koji.yaml` 位於專案根目錄。所有欄位皆為選填——有合理的預設值。

```yaml
# koji — AI 代理的工作階段管理
docs_dir: .koji               # 工作階段文件存放位置（舊版：docs）
template: default             # "default"（完整）或 "simple"（精簡）
archive:
  strategy: numbered          # "numbered"（archive-01.md）或 "dated"（YYYY-MM/DD-slug.md）
  threshold: 5                # 達到此數量時進行歸檔
  keep: 1                     # 在活動檔案中保留的數量
  dir: sessions               # 歸檔子目錄
agents:                       # 工作階段條目的標籤
  - Claude
  - Cursor
wrap:
  starter_prompt: true        # 在 /wrap 時產生下次工作階段的提示
todo:
  file: TODO.md               # 檔案名稱（自動偵測：TODO.md 或 TODOS.md）
  completed: inline           # "inline"（## Completed 區段）或 "archive"（COMPLETED_TASKS.md）
```

全域設定（`~/.config/koji/config.yaml`）也會儲存持久偏好：
- `commit_strategy` — `together` 或 `split`，由你第一次 `/wrap` 時的選擇記住
- `auto_update` — `true` 或 `false`，在 `/kick-off` 時自動更新 koji

### 模板

- **`default`** — 完整的工作階段條目：摘要、主要成果、測試結果、備註。適合複雜的多功能專案。
- **`simple`** — 精簡的條目：完成項目、關鍵決策、變更檔案、下一步。適合專注的流程和腳本。

### 歸檔策略

- **`numbered`** — 歸檔至 `sessions/archive-01.md`、`archive-02.md` 等。簡單、線性。
- **`dated`** — 歸檔至 `sessions/YYYY-MM/DD-slug.md`，附帶 `INDEX.md` 查詢表。更適合長期執行的專案。

## 啟動時載入文件（v0.4.0）

預設情況下，`/kick-off` 讀取四個必要檔案（交接文件、TODO、教訓、上次工作階段條目）。其他所有東西——`docs/*.md`、`DESIGN.md`、架構筆記——在工作階段開始時對代理是隱形的。

**將特定文件加入啟動上下文**：在 `AI_HANDOFF.md` 加一個區段：

```markdown
## Load on Kick-Off

- [Architecture](docs/ARCHITECTURE.md)
- [API Reference](docs/API.md)
- docs/DEPLOYMENT.md
- /DESIGN.md
```

項目支援 markdown 連結格式或純路徑格式。`/kick-off` 會解析此區段，將每個 `.md` 路徑載入上下文，並回報：`Docs: 4 loaded`。

### 選用：透過覆蓋標籤感知漂移

任何文件都可以透過 YAML frontmatter 宣告它所描述的程式碼路徑。當已標籤的文件在 Load on Kick-Off 中且其覆蓋路徑自文件上次編輯後超過 `docs.stale_threshold` 個提交時，`/kick-off` 會載入並附上警告。

```markdown
---
covers:
  - src/auth/
  - server/routes/auth/
---

# AUTH_FLOW.md
```

頂層 `covers` 鍵。Frontmatter 與更廣的 AI-agent-markdown 生態一致（Cursor rules、Continue.dev、Astro、MkDocs、Hugo、Jekyll 都能解析）。可以自由與其他 frontmatter 鍵混用。

### 設定

```yaml
# .koji.yaml
docs:
  stale_threshold: 10       # 覆蓋路徑中的提交數（預設 10）
  stale_action: warn        # "warn"（載入並警告）或 "skip"（預設為 warn）
```

### 孤兒文件偵測

若任何覆蓋路徑已從工作目錄中移除（程式碼已刪除、搬移或重構），文件會被標記為 **orphan**——與 stale 分開的狀態。`/kick-off` 仍會載入但警告更強烈；`/inspect-doc-drift` 將孤兒排在最前，並提供對已刪除程式碼合理的修復路徑（重新標籤、移除標籤、或刪除文件）。

### `/wrap` 建議新增

當一個工作階段的 git diff 與已標籤文件的覆蓋路徑重疊時，`/wrap` 會問一次是否將它們加入 `## Load on Kick-Off` 區段。單一整合提示，非逐個文件。

### `/inspect-doc-drift`

整個倉庫層級的文件—程式碼漂移與未標籤文件稽核。

- **已標籤文件** → 回報漂移狀態（fresh / stale / orphan），並引導問題文件的修復（開啟 / 重新標籤 / 移除標籤 / 刪除 / 跳過）。
- **倉庫中所有未標籤的 `.md`** → 依優先度分桶：
  - **HIGH**——列在 `## Load on Kick-Off` 中但未標籤的文件（載入但無漂移訊號）
  - **MEDIUM**——`docs/` 下的文件與巢狀 `DESIGN.md` 檔案
  - **LOW**——其他已追蹤的 `.md` 檔案
  中繼檔案會被排除（README、LICENSE、CHANGELOG、CLAUDE.md、AGENTS.md、handoff、工作階段日誌、TODO 等）。你可以選擇要走過哪個桶；每個文件的提示會透過啟發式（檔名關鍵字 + 內文引用）建議 covers 路徑。

不帶參數執行取得儀表板與提示，或用 `/inspect-doc-drift <path>` 唯讀鑽入某個文件。

### 設計註記

無推論。無圖形遍歷。無自動發現。`/kick-off` 只讀取你在交接中明確列出的內容。未加入 `Load on Kick-Off` 區段的專案行為與 v0.3.x 完全相同——零變化。標籤約定落在一個已有相關工具的領域（Semcheck、Driftcheck、DocSync 都以 LLM 呼叫解決相近問題）；koji 的切入點是 git 提交計數漂移啟發法，這是確定性的、便宜的，完全不需要模型。

## 運作方式

```
~/.claude/skills/koji/        # 模組（git 倉庫）
├── kick-off/SKILL.md         # /kick-off 技能定義（含版本檢查 + gstack 偵測）
├── wrap/SKILL.md             # /wrap 技能定義
├── take-note/SKILL.md        # /take-note 技能定義
├── koji-init/SKILL.md        # /koji-init 技能定義
├── inspect-doc-drift/SKILL.md  # /inspect-doc-drift 技能定義（v0.4.0）
├── bin/
│   ├── koji-config           # 設定讀寫工具
│   ├── koji-detect           # 專案偵測 + 設定層疊
│   └── koji-migrate-check    # 舊版 docs/ → .koji/ 遷移偵測
├── templates/
│   ├── default/              # 完整模板集
│   └── simple/               # 精簡模板集
├── setup                     # 安裝程式
├── VERSION                   # 目前版本
└── README.md

~/.config/koji/               # 全域狀態（XDG 標準）
└── config.yaml               # 全域預設值

<project>/
├── .koji.yaml                # 專案設定
└── .koji/                    # 工作階段文件（由 /koji-init 建立）
```

**設定層疊：** `.koji.yaml`（專案）> `~/.config/koji/config.yaml`（全域）> 內建預設值。支援 `XDG_CONFIG_HOME` 環境變數。

**無需建置步驟。** 純 bash + markdown。除 POSIX shell 外無任何依賴。

## `/wrap` 工作流程

### `/kick-off`

當你在工作階段開始時執行 `/kick-off`：

1. **遷移檢查** — 偵測 koji 檔案是否在 `docs/`（舊版）但 `.koji.yaml` 指向 `.koji/`。提供遷移或跳過選項。
2. **版本檢查** — 比較本地與遠端 VERSION。提供更新 / 跳過 / 總是更新選項。
3. **載入上下文** — 靜默讀取 AI_HANDOFF.md、TODO.md、lessons.md、上次工作階段條目。
4. **延伸上下文** — 三層式上下文收集，無需設定：
   - **基礎層**（始終執行）— git 分支、未提交變更、活動計畫
   - **參照追蹤**（當工作階段備註提及特定檔案/計畫時）— 讀取引用的計畫、搜尋歸檔中的相關工作階段
   - **程式碼導覽**（首次工作階段、過期交接或無方向時）— 偵測技術棧、專案結構、近期提交、關鍵文件
5. **簡報** — 精簡摘要：上次工作階段、下一項任務、注意事項、分支、焦點。
6. **gstack 建議** — 若偵測到 gstack，分析目前開發階段並建議 2-3 個相關工作流程（例如前端工作建議 `/browse`，準備發布建議 `/qa`）。未偵測到 gstack 則跳過。

### `/wrap`

當你在工作階段結束時執行 `/wrap`，它會依序執行六個步驟：

1. **教訓** — 掃描工作階段中的修正或發現。以格式追加至 `lessons.md`：`YYYY-MM-DD — [Agent] — 出了什麼問題 → 預防規則`
2. **交接與 TODO** — 更新 `AI_HANDOFF.md` 的專案狀態變更。標記 `TODO.md` 中已完成的任務，並新增發現的項目（首次使用時自動建立）。
3. **工作階段日誌** — 追加新條目至 `agent-session.md`。如達到閾值則歸檔最舊的條目。
4. **權限維護** — 掃描 `settings.local.json` 中本次工作階段核准的權限。安全的自動升級至 `settings.json`，危險的自動跳過，灰色地帶的才詢問使用者（目標：大多數工作階段零提示）。
5. **提交提議** — 顯示 `git diff --stat`，提議 conventional commit。對於混合程式碼與文件的變更，詢問你偏好的分割策略並記住供未來使用。
6. **啟動提示** — 為下次工作階段產生 3-5 句的簡報。根據本次完成的工作建議描述性的工作階段名稱（例如 `auth-middleware-refactor`）。

## 從專案本地 Wrap 遷移

如果你的專案中已有 `.agents/workflows/wrap.md` 或 `.claude/skills/wrap/SKILL.md`，執行 `/koji-init`——它會偵測現有文件，僅建立 `.koji.yaml`。然後刪除舊的本地檔案：

```bash
rm -f .agents/workflows/wrap.md
rm -rf .claude/skills/wrap .claude/skills/take-note
rm -f .claude/commands/wrap.md
```

## 常見問題

### 工作階段文件存放在哪裡？

在各專案的 `.koji/` 目錄中（舊版專案為 `docs/`），提交至 git。每個專案的教訓、交接和工作階段歷史都屬於該專案。`~/.config/koji/` 只存放你的全域偏好設定（如預設模板）——不含專案資料。

### `/koji-init` 會覆蓋我現有的文件嗎？

不會。如果在 `docs/` 中找到現有的工作階段檔案，koji 會詢問你要遷移至 `.koji/`（新標準）還是保持原位。無論選擇哪個，現有內容都會保留——不會覆蓋或刪除任何東西。

### 我舊的 `/wrap` 工作流程檔案怎麼辦？

`/koji-init` 會偵測舊式 wrap 檔案（`.agents/workflows/wrap.md`、`.claude/skills/wrap/SKILL.md`、`.claude/commands/wrap.md`）並提議移除。它一定會先詢問——未經你的同意不會刪除任何東西。

### 會和 gstack 衝突嗎？

不會。gstack 沒有 `wrap`、`take-note` 或 `koji-init` 技能，所以符號連結不會碰撞。它們在 `~/.claude/skills/` 中共存。

### `~/.config/koji/` 裡有什麼？

只有 `config.yaml`，存放你的全域預設值（模板偏好、歸檔策略）。沒有遙測、沒有分析、沒有專案資料。所有工作階段文件都留在專案倉庫中。支援 `XDG_CONFIG_HOME` 環境變數。

### 代理怎麼知道要在工作階段開始時讀取交接/教訓？

`/koji-init` 會在專案的 `CLAUDE.md` 中新增 `## Session Management (koji)` 區塊，指示在工作階段開始時執行 `/kick-off`，自動讀取交接狀態和教訓。Claude Code 在每次工作階段開始時會自動讀取 `CLAUDE.md`。

### 可以為不同專案使用不同模板嗎？

可以。每個專案的 `.koji.yaml` 可以獨立指定 `template: default` 或 `template: simple`。沒有 `.koji.yaml` 的專案使用 `~/.config/koji/config.yaml` 中的全域預設值。

### TODO.md 如何運作？

`TODO.md` 由 `/wrap` 在首次有任務相關工作時自動建立——`/koji-init` 不會建立空的骨架。它位於專案根目錄（不在 `.koji/` 內）。`/wrap` 會標記已完成的項目並新增工作階段中發現的任務。`/kick-off` 會與交接一起讀取它以獲取任務上下文。在 `.koji.yaml` 的 `todo:` 下設定檔案名稱和已完成任務的處理方式。

### 提交策略偏好是什麼？

當 `/wrap` 同時遇到程式碼和文件變更時，會詢問你要一起提交還是分成兩次提交（先程式碼、後文件）。你的選擇會儲存至 `~/.config/koji/config.yaml`，未來的 wrap 會自動使用相同策略。隨時可用 `koji-config set commit_strategy together` 或 `koji-config set commit_strategy split` 更改。

### /kick-off 如何收集上下文？

三層式，無需設定。**基礎層**（始終執行）：檢查 git 分支、未提交變更、活動計畫。**參照追蹤**（當工作階段備註提及特定檔案/計畫時）：讀取引用的計畫並搜尋歸檔中的相關主題。**程式碼導覽**（首次工作階段、交接超過 7 天或無工作階段備註時）：偵測技術棧、專案結構、近期提交、關鍵文件。每層根據上下文自動觸發——無需設定旗標。

### 設定有多難？

一行指令：`git clone ... && ./setup`。大約 2 秒。無依賴、無建置步驟、無 npm/bun/pip。純 bash + markdown。

## 相容性

- **Claude Code**（主要目標）
- 任何能讀取 markdown 技能檔案的 AI 代理

設計上與 [gstack](https://github.com/garrytan/gstack) 共存——無命名衝突。

## 授權

MIT
