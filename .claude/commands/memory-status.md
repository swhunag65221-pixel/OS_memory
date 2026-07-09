---
description: Show OS-Memory statistics and the strongest memories
---
Show the current state of OS-Memory.

1. Locate the memory script:
   ```bash
   MEM="$CLAUDE_PROJECT_DIR/.claude/os-memory/scripts/memory.sh"
   [ -f "$MEM" ] || MEM="$HOME/.claude/os-memory/scripts/memory.sh"
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
