---
description: Curate OS-Memory — merge duplicates, prune stale entries, promote shared lessons
---
Run a full memory review — the "consolidation during sleep" step of OS-Memory.

1. Locate the memory script:
   ```bash
   MEM="$CLAUDE_PROJECT_DIR/.claude/os-memory/scripts/memory.sh"
   [ -f "$MEM" ] || MEM="$HOME/.claude/os-memory/scripts/memory.sh"
   ```
2. Get the full picture:
   ```bash
   bash "$MEM" stats
   bash "$MEM" list --all
   ```
3. Curate every active memory (both project and global stores):
   - **Merge near-duplicates**: keep one canonical phrasing. If none of the
     duplicates is well phrased, `add` a rewritten canonical version, then
     `forget` the redundant ones.
   - **Prune**: `weaken` (doubtful) or `forget` (clearly wrong/stale/too
     session-specific) entries that no longer earn their place.
   - **Generalize**: if several memories are instances of one underlying rule,
     `add` the general rule and `forget` the specific instances.
   - **Promote**: project memories valuable to every project →
     `bash "$MEM" promote <id>` (moves to the account-wide store).
   - **Pin sparingly**: only critical invariants that must never decay →
     `bash "$MEM" pin <id>`.
   - **Reinforce** entries you can verify are still true and valuable.
4. Apply decay and record the review:
   ```bash
   bash "$MEM" consolidate
   bash "$MEM" mark-reviewed
   ```
5. Report a summary: counts of kept / merged / weakened / forgotten / promoted /
   pinned, and anything surprising you found.
