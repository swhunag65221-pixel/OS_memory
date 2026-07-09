#!/usr/bin/env bash
# OS-Memory installer — installs the memory system into a project (.claude/)
# or account-wide (~/.claude/). Both modes are idempotent and can coexist:
# project memories take precedence and merge with account memories at recall.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/.claude"

usage() {
  cat <<'EOF'
OS-Memory installer

Usage:
  ./install.sh --project [DIR]   Install into a project (default: current directory)
  ./install.sh --global          Install account-wide (~/.claude)
  ./install.sh --doctor          Check installation health

Install both to share memories across projects: the project store holds
project-specific lessons, the account store holds lessons shared by all
projects, and every session sees the merge of the two.
EOF
}

err() { printf 'install: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (https://jqlang.org)"
[ -f "$SRC/os-memory/scripts/memory.sh" ] || die "source tree not found next to install.sh"

# merge_hook <settings.json> <event> <command> — append the hook entry unless
# an identical command is already registered.
merge_hook() {
  local f="$1" ev="$2" cmd="$3" tmp
  if [ ! -f "$f" ]; then
    mkdir -p "$(dirname "$f")"
    printf '{}\n' > "$f"
  fi
  jq -e . "$f" >/dev/null 2>&1 || die "$f is not valid JSON — fix it and re-run"
  tmp="$(mktemp)"
  jq --arg ev "$ev" --arg cmd "$cmd" '
    .hooks = (.hooks // {})
    | .hooks[$ev] = (.hooks[$ev] // [])
    | if ([.hooks[$ev][]?.hooks[]?.command] | index($cmd)) then .
      else .hooks[$ev] += [{hooks: [{type: "command", command: $cmd}]}] end' \
    "$f" > "$tmp" && mv "$tmp" "$f"
}

# append_claude_md <CLAUDE.md path> — add the OS-Memory block once.
append_claude_md() {
  local f="$1"
  if [ -f "$f" ] && grep -qF '<!-- os-memory:begin -->' "$f"; then
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  cat >> "$f" <<'EOF'

<!-- os-memory:begin -->
## OS-Memory (long-term memory)

This environment uses OS-Memory: decaying long-term memory injected as a digest
at session start. While working, maintain it — reinforce memories that helped,
weaken ones that proved wrong, and add at most a few genuinely durable lessons
per session using the memory script shown in the digest. Slash commands:
/remember, /reflect, /forget, /memory-review, /memory-status.
<!-- os-memory:end -->
EOF
}

# install_into <claude_dir> <path_prefix_literal> <claude_md> <scope label>
install_into() {
  local cdir="$1" prefix="$2" cmd_md="$3" scope="$4" f

  mkdir -p "$cdir/os-memory/scripts" "$cdir/commands"
  cp "$SRC/os-memory/scripts/memory.sh" "$cdir/os-memory/scripts/memory.sh"
  chmod +x "$cdir/os-memory/scripts/memory.sh"
  # Never overwrite an existing config or data files.
  [ -f "$cdir/os-memory/config.json" ] || cp "$SRC/os-memory/config.json" "$cdir/os-memory/config.json"
  touch "$cdir/os-memory/memory.jsonl" "$cdir/os-memory/archive.jsonl"
  [ -f "$cdir/os-memory/state.json" ] || printf '{}\n' > "$cdir/os-memory/state.json"

  for f in "$SRC"/commands/*.md; do
    cp "$f" "$cdir/commands/$(basename "$f")"
  done

  merge_hook "$cdir/settings.json" SessionStart \
    "bash \"$prefix/.claude/os-memory/scripts/memory.sh\" hook-session-start"
  merge_hook "$cdir/settings.json" Stop \
    "bash \"$prefix/.claude/os-memory/scripts/memory.sh\" hook-stop"

  append_claude_md "$cmd_md"

  echo "OS-Memory installed ($scope):"
  echo "  store:    $cdir/os-memory"
  echo "  commands: $cdir/commands/{remember,reflect,forget,memory-review,memory-status}.md"
  echo "  hooks:    $cdir/settings.json (SessionStart, Stop)"
  echo "  notes:    $cmd_md"
}

case "${1:-}" in
  --project)
    shift
    TARGET="${1:-$PWD}"
    [ -d "$TARGET" ] || die "no such directory: $TARGET"
    TARGET="$(cd "$TARGET" && pwd)"
    [ "$TARGET" != "$HOME" ] || die "use --global to install account-wide"
    install_into "$TARGET/.claude" '$CLAUDE_PROJECT_DIR' "$TARGET/CLAUDE.md" "project: $TARGET"
    echo
    echo "New Claude Code sessions in this project now load and maintain memory automatically."
    ;;
  --global)
    install_into "$HOME/.claude" '$HOME' "$HOME/.claude/CLAUDE.md" "account-wide"
    echo
    echo "New Claude Code sessions in every project now load and maintain memory automatically."
    ;;
  --doctor)
    exec bash "$SRC/os-memory/scripts/memory.sh" doctor
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
