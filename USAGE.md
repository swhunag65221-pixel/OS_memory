# OS-Memory 使用說明

這是 OS-Memory 的完整操作手冊。架構設計與原理請見 [README.md](README.md)；這份文件專注在**怎麼裝、怎麼用、怎麼調、出問題怎麼辦**。

文中所有指令輸出皆為實際執行擷取，範例路徑以 `~/projects/myapp` 代表你的專案。

## 目錄

1. [一分鐘理解](#1-一分鐘理解)
2. [安裝](#2-安裝)
3. [日常使用：全自動流程](#3-日常使用全自動流程)
4. [Slash 指令](#4-slash-指令)
5. [CLI 完整參考](#5-cli-完整參考)
6. [生命週期實戰演練](#6-生命週期實戰演練)
7. [跨專案共享經驗](#7-跨專案共享經驗)
8. [設定調整情境](#8-設定調整情境)
9. [疑難排解](#9-疑難排解)
10. [解除安裝](#10-解除安裝)
11. [附錄：檔案位置與資料格式](#11-附錄檔案位置與資料格式)

---

## 1. 一分鐘理解

裝好之後你**不需要做任何事**，系統全自動運作：

| 時機 | 發生什麼 |
|---|---|
| Session 開始 | 過去累積的記憶（專案層 + 帳戶層合併）以 digest 注入 context |
| 工作中 | Claude 依 digest 指引維護記憶：有用就強化、錯了就削弱、學到新東西就新增 |
| Session 結束 | 有實質工作量時，自動觸發一次反思，沉澱這個 session 的經驗 |
| 時間流逝 | 記憶按半衰期指數衰減；沒被驗證的自然消失，反覆驗證的留下來 |

想主動介入時，隨時可用 `/remember`、`/reflect`、`/forget`、`/memory-review`、`/memory-status`。

## 2. 安裝

### 需求

- `bash` 3.2+（macOS 內建版本即可）
- `jq` 1.5+（`brew install jq` / `apt install jq`）

### 裝到單一專案

```console
$ ./install.sh --project ~/projects/myapp
OS-Memory installed (project: /home/you/projects/myapp):
  store:    /home/you/projects/myapp/.claude/os-memory
  commands: /home/you/projects/myapp/.claude/commands/{remember,reflect,forget,memory-review,memory-status}.md
  hooks:    /home/you/projects/myapp/.claude/settings.json (SessionStart, Stop)
  notes:    /home/you/projects/myapp/CLAUDE.md

New Claude Code sessions in this project now load and maintain memory automatically.
```

不帶路徑時裝到目前目錄：`cd ~/projects/myapp && /path/to/os_memory/install.sh --project`。

### 裝到整個帳戶

```console
$ ./install.sh --global
OS-Memory installed (account-wide):
  store:    /home/you/.claude/os-memory
  ...
```

帳戶層安裝後，**所有專案**的 session 都會載入帳戶記憶——包括沒有做專案層安裝的專案。

### 建議：兩者並存

```bash
./install.sh --global                       # 一次
./install.sh --project ~/projects/myapp     # 每個重要專案一次
```

專案層存放專案知識（慣例、踩過的坑），帳戶層存放通用經驗（你的偏好、通用工作流）。recall 時自動合併，專案記憶排在前面。

安裝是**冪等**的：重跑不會重複註冊 hooks、不會覆蓋既有的 `config.json` 與記憶資料、CLAUDE.md 區塊只加一次。已有 `settings.json` 時採合併而非覆蓋。

### 驗證安裝

```console
$ ./install.sh --doctor
OS-Memory v1.0.0
jq: jq-1.7
clock: 2026-07-09T09:30:51Z
project store: /home/you/projects/myapp/.claude/os-memory (0 active, 0 archived)
global store:  /home/you/.claude/os-memory (0 active, 0 archived)
hooks registered in: /home/you/.claude/settings.json
markers dir: /tmp/os-memory-1000
```

裝完後**重新啟動 Claude Code session**（hooks 在 session 開始時載入）。

## 3. 日常使用：全自動流程

### Session 開始：記憶注入

每個新 session 開始時（含 `/clear` 之後與 context 壓縮之後），你會在 context 中看到：

```markdown
<os-memory-digest>
# Long-term memory (OS-Memory v1.0.0)

Persistent memories from past sessions, strongest first. Maintain them while
you work — this is how learning happens:
- A memory below proved helpful → bash ".../memory.sh" reinforce <id>
- A memory below is wrong or outdated → bash ".../memory.sh" weaken <id> --reason "why"
- You learned a durable, non-obvious lesson (max 3 per session; skip trivia) →
  bash ".../memory.sh" add --category <...> [--scope global] "<one-sentence lesson>"
Slash commands: /remember /reflect /forget /memory-review /memory-status

## Project memories (myapp)

### pitfall
- [m260709d1408d | candidate | 3] Alembic migrations silently skip tables without a declared primary key — hit during the v2 migration

### convention
- [m260709e49367 | verified | 5] API error responses always use the ProblemDetails JSON shape

## Account-wide memories (shared across projects)

### preference
- [m260709879a84 | candidate | 3] User prefers Traditional Chinese for discussion and English for code

</os-memory-digest>
```

每條格式為 `[id | 狀態 | 有效強度]`。只顯示有效強度 ≥ `digest_min_score`（預設 1.0）的記憶，每層最多 `digest_max_entries`（預設 40）條；`pinned` 記憶永遠顯示。分類固定排序：pitfall → fix → convention → preference → workflow → fact → insight（保護性知識優先）。

digest 注入時也會順便檢查是否距上次衰減結算超過 24 小時，是的話自動跑一次 `consolidate`（純腳本、零 token）。

記憶累積 5 條以上且超過 14 天未審查時，digest 底部會出現提醒：

```
NOTE: project store has 12 memories and has never been reviewed — consider running /memory-review.
```

### Session 結束：自動反思

當 session 有實質工作量（transcript ≥ `reflect_min_transcript_bytes`，預設 60KB）時，Claude 第一次要結束回覆會被 Stop hook 擋下，收到以下指示（每個 session 只觸發一次）：

```
[OS-Memory] Automatic end-of-session reflection (fires once per session).
Before giving your final reply, update long-term memory (script: .../memory.sh):
1. Reinforce digest memories that actually helped this session: ...
2. Weaken digest memories that proved wrong or outdated: ...
3. Save at most 3 genuinely durable new lessons, one self-contained English sentence each: ...
Worth saving: pitfalls you hit and their fixes, corrections from the user, verified
project facts and conventions, stated user preferences. Not worth saving: trivia,
one-off details, anything already in the digest.
If nothing qualifies, save nothing. Then finish your reply.
```

Claude 反思完（或判定無事可存）就正常結束。閒聊型 session 不會觸發。

## 4. Slash 指令

### `/remember <經驗>`

立刻存一條記憶。Claude 會把你的輸入濃縮成一句自足的英文、選好分類與範圍再存：

```
你：/remember 這個專案的 CI 在 node 20 以下會炸，一定要用 nvm use 20
Claude：已存為 m2607091a2b3c [project/pitfall/candidate]
        "CI requires Node 20+; run nvm use 20 before pushing"
```

不帶參數時，Claude 會回顧當前 session、提出 1–3 條候選讓你挑。

### `/reflect`

手動觸發完整反思（等同 session 結束的自動反思，但由你決定時機）：強化有用的、削弱錯誤的、新增最多 3 條，最後跑 `consolidate` 並回報。

### `/forget <id 或描述>`

移除或削弱記憶。給描述時 Claude 會先 `search` 找出對象，模糊時會問你：

```
你：/forget 那條關於 ProblemDetails 的記憶已經過時了
Claude：找到 m260709e49367 "API error responses always use the ProblemDetails JSON shape"
        已 forget（封存，60 天後永久刪除）
```

明確錯誤／要求移除 → `forget`（立即封存）；只是存疑 → `weaken`（扣分，讓它自然淘汰）。

### `/memory-review`

完整審查，相當於「睡眠中的記憶鞏固」。Claude 會列出兩層全部記憶，然後：合併重複、修剪過時、把多條個案歸納成通則、將通用經驗 `promote` 到帳戶層、對關鍵不變量 `pin`，最後 `consolidate` + `mark-reviewed` 並回報統計。建議每 1–2 週跑一次（digest 會提醒你）。

### `/memory-status`

顯示兩層的統計、最強的記憶、上次結算與審查時間，以及是否該跑 `/memory-review`。

## 5. CLI 完整參考

所有操作也可以直接下 CLI（對 Claude 與對你都一樣）。腳本位置：

```bash
MEM="$CLAUDE_PROJECT_DIR/.claude/os-memory/scripts/memory.sh"   # 專案層
[ -f "$MEM" ] || MEM="$HOME/.claude/os-memory/scripts/memory.sh" # 帳戶層 fallback
```

### `add` — 新增記憶

```bash
bash "$MEM" add [--scope project|global] [--category CAT] [--context TXT] [--status S] "lesson"
```

| 旗標 | 預設 | 說明 |
|---|---|---|
| `--scope` | `auto`（有專案層就存專案層，否則存帳戶層） | `project` / `global` |
| `--category`（或 `-c`） | `insight` | `pitfall` `fix` `convention` `preference` `workflow` `fact` `insight`；其他值可用但會警告 |
| `--context` | 無 | 補充細節，會顯示在 digest 條目後方 |
| `--status` | `candidate` | 也可直接建立 `verified` / `pinned` |

```console
$ bash "$MEM" add --category pitfall --context "hit during the v2 migration" \
    "Alembic migrations silently skip tables without a declared primary key"
added m260709fcde1e [project/pitfall/candidate] Alembic migrations silently skip tables without a declared primary key
```

**自動去重**：同一層已有內容完全相同的記憶時，不會重複建立，改為強化既有那條：

```console
$ bash "$MEM" add --category pitfall "Alembic migrations silently skip tables without a declared primary key"
os-memory: identical memory already exists (m260709fcde1e) — reinforcing it instead
reinforced m260709fcde1e → score 4, wins 1, status candidate
```

### `reinforce <id>` — 強化（記憶有用）

+1 分（上限 10）、`wins` +1、**刷新衰減時鐘**；candidate 累積 2 次 wins 自動升級 verified：

```console
$ bash "$MEM" reinforce m260709fcde1e
reinforced m260709fcde1e → score 5, wins 2, status verified
```

### `weaken <id> [--reason TXT]` — 削弱（記憶錯誤）

-1.5 分（下限 0）、`losses` +1、記錄原因；**不會**刷新衰減時鐘（錯誤的記憶要死得快）。扣到 0 立即封存：

```console
$ bash "$MEM" weaken m26070955029b --reason "proven incorrect"
weakened m26070955029b → score 1.5
$ bash "$MEM" weaken m26070955029b --reason "still wrong"
weakened m26070955029b → score 0 — forgotten (archived)
```

### `forget <id>` — 立即封存

```console
$ bash "$MEM" forget m260709e49367
forgot m260709e49367 (archived; purged permanently after grace period)
```

### `pin <id>` / `unpin <id>` — 釘選／解除

`pin` 讓記憶豁免衰減且永遠出現在 digest（請節制，只用於關鍵不變量）；`unpin` 恢復為 `verified`。

### `promote <id>` — 升級到帳戶層

把專案記憶搬到帳戶層（所有專案共享）。帳戶層已有相同內容時自動合併（強化帳戶層那條、移除專案層副本）：

```console
$ bash "$MEM" promote m260709648459
promoted m260709648459 to account-wide memory (shared across projects)
```

### `recall [--hook]` — 印出 digest

輸出與 session 開始注入的內容相同，可隨時手動檢視。也會觸發到期的自動結算。

### `search <text>` — 搜尋

大小寫不敏感的子字串比對，範圍涵蓋內容、context 與分類：

```console
$ bash "$MEM" search "alembic"
== project store
m260709fcde1e	verified	pitfall	Alembic migrations silently skip tables without a declared primary key
```

### `list [--all|--archived]` — 表列

`list` 列出活躍記憶（含即時計算的有效強度 EFF）；`--archived` 只列封存區；`--all` 兩者都列：

```console
$ bash "$MEM" list
== project store: /home/you/projects/myapp/.claude/os-memory
ID              STATUS    EFF  SCORE  W/L  CATEGORY  CONTENT
m260709fcde1e   verified  5    5      2/0  pitfall   Alembic migrations silently skip tables without a declared primary key

== global store: /home/you/.claude/os-memory
ID              STATUS     EFF  SCORE  W/L  CATEGORY    CONTENT
m2607098a0468   candidate  3    3      0/0  preference  User prefers Traditional Chinese for discussion and English for code
```

### `stats` — 統計

```console
$ bash "$MEM" stats
== project store: /home/you/projects/myapp/.claude/os-memory
  active: 1  (pinned 0, verified 1, candidate 0)
  avg effective score: 5
  by category: pitfall=1
  archived: 1
  last consolidated: never
  last reviewed: never
...
```

### `consolidate [--quiet]` — 衰減結算

手動執行永遠立即結算（自動版本才受 24 小時間隔限制）。封存有效強度 < 0.5 的非 pinned 記憶、永久刪除封存超過 60 天的記錄：

```console
$ bash "$MEM" consolidate
consolidated project store: kept 1, archived 0, purged 0
consolidated global store: kept 1, archived 0, purged 0
```

### 其他

| 指令 | 作用 |
|---|---|
| `mark-reviewed` | 記錄完成審查（`/memory-review` 的最後一步） |
| `doctor` | 健康檢查（同 `install.sh --doctor`） |
| `help` | 完整指令說明 |
| `version` | 印出版本 |

環境變數：`OS_MEMORY_GLOBAL_DIR` 覆蓋帳戶層位置（預設 `~/.claude/os-memory`）；`OS_MEMORY_NOW`（epoch 秒）覆蓋時鐘，供測試衰減用。

## 6. 生命週期實戰演練

以下完整走一遍「學習 → 驗證 → 遺忘」，你可以在任何裝好的專案裡照做：

```bash
MEM=".claude/os-memory/scripts/memory.sh"

# 1. 學到一條經驗（candidate，score 3，半衰期 14 天）
bash "$MEM" add --category pitfall "Never run migrations without a backup"

# 2. 下個 session 它出現在 digest；真的有用 → 強化兩次 → verified（半衰期變 90 天）
bash "$MEM" reinforce m260709xxxxxx
bash "$MEM" reinforce m260709xxxxxx      # → status verified

# 3. 模擬 40 天沒用到：candidate 會被封存，verified 活著
OS_MEMORY_NOW=$(( $(date +%s) + 40*86400 )) bash "$MEM" consolidate
# consolidated project store: kept 1, archived 1, purged 0

# 4. 檢視封存區（還沒真正消失，60 天內都可以人工救回）
bash "$MEM" list --archived

# 5. 模擬 200 天後：封存區被永久清除（真正遺忘）
OS_MEMORY_NOW=$(( $(date +%s) + 200*86400 )) bash "$MEM" consolidate
```

用預設參數換算成直覺時間感：

| 記憶 | 離開 digest（想不起來） | 被封存 | 被永久刪除 |
|---|---|---|---|
| candidate（score 3，半衰期 14 天） | 約 22 天沒用到 | 約 36 天 | 再過 60 天 |
| verified（score 5，半衰期 90 天） | 約 209 天沒用到 | 約 299 天 | 再過 60 天 |
| pinned | 永不 | 永不 | 永不 |

每次 `reinforce` 都會把時鐘歸零重算——常用的記憶永遠新鮮。

## 7. 跨專案共享經驗

三種方式：

1. **新增時直接存帳戶層**：`bash "$MEM" add --scope global --category preference "..."` —— 適合一開始就知道是通用經驗的。
2. **事後升級**：`bash "$MEM" promote <id>` —— 專案裡驗證過、發現放諸四海皆準時。`/memory-review` 也會主動做這件事。
3. **團隊共享**：把專案的記憶資料檔 commit 進 git（見下方 FAQ），團隊成員 clone 後即共享專案記憶。

範圍判斷原則：**跟這個 repo 綁定的**（慣例、架構、特定坑）留專案層；**跟「你」綁定的**（偏好、通用工作流、工具使用心得）放帳戶層。

## 8. 設定調整情境

編輯對應層的 `.claude/os-memory/config.json`（兩層各自獨立、可部分覆蓋，欄位完整清單見 README）：

**「記憶消失得太快」** — 拉長半衰期：

```json
{ "half_life_days": { "candidate": 30, "verified": 180 } }
```

**「候選記憶太多、雜訊高」** — 提高門檻讓它們死快一點：

```json
{ "half_life_days": { "candidate": 7 }, "digest_min_score": 1.5 }
```

**「不想要 session 結束的自動反思」** — 關掉，改用 `/reflect` 手動：

```json
{ "auto_reflect": false }
```

**「反思觸發太頻繁／太少」** — 調整工作量門檻（單位：bytes）：

```json
{ "reflect_min_transcript_bytes": 150000 }
```

**「digest 佔太多 context」** — 減少條數：

```json
{ "digest_max_entries": 20 }
```

改完即刻生效（下次 recall / consolidate 就用新值），不需重新安裝。

## 9. 疑難排解

第一步永遠是：

```bash
./install.sh --doctor    # 或 bash "$MEM" doctor
```

**Session 開始沒看到 digest？**
- 記憶庫是空的（新裝）——存一條再開新 session 就有了。digest 在沒有任何夠強的記憶時完全靜默，這是刻意設計。
- hooks 是 session 開始時載入的——安裝後要開**新** session 才生效。
- `resume` 續開的 session 不重新注入（舊 context 裡已經有了），這是刻意的。`/clear` 與 context 壓縮後會重新注入。
- 確認 `doctor` 輸出有 `hooks registered in: ...`。

**自動反思沒觸發？**
- transcript 未達門檻（預設 60KB）——短 session 不觸發是刻意的。
- 每個 session 只觸發一次，已觸發過就不會再擋。
- 確認該層 config 的 `auto_reflect` 是 `true`。

**專案層＋帳戶層都裝了，會不會重複注入／重複反思？**
不會。兩層的 hooks 都會啟動，但以 session 為單位的 marker（存於 `${TMPDIR:-/tmp}/os-memory-<uid>/`）保證 digest 只注入一次、反思只觸發一次，且內容本來就是兩層合併的。

**`jq is required` 錯誤？**
裝 jq：`brew install jq`（macOS）/ `sudo apt install jq`（Debian/Ubuntu）。jq 不在時 hooks 靜默跳過，不會弄壞 session。

**誤刪了記憶？**
60 天寬限期內都在封存區：`bash "$MEM" list --archived` 找到那條，手動把該行從 `archive.jsonl` 搬回 `memory.jsonl`（刪掉 `archived_at` 與 `archive_reason` 欄位即可）。

**記憶檔要不要 commit？**
本 repo 的 `.gitignore` 預設忽略自身的記憶資料（範本保持乾淨）。你的專案裡兩種選擇都合理：commit → 團隊／多機共享；不 commit → 在專案 `.gitignore` 加上三行（見 README FAQ）。

**同時開多個 session 會怎樣？**
極端情況下同時寫入可能丟失一次更新（最後寫入者勝）。實務上單人使用幾乎不會遇到；記憶系統的自我修復特性（重要的東西會再次被學到）也讓偶發丟失無害。

## 10. 解除安裝

```bash
# 專案層
rm -rf ~/projects/myapp/.claude/os-memory
rm ~/projects/myapp/.claude/commands/{remember,reflect,forget,memory-review,memory-status}.md
# 手動移除 settings.json 中 hooks.SessionStart / hooks.Stop 內含 os-memory 的兩條
# 手動移除 CLAUDE.md 中 <!-- os-memory:begin --> 到 <!-- os-memory:end --> 區塊

# 帳戶層：同上，把路徑換成 ~/.claude/
```

只想暫停不想移除：config 設 `auto_reflect: false`，並把 `settings.json` 裡兩條 hook 註解掉（搬走）即可；記憶資料原封不動。

## 11. 附錄：檔案位置與資料格式

```
<專案>/.claude/                         （帳戶層為 ~/.claude/，結構相同）
├── settings.json                       hooks 註冊（SessionStart、Stop）
├── commands/                           五個 slash 指令
│   ├── remember.md  reflect.md  forget.md
│   ├── memory-review.md  memory-status.md
└── os-memory/
    ├── config.json                     本層設定
    ├── memory.jsonl                    活躍記憶（一行一條）
    ├── archive.jsonl                   封存區（60 天寬限）
    ├── state.json                      上次結算／審查時間
    └── scripts/memory.sh               記憶引擎
```

`memory.jsonl` 記錄格式（人類可讀、可直接編輯）：

```json
{
  "id": "m260709fcde1e",
  "category": "pitfall",
  "content": "Alembic migrations silently skip tables without a declared primary key",
  "context": "hit during the v2 migration",
  "status": "verified",
  "score": 5.0,
  "wins": 2,
  "losses": 0,
  "created": "2026-07-09T09:00:00Z",
  "reinforced": "2026-07-09T12:00:00Z",
  "scope": "project",
  "project": "myapp"
}
```

封存記錄額外帶 `archived_at` 與 `archive_reason`：`decayed`（自然衰減）、`manual`（forget）、`weakened-to-zero`（削弱歸零）。

有效強度公式：`eff = score × 0.5 ^ (距上次 reinforced 的天數 / 該狀態半衰期)`。
