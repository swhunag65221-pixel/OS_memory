---
description: Weaken or remove a memory from OS-Memory
argument-hint: <memory id or description of what to forget>
---
<!-- os-memory:command -->
The user wants to forget a memory: $ARGUMENTS

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
2. If $ARGUMENTS looks like a memory id (starts with `m` followed by digits/hex),
   use it directly. Otherwise find it:
   ```bash
   bash "$MEM" search "<keywords>"
   ```
   If several entries match and the choice is not obvious, ask the user which one.
3. Choose the right operation:
   - Clearly wrong, harmful, or explicitly to be removed → `bash "$MEM" forget <id>`
     (archives immediately; permanently purged after the grace period)
   - Merely doubtful or weakened trust → `bash "$MEM" weaken <id> --reason "why"`
   - Pinned memories refuse both — run `bash "$MEM" unpin <id>` first, and only
     if the user confirms the invariant no longer holds.
4. Report what was done and to which memory.
