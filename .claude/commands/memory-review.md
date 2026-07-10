---
description: Curate OS-Memory — merge duplicates, prune stale entries, promote shared lessons
---
<!-- os-memory:command -->
Run a full memory review — the "consolidation during sleep" step of OS-Memory.

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
