---
description: Save a durable lesson to OS-Memory (long-term memory)
argument-hint: <lesson to remember>
---
Save the following as a long-term OS-Memory entry: $ARGUMENTS

Follow these steps:

1. Locate the memory script (project store first, then account store):
   ```bash
   MEM="$CLAUDE_PROJECT_DIR/.claude/os-memory/scripts/memory.sh"
   [ -f "$MEM" ] || MEM="$HOME/.claude/os-memory/scripts/memory.sh"
   ```
2. Distill the input into ONE self-contained English sentence — actionable and
   understandable without this session's context. Put extra detail in `--context`.
3. Pick a category: `pitfall` | `fix` | `convention` | `preference` | `workflow` | `fact` | `insight`.
4. Pick the scope: project-specific knowledge → default (project store);
   useful across all projects → add `--scope global`.
5. Run:
   ```bash
   bash "$MEM" add --category <category> [--scope global] [--context "<detail>"] "<lesson>"
   ```
6. Report the resulting memory id to the user. If the script reports that an
   identical memory was reinforced instead, say so.

If $ARGUMENTS is empty: review the current session, propose 1–3 candidate
lessons to the user, ask which to save, then save the chosen ones.
