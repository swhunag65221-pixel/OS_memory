# OS-Memory — Claude Code 的長期記憶架構

OS-Memory 讓 Claude Code 像人一樣**持續學習、逐步遺忘**：每次 session 自動載入過去累積的經驗，工作中驗證有用的記憶會被強化、證明錯誤的會被削弱，長期沒用到的會沿著遺忘曲線自然衰減、封存、最終刪除。留下來的，是經過反覆驗證的重要經驗。

靈感來自 Hermes agents 的記憶架構。純 Bash + JSONL 實作，唯一相依是 [`jq`](https://jqlang.org)。

## 核心概念

每條記憶是一筆 JSONL 記錄，帶有分數與狀態，有效強度隨時間指數衰減：

```
有效強度 eff = score × 0.5 ^ (距離上次強化的天數 / 半衰期)
```

| 狀態 | 意義 | 預設半衰期 |
|---|---|---|
| `candidate` | 新學到、尚未驗證的經驗 | 14 天 |
| `verified` | 被強化 2 次以上、經過驗證 | 90 天 |
| `pinned` | 手動釘選的關鍵不變量 | 不衰減 |

記憶的一生（兩段式遺忘，如同人類的遺忘曲線）：

```
 add (score=3, candidate)
   │
   ├── 被引用且有幫助 → reinforce：+1 分、刷新衰減時鐘，2 次後升級 verified
   ├── 被證明錯誤     → weaken：-1.5 分，歸零立即封存（錯誤忘得快）
   │
   ▼ 時間流逝，eff 指數衰減
 eff < 1.0   → 不再出現在 digest（想不起來，但還在）
 eff < 0.5   → consolidate 時移入 archive/（封存）
 封存 60 天  → 永久刪除（真正遺忘）
```

## 兩層儲存、跨專案共享

```
<專案>/.claude/os-memory/   專案記憶（優先）── 這個 repo 的知識
~/.claude/os-memory/        帳戶記憶（共享）── 所有專案共用的經驗
```

每次 session 開始時，兩層記憶**合併**注入。專案裡學到的通用經驗可以用 `promote` 升級到帳戶層，讓其他專案受益；新增時也可以直接 `--scope global`。

## 安裝

需求：`bash` 3.2+、`jq` 1.5+。

```bash
git clone https://github.com/swhunag65221-pixel/os_memory.git
cd os_memory

# 裝進某個專案（寫入該專案的 .claude/）
./install.sh --project /path/to/your/project

# 裝到整個帳戶（寫入 ~/.claude/，所有專案生效）
./install.sh --global

# 檢查安裝狀態
./install.sh --doctor
```

兩種模式可以並存，也建議並存：專案層存放專案知識、帳戶層存放通用經驗。安裝是冪等的（重跑不會重複註冊 hooks），也不會覆蓋既有的記憶資料與 config。

安裝內容：

| 項目 | 位置 | 作用 |
|---|---|---|
| 記憶引擎 | `.claude/os-memory/scripts/memory.sh` | 所有記憶操作的 CLI |
| Hooks | `.claude/settings.json` | SessionStart 注入記憶、Stop 觸發反思 |
| Slash 指令 | `.claude/commands/*.md` | `/remember` `/reflect` `/forget` `/memory-review` `/memory-status` |
| 說明區塊 | `CLAUDE.md` | 告訴 Claude 記憶系統的使用規則 |

## 運作方式（全自動）

1. **Session 開始** — SessionStart hook 將記憶 digest 注入 context：兩層記憶合併、按有效強度排序、只取強度 ≥ 1.0 的前 40 條，並附上維護指引。同時每 24 小時自動跑一次 consolidate（衰減結算）。
2. **工作中** — Claude 依照 digest 指引隨手維護：用到且有幫助就 `reinforce`、發現錯誤就 `weaken`、學到重要經驗就 `add`。
3. **Session 結束** — Stop hook 檢查這個 session 是否有實質工作量（transcript 大小門檻），是的話擋下一次，要求 Claude 反思：強化有用的、削弱錯誤的、最多存 3 條新經驗。每個 session 只觸發一次，不會無限循環。
4. **定期審查** — 記憶超過 14 天未審查時，digest 會提示執行 `/memory-review`：Claude 會合併重複、修剪過時、歸納通則、把通用經驗 promote 到帳戶層——相當於「睡眠中的記憶鞏固」。

## 手動指令

Slash 指令（在 Claude Code 對話中使用）：

| 指令 | 作用 |
|---|---|
| `/remember <經驗>` | 立刻存一條記憶（Claude 會濃縮成一句話並選好分類與範圍） |
| `/reflect` | 對當前 session 做完整反思：強化／削弱／新增 |
| `/forget <id 或描述>` | 削弱或移除某條記憶 |
| `/memory-review` | 完整審查：去重、修剪、歸納、升級、釘選 |
| `/memory-status` | 顯示統計與最強的記憶 |

CLI（`memory.sh`，Claude 與人都可以直接呼叫）：

```bash
MEM=".claude/os-memory/scripts/memory.sh"   # 或 ~/.claude/os-memory/scripts/memory.sh

bash "$MEM" add --category pitfall --context "detail" "One-sentence lesson"
bash "$MEM" add --scope global --category preference "Applies to every project"
bash "$MEM" reinforce <id>            # 有用 → +1 分、刷新時鐘
bash "$MEM" weaken <id> --reason "…"  # 錯誤 → -1.5 分，歸零即封存
bash "$MEM" forget <id>               # 立即封存
bash "$MEM" pin <id> / unpin <id>     # 豁免衰減／恢復衰減
bash "$MEM" promote <id>              # 專案記憶 → 帳戶記憶
bash "$MEM" recall                    # 印出 digest（session 看到的內容）
bash "$MEM" search "keyword"          # 依內容搜尋
bash "$MEM" list [--all|--archived]   # 表列（含有效強度）
bash "$MEM" stats                     # 統計
bash "$MEM" consolidate               # 手動結算衰減
bash "$MEM" doctor                    # 健康檢查
```

分類：`pitfall`（踩過的坑）、`fix`（修法）、`convention`（慣例）、`preference`（使用者偏好）、`workflow`（工作流）、`fact`（事實）、`insight`（洞見）。

## 設定（config.json）

每層儲存各有一份 `.claude/os-memory/config.json`，可獨立調整：

| 欄位 | 預設 | 意義 |
|---|---|---|
| `score_initial` | 3.0 | 新記憶初始分數 |
| `score_max` | 10.0 | 分數上限 |
| `reinforce_bonus` | 1.0 | 每次強化加分 |
| `weaken_penalty` | 1.5 | 每次削弱扣分（錯誤忘得比較快） |
| `verify_wins` | 2 | candidate 升級 verified 所需強化次數 |
| `half_life_days` | 14 / 90 / 36500 | candidate / verified / pinned 的半衰期 |
| `digest_min_score` | 1.0 | 低於此有效強度就不進 digest |
| `digest_max_entries` | 40 | digest 每層最多幾條 |
| `archive_threshold` | 0.5 | 低於此有效強度就封存 |
| `purge_archive_after_days` | 60 | 封存多久後永久刪除 |
| `consolidate_interval_hours` | 24 | 自動結算間隔 |
| `review_interval_days` | 14 | 幾天沒審查就提示 `/memory-review` |
| `auto_reflect` | true | 是否啟用 Stop hook 自動反思 |
| `reflect_min_transcript_bytes` | 60000 | session 記錄大於此才觸發反思 |
| `max_new_memories_per_session` | 3 | 每 session 建議新增上限（品質重於數量） |

## 資料格式

`memory.jsonl` 一行一條，人類可讀可直接編輯：

```json
{"id":"m260709f425","category":"pitfall","content":"Alembic migrations silently skip tables without a primary key","context":"hit in v2 migration","status":"verified","score":5.0,"wins":2,"losses":0,"created":"2026-07-09T09:00:00Z","reinforced":"2026-07-09T12:00:00Z","scope":"project","project":"myapp"}
```

封存的記憶在 `archive.jsonl`，多了 `archived_at` 與 `archive_reason`（`decayed` / `manual` / `weakened-to-zero`）。

## FAQ

**記憶檔要不要 commit 進 git？**
你決定。commit 的話團隊成員與多台機器可以共享專案記憶；不想的話在專案 `.gitignore` 加：
```
.claude/os-memory/memory.jsonl
.claude/os-memory/archive.jsonl
.claude/os-memory/state.json
```
（本 repo 自身就是這樣設定的，讓範本保持乾淨。）

**token 成本？** digest 有上限（每層 40 條、只取強度夠的），一般是幾百到一兩千 token。衰減結算純腳本、零 token；只有 Stop hook 反思與 `/memory-review` 需要模型參與。

**跟 CLAUDE.md 什麼關係？** CLAUDE.md 放你手寫的固定規則；OS-Memory 放 Claude 自己累積、會驗證與遺忘的動態經驗。兩者互補。

**如何解除安裝？** 刪掉 `.claude/os-memory/`、`.claude/commands/` 裡的五個指令檔、`settings.json` 中兩條 hook、以及 CLAUDE.md 裡 `<!-- os-memory:begin -->` 到 `<!-- os-memory:end -->` 的區塊。

**測試時間衰減？** 用 `OS_MEMORY_NOW`（epoch 秒）覆蓋時鐘：
```bash
OS_MEMORY_NOW=$(( $(date +%s) + 40*86400 )) bash "$MEM" consolidate
```
