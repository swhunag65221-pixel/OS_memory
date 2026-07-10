---
description: Reflect on this session and update OS-Memory (reinforce / weaken / add)
---
<!-- os-memory:command -->
Reflect on the current session and update long-term memory.

1. Locate the memory script — walk up from the current directory (note:
   $CLAUDE_PROJECT_DIR is usually NOT set in this environment), then fall back
   to the account-wide install:
   ```bash
   d="${CLAUDE_PROJECT_DIR:-$PWD}"; MEM=""
   while [ -n "$d" ] && [ "$d" != "/" ]; do
     [ -f "$d/.claude/os-memory/scripts/memory.sh" ] && { MEM="$d/.claude/os-memory/scripts/memory.sh"; break; }
     d="$(dirname "$d")"
   done
   [ -n "$MEM" ] || MEM="$HOME/.claude/os-memory/scripts/memory.sh"
   ```
2. Re-examine the memory digest injected at session start:
   - For every memory that actually helped this session: `bash "$MEM" reinforce <id>`
   - For every memory that proved wrong or outdated: `bash "$MEM" weaken <id> --reason "why"`
3. Extract at most 3 durable lessons from this session — pitfalls you hit and
   their fixes, corrections from the user, verified project facts, conventions,
   workflow insights. For each one:
   ```bash
   bash "$MEM" add --category <pitfall|fix|convention|preference|workflow|fact|insight> [--scope global] [--context "detail"] -- "<one-sentence lesson in English>"
   ```
   Quality bar: skip trivia, session-specific details, and anything already in
   the digest. Fewer, better memories beat many weak ones.
4. Run `bash "$MEM" consolidate` and note its summary.
5. Report to the user, briefly: which memories were reinforced, weakened, and
   added (with ids), plus the consolidation summary.
