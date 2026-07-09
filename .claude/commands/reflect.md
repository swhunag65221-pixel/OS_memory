---
description: Reflect on this session and update OS-Memory (reinforce / weaken / add)
---
Reflect on the current session and update long-term memory.

1. Locate the memory script:
   ```bash
   MEM="$CLAUDE_PROJECT_DIR/.claude/os-memory/scripts/memory.sh"
   [ -f "$MEM" ] || MEM="$HOME/.claude/os-memory/scripts/memory.sh"
   ```
2. Re-examine the memory digest injected at session start:
   - For every memory that actually helped this session: `bash "$MEM" reinforce <id>`
   - For every memory that proved wrong or outdated: `bash "$MEM" weaken <id> --reason "why"`
3. Extract at most 3 durable lessons from this session — pitfalls you hit and
   their fixes, corrections from the user, verified project facts, conventions,
   workflow insights. For each one:
   ```bash
   bash "$MEM" add --category <pitfall|fix|convention|preference|workflow|fact|insight> [--scope global] [--context "detail"] "<one-sentence lesson in English>"
   ```
   Quality bar: skip trivia, session-specific details, and anything already in
   the digest. Fewer, better memories beat many weak ones.
4. Run `bash "$MEM" consolidate` and note its summary.
5. Report to the user, briefly: which memories were reinforced, weakened, and
   added (with ids), plus the consolidation summary.
