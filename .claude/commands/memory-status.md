---
description: Show OS-Memory statistics and the strongest memories
---
<!-- os-memory:command -->
Show the current state of OS-Memory.

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
2. Gather data:
   ```bash
   bash "$MEM" stats
   bash "$MEM" list
   ```
3. Present to the user, concisely:
   - Counts per store (project / global) by status and category
   - Last consolidation and last review times; note if a /memory-review is overdue
   - The top ~10 memories by effective score
   - Anything notable (e.g. many candidates never verified, a large archive)
