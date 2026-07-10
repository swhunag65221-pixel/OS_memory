#!/usr/bin/env bash
# OS-Memory — portable long-term memory for Claude Code with human-like decay.
#
# Memories live as JSONL records in two stores that merge at recall time:
#   project store: <project>/.claude/os-memory/   (takes precedence)
#   account store: ~/.claude/os-memory/           (shared across projects)
#
# Each record carries a score. Effective strength decays exponentially:
#   eff = score * 0.5 ^ (days_since_reinforced / half_life(status))
# Reinforcement (memory proved useful) refreshes the clock and raises score;
# weakening (memory proved wrong) lowers it. Consolidation archives entries
# whose effective strength falls below a threshold, and permanently purges
# archived entries after a grace period — a two-stage forgetting curve.
#
# Requires: bash 3.2+, jq 1.6+ (round, try/catch).

set -euo pipefail

OSM_VERSION="1.1.0"

err() { printf 'os-memory: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

HAS_JQ=1
command -v jq >/dev/null 2>&1 || HAS_JQ=0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/memory.sh"

# OS_MEMORY_NOW (epoch seconds) overrides the clock — used by tests to
# simulate the passage of time.
NOW_EPOCH="${OS_MEMORY_NOW:-$(date +%s)}"
NOW_ISO="$(date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
ID_DATE="$(date -u -d "@$NOW_EPOCH" +%y%m%d 2>/dev/null \
        || date -u -r "$NOW_EPOCH" +%y%m%d)"

# Single source of truth for memory categories — used by validation, the
# digest ordering, and every instruction string shown to the model.
CATEGORIES="pitfall fix convention preference workflow fact insight"
CATEGORIES_PIPE="$(printf '%s' "$CATEGORIES" | tr ' ' '|')"

GLOBAL_STORE="${OS_MEMORY_GLOBAL_DIR:-$HOME/.claude/os-memory}"

find_project_store() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] \
     && [ -d "$CLAUDE_PROJECT_DIR/.claude/os-memory" ] \
     && [ "$CLAUDE_PROJECT_DIR/.claude/os-memory" != "$GLOBAL_STORE" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR/.claude/os-memory"
    return 0
  fi
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -d "$d/.claude/os-memory" ] && [ "$d/.claude/os-memory" != "$GLOBAL_STORE" ]; then
      printf '%s\n' "$d/.claude/os-memory"
      return 0
    fi
    d="$(dirname "$d")"
  done
  printf ''
}
PROJECT_STORE="$(find_project_store)"

project_name() {
  [ -n "$PROJECT_STORE" ] || { printf '-'; return; }
  basename "$(dirname "$(dirname "$PROJECT_STORE")")"
}

store_label() {
  if [ "$1" = "$GLOBAL_STORE" ]; then printf 'global'; else printf 'project'; fi
}

ensure_store() {
  mkdir -p "$1"
  touch "$1/memory.jsonl" "$1/archive.jsonl"
  [ -f "$1/state.json" ] || printf '{}\n' > "$1/state.json"
}

count_lines() {
  if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else printf '0'; fi
}

load_config() {
  local f="$1/config.json" user='{}'
  if [ -f "$f" ]; then
    # -e turns a null output (valid JSON but not an object) into a nonzero
    # exit, so both parse errors and wrong-type configs fall back to defaults
    if ! user="$(jq -c -e 'if type == "object" then . else null end' "$f" 2>/dev/null)"; then
      err "warning: invalid config.json in $f (must be a JSON object) — using defaults"
      user='{}'
    fi
  fi
  jq -c -n --argjson u "$user" '{
    score_initial: 3.0,
    score_max: 10.0,
    reinforce_bonus: 1.0,
    weaken_penalty: 1.5,
    verify_wins: 2,
    half_life_days: {candidate: 14, verified: 90, pinned: 36500},
    digest_min_score: 1.0,
    digest_max_entries: 40,
    archive_threshold: 0.5,
    purge_archive_after_days: 60,
    consolidate_interval_hours: 24,
    review_interval_days: 14,
    auto_reflect: true,
    reflect_min_transcript_bytes: 60000,
    max_new_memories_per_session: 3
  } * $u'
}

# Shared jq definitions. Callers must pass --argjson cfg and --argjson now.
# A record with a missing or malformed timestamp gets age 0 (full strength)
# instead of aborting the whole pass — surfacing beats bricking recall.
JQ_DEFS='
def hl: ($cfg.half_life_days[.status] // $cfg.half_life_days.candidate);
def ts: (((.reinforced // .created // "") | tostring | (try fromdateiso8601 catch null)) // $now);
def age_days: (($now - ts) / 86400);
def eff: if .status == "pinned" then .score
         else .score * ((age_days / hl) * -0.6931471805599453 | exp) end;
def keep: (.status == "pinned" or eff >= $cfg.archive_threshold);
'

# Prints the marker directory, or fails (rc=1) when it cannot be created or
# written (e.g. pre-owned by another user on a shared machine). Callers must
# degrade gracefully — markers must never break the user's session.
markers_dir() {
  local d="${TMPDIR:-/tmp}/os-memory-$(id -u 2>/dev/null || echo 0)"
  mkdir -p "$d" 2>/dev/null || return 1
  [ -w "$d" ] || return 1
  printf '%s\n' "$d"
}

# rewrite <store> <jq-filter-over-slurped-array> [jq args...]
rewrite() {
  local store="$1" filter="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  if jq -s -c "$@" "$filter | .[]" "$store/memory.jsonl" > "$tmp"; then
    mv "$tmp" "$store/memory.jsonl"
  else
    rm -f "$tmp"
    die "internal error: jq rewrite failed"
  fi
}

set_state() { # <store> <key>  — sets key to NOW_ISO in state.json
  local store="$1" key="$2" tmp
  tmp="$(mktemp)"
  jq --arg v "$NOW_ISO" ".$key = \$v" "$store/state.json" > "$tmp" && mv "$tmp" "$store/state.json"
}

id_count() { # <id> <store>
  jq -s --arg id "$1" 'map(select(.id == $id)) | length' "$2/memory.jsonl"
}

store_of_id() { # <id> → prints store path, rc=1 if not found
  local s found=""
  for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
    [ -n "$s" ] && [ -f "$s/memory.jsonl" ] || continue
    if [ "$(id_count "$1" "$s")" -gt 0 ]; then
      if [ -z "$found" ]; then
        found="$s"
      else
        err "warning: $1 exists in both stores — operating on the $(store_label "$found") copy"
      fi
    fi
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

gen_id() { # ids must be unique across BOTH stores — mutations match by id
  local id s taken
  while :; do
    id="m${ID_DATE}$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    taken=0
    for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
      [ -n "$s" ] && [ -f "$s/memory.jsonl" ] || continue
      [ "$(id_count "$id" "$s")" -eq 0 ] || { taken=1; break; }
    done
    if [ "$taken" -eq 0 ]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
}

archive_id() { # <store> <id> <reason>
  local store="$1" id="$2" reason="$3"
  jq -s -c --arg id "$id" --arg iso "$NOW_ISO" --arg r "$reason" \
    'map(select(.id == $id) | . + {archived_at: $iso, archive_reason: $r}) | .[]' \
    "$store/memory.jsonl" >> "$store/archive.jsonl"
  rewrite "$store" 'map(select(.id != $id))' --arg id "$id"
}

# ---------------------------------------------------------------- commands

cmd_add() {
  local scope="auto" category="insight" context="" status="candidate" content=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)         scope="$2"; shift 2 ;;
      --category|-c)   category="$2"; shift 2 ;;
      --context)       context="$2"; shift 2 ;;
      --status)        status="$2"; shift 2 ;;
      --)              shift
                       while [ $# -gt 0 ]; do
                         if [ -z "$content" ]; then content="$1"; else content="$content $1"; fi
                         shift
                       done ;;
      --*)             die "add: unknown flag: $1 (put -- before content that starts with a dash)" ;;
      *)               if [ -z "$content" ]; then content="$1"; else content="$content $1"; fi; shift ;;
    esac
  done
  [ -n "$content" ] || die 'add: content required — memory.sh add [--category CAT] "lesson"'

  category="$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')"
  case " $CATEGORIES " in
    *" $category "*) ;;
    *) err "note: non-standard category '$category' (standard: $CATEGORIES)" ;;
  esac
  case "$status" in
    candidate|verified|pinned) ;;
    *) die "add: --status must be candidate|verified|pinned" ;;
  esac

  local store
  case "$scope" in
    global)  store="$GLOBAL_STORE" ;;
    project) [ -n "$PROJECT_STORE" ] || die "add: no project store found (run install.sh --project first)"
             store="$PROJECT_STORE" ;;
    auto)    if [ -n "$PROJECT_STORE" ]; then store="$PROJECT_STORE"; else store="$GLOBAL_STORE"; fi ;;
    *)       die "add: --scope must be project|global" ;;
  esac
  ensure_store "$store"

  local dup
  dup="$(jq -s -r --arg c "$content" 'map(select(.content == $c)) | first | .id // empty' "$store/memory.jsonl")"
  if [ -n "$dup" ]; then
    err "identical memory already exists ($dup) — reinforcing it instead"
    cmd_reinforce "$dup"
    return 0
  fi

  local cfg scope_val proj id
  cfg="$(load_config "$store")"
  if [ "$store" = "$GLOBAL_STORE" ]; then scope_val="global"; proj="-"; else scope_val="project"; proj="$(project_name)"; fi
  id="$(gen_id "$store")"
  jq -c -n \
    --arg id "$id" --arg cat "$category" --arg content "$content" --arg context "$context" \
    --arg status "$status" --arg iso "$NOW_ISO" --arg scope "$scope_val" --arg proj "$proj" \
    --argjson score "$(jq -r '.score_initial' <<<"$cfg")" \
    '{id: $id, category: $cat, content: $content,
      context: (if $context == "" then null else $context end),
      status: $status, score: $score, wins: 0, losses: 0,
      created: $iso, reinforced: $iso, scope: $scope, project: $proj}' \
    >> "$store/memory.jsonl"
  echo "added $id [$scope_val/$category/$status] $content"
}

cmd_reinforce() {
  local id="${1:-}"
  [ -n "$id" ] || die "reinforce: id required"
  local store
  store="$(store_of_id "$id")" || die "reinforce: memory not found: $id"
  local cfg; cfg="$(load_config "$store")"
  rewrite "$store" '
    map(if .id == $id then
      .score = ([(.score + $cfg.reinforce_bonus), $cfg.score_max] | min)
      | .wins += 1
      | .reinforced = $iso
      | .status = (if .status == "candidate" and .wins >= $cfg.verify_wins then "verified" else .status end)
    else . end)' \
    --arg id "$id" --arg iso "$NOW_ISO" --argjson cfg "$cfg"
  jq -s -r --arg id "$id" \
    'map(select(.id == $id)) | .[0] | "reinforced \(.id) → score \(.score), wins \(.wins), status \(.status)"' \
    "$store/memory.jsonl"
}

cmd_weaken() {
  local id="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      --*)      die "weaken: unknown flag: $1" ;;
      *)        id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "weaken: id required"
  local store
  store="$(store_of_id "$id")" || die "weaken: memory not found: $id"
  # honour the documented guarantee: pinned memories are never archived/purged
  if [ "$(jq -s -r --arg id "$id" 'map(select(.id == $id)) | .[0].status' "$store/memory.jsonl")" = "pinned" ]; then
    die "weaken: $id is pinned — pinned memories never decay or get archived; run 'unpin $id' first"
  fi
  local cfg; cfg="$(load_config "$store")"
  rewrite "$store" '
    map(if .id == $id then
      .score = ([(.score - $cfg.weaken_penalty), 0] | max)
      | .losses += 1
      | .last_weaken_reason = (if $reason == "" then .last_weaken_reason else $reason end)
    else . end)' \
    --arg id "$id" --arg reason "$reason" --argjson cfg "$cfg"
  local newscore
  newscore="$(jq -s -r --arg id "$id" 'map(select(.id == $id)) | .[0].score' "$store/memory.jsonl")"
  if awk -v s="$newscore" 'BEGIN { exit !(s <= 0) }'; then
    archive_id "$store" "$id" "weakened-to-zero"
    echo "weakened $id → score 0 — forgotten (archived)"
  else
    echo "weakened $id → score $newscore"
  fi
}

cmd_forget() {
  local id="${1:-}"
  [ -n "$id" ] || die "forget: id required"
  local store
  store="$(store_of_id "$id")" || die "forget: memory not found: $id"
  if [ "$(jq -s -r --arg id "$id" 'map(select(.id == $id)) | .[0].status' "$store/memory.jsonl")" = "pinned" ]; then
    die "forget: $id is pinned — run 'unpin $id' first, then forget it"
  fi
  archive_id "$store" "$id" "manual"
  echo "forgot $id (archived; purged permanently after grace period)"
}

cmd_pin() {
  local id="${1:-}"
  [ -n "$id" ] || die "pin: id required"
  local store
  store="$(store_of_id "$id")" || die "pin: memory not found: $id"
  rewrite "$store" 'map(if .id == $id then .status = "pinned" else . end)' --arg id "$id"
  echo "pinned $id (exempt from decay)"
}

cmd_unpin() {
  local id="${1:-}"
  [ -n "$id" ] || die "unpin: id required"
  local store
  store="$(store_of_id "$id")" || die "unpin: memory not found: $id"
  # restart the decay clock — otherwise the whole pinned period counts as
  # elapsed decay time and the next consolidate archives the entry instantly
  rewrite "$store" 'map(if .id == $id then .status = "verified" | .reinforced = $iso else . end)' \
    --arg id "$id" --arg iso "$NOW_ISO"
  echo "unpinned $id (now verified; decay clock restarted)"
}

cmd_promote() {
  local id="${1:-}"
  [ -n "$id" ] || die "promote: id required"
  [ -n "$PROJECT_STORE" ] || die "promote: no project store found"
  [ "$(id_count "$id" "$PROJECT_STORE")" -gt 0 ] || die "promote: $id not found in project store"
  ensure_store "$GLOBAL_STORE"
  local content dup
  content="$(jq -s -r --arg id "$id" 'map(select(.id == $id)) | .[0].content' "$PROJECT_STORE/memory.jsonl")"
  dup="$(jq -s -r --arg c "$content" 'map(select(.content == $c)) | first | .id // empty' "$GLOBAL_STORE/memory.jsonl")"
  if [ -n "$dup" ]; then
    rewrite "$PROJECT_STORE" 'map(select(.id != $id))' --arg id "$id"
    err "identical global memory exists ($dup) — merged: removed project copy, reinforcing global"
    cmd_reinforce "$dup"
    return 0
  fi
  local newid="$id"
  if [ "$(id_count "$id" "$GLOBAL_STORE")" -gt 0 ]; then
    # same id already lives in the global store (e.g. via a git-synced project
    # file) — renaming avoids one id addressing two unrelated records
    newid="$(gen_id "$GLOBAL_STORE")"
    err "note: $id already exists in the global store — promoted copy renamed to $newid"
  fi
  jq -s -c --arg id "$id" --arg newid "$newid" \
    'map(select(.id == $id) | .id = $newid | .scope = "global" | .project = "-") | .[]' \
    "$PROJECT_STORE/memory.jsonl" >> "$GLOBAL_STORE/memory.jsonl"
  rewrite "$PROJECT_STORE" 'map(select(.id != $id))' --arg id "$id"
  echo "promoted $newid to account-wide memory (shared across projects)"
}

consolidate_store() { # <store> <auto:0|1> <quiet:0|1> [cfg-json]
  local store="$1" auto="$2" quiet="$3" cfg="${4:-}"
  [ -d "$store" ] || return 0
  ensure_store "$store"
  [ -n "$cfg" ] || cfg="$(load_config "$store")"

  if [ "$auto" = "1" ]; then
    local last interval_h last_epoch age_h
    last="$(jq -r '.last_consolidated // empty' "$store/state.json" 2>/dev/null || true)"
    if [ -n "$last" ]; then
      interval_h="$(jq -r '.consolidate_interval_hours' <<<"$cfg")"
      last_epoch="$(jq -n -r --arg t "$last" '$t | fromdateiso8601' 2>/dev/null || echo 0)"
      age_h=$(( (NOW_EPOCH - last_epoch) / 3600 ))
      [ "$age_h" -lt "$interval_h" ] && return 0
    fi
  fi

  local tmp_keep tmp_arch archived kept
  tmp_keep="$(mktemp)"; tmp_arch="$(mktemp)"
  jq -s -c --argjson cfg "$cfg" --argjson now "$NOW_EPOCH" "$JQ_DEFS"'
    .[] | select(keep)' \
    "$store/memory.jsonl" > "$tmp_keep"
  jq -s -c --argjson cfg "$cfg" --argjson now "$NOW_EPOCH" --arg iso "$NOW_ISO" "$JQ_DEFS"'
    .[] | select(keep | not)
        | . + {archived_at: $iso, archive_reason: "decayed"}' \
    "$store/memory.jsonl" > "$tmp_arch"
  archived="$(count_lines "$tmp_arch")"
  cat "$tmp_arch" >> "$store/archive.jsonl"
  mv "$tmp_keep" "$store/memory.jsonl"
  rm -f "$tmp_arch"
  kept="$(count_lines "$store/memory.jsonl")"

  local arch_before arch_after purged tmp_purge
  arch_before="$(count_lines "$store/archive.jsonl")"
  tmp_purge="$(mktemp)"
  jq -s -c --argjson cfg "$cfg" --argjson now "$NOW_EPOCH" '
    .[] | select((($now - (((.archived_at // .created // "") | tostring
                            | (try fromdateiso8601 catch null)) // $now)) / 86400)
                 <= $cfg.purge_archive_after_days)' \
    "$store/archive.jsonl" > "$tmp_purge"
  mv "$tmp_purge" "$store/archive.jsonl"
  arch_after="$(count_lines "$store/archive.jsonl")"
  purged=$(( arch_before - arch_after ))

  set_state "$store" last_consolidated
  if [ "$quiet" != "1" ]; then
    echo "consolidated $(store_label "$store") store: kept $kept, archived $archived, purged $purged"
  fi
}

cmd_consolidate() {
  local quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=1; shift ;;
      *)       die "consolidate: unknown argument: $1 (manual consolidate always runs immediately)" ;;
    esac
  done
  local ran=0 s
  for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
    [ -n "$s" ] && [ -d "$s" ] || continue
    consolidate_store "$s" 0 "$quiet"
    ran=1
  done
  [ "$ran" = "1" ] || err "no memory store found — nothing to consolidate"
}

digest_store() { # <store> <title> [cfg-json]
  local store="$1" title="$2" cfg="${3:-}"
  [ -s "$store/memory.jsonl" ] || return 0
  local body
  [ -n "$cfg" ] || cfg="$(load_config "$store")"
  body="$(jq -s -r --argjson cfg "$cfg" --argjson now "$NOW_EPOCH" --arg cats "$CATEGORIES" "$JQ_DEFS"'
    ($cats | split(" ")) as $order
    | map(. + {eff: eff})
    | map(select(.status == "pinned" or .eff >= $cfg.digest_min_score))
    | sort_by(-.eff)
    # pinned entries are never cut by the cap; remaining slots go to the strongest rest
    | (map(select(.status == "pinned"))) as $pinned
    | ($pinned + (map(select(.status != "pinned"))
                  | .[0:([($cfg.digest_max_entries - ($pinned | length)), 0] | max)]))
    | group_by(.category)
    | sort_by(.[0].category as $c | (($order | index($c)) // 99))
    | map("### " + .[0].category + "\n"
        + (map("- [" + .id + " | " + .status + " | "
               + ((((.eff * 10) | round) / 10) | tostring) + "] " + .content
               + (if (.context // "") != "" then " — " + .context else "" end))
           | join("\n")))
    | join("\n\n")' \
    "$store/memory.jsonl")"
  [ -n "$body" ] || return 0
  printf '## %s\n\n%s\n\n' "$title" "$body"
}

review_notice() { # <store> [cfg-json]
  local store="$1" cfg="${2:-}"
  [ -s "$store/memory.jsonl" ] || return 0
  local count interval last
  count="$(count_lines "$store/memory.jsonl")"
  [ "$count" -ge 5 ] || return 0
  [ -n "$cfg" ] || cfg="$(load_config "$store")"
  interval="$(jq -r '.review_interval_days' <<<"$cfg")"
  last="$(jq -r '.last_review // empty' "$store/state.json" 2>/dev/null || true)"
  if [ -z "$last" ]; then
    echo "NOTE: $(store_label "$store") store has $count memories and has never been reviewed — consider running /memory-review."
    return 0
  fi
  local last_epoch days
  last_epoch="$(jq -n -r --arg t "$last" '$t | fromdateiso8601' 2>/dev/null || echo 0)"
  days=$(( (NOW_EPOCH - last_epoch) / 86400 ))
  if [ "$days" -ge "$interval" ]; then
    echo "NOTE: $(store_label "$store") store was last reviewed $days days ago — consider running /memory-review."
  fi
}

cmd_recall() {
  [ $# -eq 0 ] || die "recall: unknown argument: $1"

  local stores=() titles=()
  if [ -n "$PROJECT_STORE" ]; then
    stores+=("$PROJECT_STORE")
    titles+=("Project memories ($(project_name))")
  fi
  if [ -d "$GLOBAL_STORE" ] && [ "$GLOBAL_STORE" != "$PROJECT_STORE" ]; then
    stores+=("$GLOBAL_STORE")
    titles+=("Account-wide memories (shared across projects)")
  fi
  [ "${#stores[@]}" -gt 0 ] || return 0

  local i sections="" notices="" n body maxnew cfg cfg_first=""
  for i in "${!stores[@]}"; do
    # load each store's config once and pass it down — this path runs at
    # every session start, so redundant jq spawns directly cost startup time
    cfg="$(load_config "${stores[$i]}")"
    [ -n "$cfg_first" ] || cfg_first="$cfg"
    consolidate_store "${stores[$i]}" 1 1 "$cfg"
    # command substitution strips trailing newlines — re-add the separator
    body="$(digest_store "${stores[$i]}" "${titles[$i]}" "$cfg")"
    [ -n "$body" ] && sections="$sections$body

"
    n="$(review_notice "${stores[$i]}" "$cfg")" || true
    [ -n "$n" ] && notices="$notices$n
"
  done
  [ -n "$sections" ] || { [ -n "$notices" ] && printf '%s' "$notices"; return 0; }

  maxnew="$(jq -r '.max_new_memories_per_session' <<<"$cfg_first")"

  cat <<EOF
<os-memory-digest>
# Long-term memory (OS-Memory v$OSM_VERSION)

Persistent memories from past sessions, strongest first. Maintain them while
you work — this is how learning happens:
- A memory below proved helpful → bash "$SELF" reinforce <id>
- A memory below is wrong or outdated → bash "$SELF" weaken <id> --reason "why"
- You learned a durable, non-obvious lesson (max $maxnew per session; skip trivia) →
  bash "$SELF" add --category <$CATEGORIES_PIPE> [--scope global] [--context "detail"] -- "<one-sentence lesson in English>"
Slash commands: /remember /reflect /forget /memory-review /memory-status

$sections${notices}</os-memory-digest>
EOF
}

cmd_search() {
  local q="${1:-}"
  [ -n "$q" ] || die "search: query required"
  local s found=0
  for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
    [ -n "$s" ] && [ -s "$s/memory.jsonl" ] || continue
    local out
    out="$(jq -s -r --arg q "$q" '
      map(select(((.content + " " + (.context // "") + " " + .category) | ascii_downcase)
                 | contains($q | ascii_downcase)))
      | .[] | "\(.id)\t\(.status)\t\(.category)\t\(.content)"' \
      "$s/memory.jsonl")"
    if [ -n "$out" ]; then
      echo "== $(store_label "$s") store"
      printf '%s\n' "$out"
      found=1
    fi
  done
  [ "$found" = "1" ] || echo "no active memories match: $q"
}

cmd_list() {
  local mode="active"
  while [ $# -gt 0 ]; do
    case "$1" in
      --archived) mode="archived"; shift ;;
      --all)      mode="all"; shift ;;
      *)          shift ;;
    esac
  done
  local s cfg
  for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
    [ -n "$s" ] && [ -d "$s" ] || continue
    cfg="$(load_config "$s")"
    echo "== $(store_label "$s") store: $s"
    if [ "$mode" = "active" ] || [ "$mode" = "all" ]; then
      if [ -s "$s/memory.jsonl" ]; then
        {
          printf 'ID\tSTATUS\tEFF\tSCORE\tW/L\tCATEGORY\tCONTENT\n'
          jq -s -r --argjson cfg "$cfg" --argjson now "$NOW_EPOCH" "$JQ_DEFS"'
            map(. + {eff: eff}) | sort_by(-.eff) | .[]
            | [.id, .status,
               ((((.eff * 100) | round) / 100) | tostring),
               ((((.score * 100) | round) / 100) | tostring),
               "\(.wins)/\(.losses)", .category,
               (.content | if length > 80 then .[0:77] + "..." else . end)]
            | @tsv' "$s/memory.jsonl"
        } | expand_table
      else
        echo "  (no active memories)"
      fi
    fi
    if [ "$mode" = "archived" ] || [ "$mode" = "all" ]; then
      echo "-- archived:"
      if [ -s "$s/archive.jsonl" ]; then
        {
          printf 'ID\tARCHIVED\tREASON\tCATEGORY\tCONTENT\n'
          jq -s -r '
            sort_by(.archived_at) | reverse | .[]
            | [.id, (.archived_at // "-"), (.archive_reason // "-"), .category,
               (.content | if length > 80 then .[0:77] + "..." else . end)]
            | @tsv' "$s/archive.jsonl"
        } | expand_table
      else
        echo "  (empty)"
      fi
    fi
    echo
  done
}

expand_table() {
  if command -v column >/dev/null 2>&1; then
    column -t -s "$(printf '\t')"
  else
    cat
  fi
}

cmd_stats() {
  local s
  for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
    [ -n "$s" ] && [ -d "$s" ] || continue
    ensure_store "$s"
    local cfg; cfg="$(load_config "$s")"
    echo "== $(store_label "$s") store: $s"
    jq -s -r --argjson cfg "$cfg" --argjson now "$NOW_EPOCH" "$JQ_DEFS"'
      "  active: \(length)  (pinned \(map(select(.status == "pinned")) | length), verified \(map(select(.status == "verified")) | length), candidate \(map(select(.status == "candidate")) | length))",
      "  avg effective score: \(if length > 0 then (((map(eff) | add / length) * 100 | round) / 100) else 0 end)",
      "  by category: \(group_by(.category) | map("\(.[0].category)=\(length)") | join(", ") | if . == "" then "-" else . end)"' \
      "$s/memory.jsonl"
    echo "  archived: $(count_lines "$s/archive.jsonl")"
    jq -r '"  last consolidated: \(.last_consolidated // "never")",
           "  last reviewed: \(.last_review // "never")"' "$s/state.json"
    echo
  done
}

cmd_mark_reviewed() {
  local s ran=0
  for s in "$PROJECT_STORE" "$GLOBAL_STORE"; do
    [ -n "$s" ] && [ -d "$s" ] || continue
    ensure_store "$s"
    set_state "$s" last_review
    echo "marked $(store_label "$s") store as reviewed ($NOW_ISO)"
    ran=1
  done
  [ "$ran" = "1" ] || err "no memory store found"
}

cmd_doctor() {
  echo "OS-Memory v$OSM_VERSION"
  if [ "$HAS_JQ" = "1" ]; then
    echo "jq: $(jq --version)"
  else
    echo "jq: MISSING — required; hooks are silently disabled until installed (https://jqlang.org)"
    return 0
  fi
  echo "clock: $NOW_ISO"
  if [ -n "$PROJECT_STORE" ]; then
    echo "project store: $PROJECT_STORE ($(count_lines "$PROJECT_STORE/memory.jsonl") active, $(count_lines "$PROJECT_STORE/archive.jsonl") archived)"
  else
    echo "project store: not found (run install.sh --project)"
  fi
  if [ -d "$GLOBAL_STORE" ]; then
    echo "global store:  $GLOBAL_STORE ($(count_lines "$GLOBAL_STORE/memory.jsonl") active, $(count_lines "$GLOBAL_STORE/archive.jsonl") archived)"
  else
    echo "global store:  not installed (run install.sh --global)"
  fi
  local f
  for f in "${PROJECT_STORE:+$(dirname "$PROJECT_STORE")/settings.json}" "$HOME/.claude/settings.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if grep -q 'hook-session-start' "$f" 2>/dev/null; then
      echo "hooks registered in: $f"
    fi
  done
  echo "markers dir: $(markers_dir)"
}

# ------------------------------------------------------------------ hooks

cmd_hook_session_start() {
  local input parsed session_id src marker_dir claim ts
  input="$(cat 2>/dev/null || true)"
  parsed="$(printf '%s' "$input" \
    | jq -r '[(.session_id // "unknown"), (.source // "startup")] | @tsv' 2>/dev/null)" || parsed=""
  [ -n "$parsed" ] || parsed="$(printf 'unknown\tstartup')"
  session_id="${parsed%%$'\t'*}"
  src="${parsed#*$'\t'}"
  # On resume the previous context (which already contains the digest) is
  # restored, so re-injecting would duplicate it.
  [ "$src" = "resume" ] && return 0
  # Dedupe concurrent injections (a global and a project install both fire this
  # hook) with an atomic mkdir claim plus a short TTL: a fresh claim suppresses
  # the duplicate, while a later event with the same source — e.g. a SECOND
  # context compaction — is past the TTL and re-injects. If markers are
  # unavailable, prefer a possible duplicate over injecting no memory at all.
  if marker_dir="$(markers_dir)"; then
    claim="$marker_dir/recall-$session_id-$src.d"
    if ! mkdir "$claim" 2>/dev/null; then
      ts="$(cat "$claim/ts" 2>/dev/null || echo 0)"
      case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
      [ $((NOW_EPOCH - ts)) -lt 60 ] && return 0
    fi
    printf '%s' "$NOW_EPOCH" > "$claim/ts" 2>/dev/null || true
    find "$marker_dir" -mindepth 1 -mtime +30 -delete 2>/dev/null || true
  fi
  cmd_recall
}

cmd_hook_stop() {
  local input parsed active rest store cfg session_id marker_dir marker transcript min size maxnew
  input="$(cat 2>/dev/null || true)"
  parsed="$(printf '%s' "$input" \
    | jq -r '[(.stop_hook_active // false | tostring), (.session_id // "unknown"), (.transcript_path // "")] | @tsv' 2>/dev/null)" || parsed=""
  [ -n "$parsed" ] || parsed="$(printf 'false\tunknown\t')"
  active="${parsed%%$'\t'*}"
  rest="${parsed#*$'\t'}"
  session_id="${rest%%$'\t'*}"
  transcript="${rest#*$'\t'}"
  [ "$active" = "true" ] && return 0

  if [ -n "$PROJECT_STORE" ]; then store="$PROJECT_STORE"
  elif [ -d "$GLOBAL_STORE" ]; then store="$GLOBAL_STORE"
  else return 0; fi
  cfg="$(load_config "$store")"
  [ "$(jq -r '.auto_reflect' <<<"$cfg")" = "true" ] || return 0

  # Without a usable marker dir we cannot guarantee once-per-session, so skip
  # the nudge entirely rather than re-firing it on every Stop.
  marker_dir="$(markers_dir)" || return 0
  marker="$marker_dir/reflect-$session_id"
  [ -e "$marker" ] && return 0

  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  min="$(jq -r '.reflect_min_transcript_bytes' <<<"$cfg")"
  size="$(wc -c < "$transcript" | tr -d '[:space:]')"
  [ "$size" -ge "$min" ] || return 0

  : > "$marker" 2>/dev/null || true
  maxnew="$(jq -r '.max_new_memories_per_session' <<<"$cfg")"
  local reason
  reason="[OS-Memory] Automatic end-of-session reflection (fires once per session).
Before giving your final reply, update long-term memory (script: $SELF):
1. Reinforce digest memories that actually helped this session: bash \"$SELF\" reinforce <id>
2. Weaken digest memories that proved wrong or outdated: bash \"$SELF\" weaken <id> --reason \"why\"
3. Save at most $maxnew genuinely durable new lessons, one self-contained English sentence each: bash \"$SELF\" add --category <$CATEGORIES_PIPE> [--scope global] [--context \"detail\"] -- \"<lesson>\"
Worth saving: pitfalls you hit and their fixes, corrections from the user, verified project facts and conventions, stated user preferences. Not worth saving: trivia, one-off details, anything already in the digest.
If nothing qualifies, save nothing. Then finish your reply."
  jq -n --arg r "$reason" '{decision: "block", reason: $r}'
}

# ------------------------------------------------------------------- main

cmd_help() {
  cat <<EOF
OS-Memory v$OSM_VERSION — long-term memory for Claude Code with human-like decay

Usage: memory.sh <command> [args]

Memory commands:
  add [--scope project|global] [--category CAT] [--context TXT] [--status S] [--] "lesson"
                          Save a memory (dedupes: identical content is
                          reinforced; use -- before content starting with a dash)
  reinforce <id>          Memory proved useful: +score, refresh decay clock
  weaken <id> [--reason TXT]
                          Memory proved wrong: -score (score 0 → forgotten;
                          pinned memories must be unpinned first)
  forget <id>             Archive a memory immediately (pinned: unpin first)
  pin <id> / unpin <id>   Exempt from / restore decay (unpin restarts the clock)
  promote <id>            Move a project memory to the account-wide store

Recall & curation:
  recall                  Print the memory digest (what sessions see at start)
  search <text>           Find memories by content
  list [--all|--archived] Table of memories with effective scores
  stats                   Store statistics
  consolidate [--quiet]   Apply decay: archive weak memories, purge old archive
  mark-reviewed           Record that a /memory-review was completed

Internals:
  hook-session-start      SessionStart hook entry (reads hook JSON on stdin)
  hook-stop               Stop hook entry (reflection nudge)
  doctor                  Check installation health

Env: OS_MEMORY_GLOBAL_DIR (default ~/.claude/os-memory)
     OS_MEMORY_NOW (epoch seconds; overrides clock, for testing)
Categories: $CATEGORIES
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  if [ "$HAS_JQ" != "1" ]; then
    case "$cmd" in
      # A missing jq must never break the user's session — hooks skip silently.
      hook-session-start|hook-stop) exit 0 ;;
      doctor|help|--help|-h|version) ;;
      *) die "jq is required (https://jqlang.org)" ;;
    esac
  fi
  case "$cmd" in
    add)                cmd_add "$@" ;;
    recall)             cmd_recall "$@" ;;
    reinforce)          cmd_reinforce "$@" ;;
    weaken)             cmd_weaken "$@" ;;
    forget)             cmd_forget "$@" ;;
    pin)                cmd_pin "$@" ;;
    unpin)              cmd_unpin "$@" ;;
    promote)            cmd_promote "$@" ;;
    search)             cmd_search "$@" ;;
    list)               cmd_list "$@" ;;
    stats)              cmd_stats "$@" ;;
    consolidate)        cmd_consolidate "$@" ;;
    mark-reviewed)      cmd_mark_reviewed "$@" ;;
    doctor)             cmd_doctor "$@" ;;
    hook-session-start) cmd_hook_session_start "$@" ;;
    hook-stop)          cmd_hook_stop "$@" ;;
    version)            echo "$OSM_VERSION" ;;
    help|--help|-h)     cmd_help ;;
    *)                  die "unknown command: $cmd (try: memory.sh help)" ;;
  esac
}

main "$@"
