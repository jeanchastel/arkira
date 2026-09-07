#!/usr/bin/env bash
# Shared checkpoint writer, sourced by checkpoint-on-merge.sh, time-checkpoint.sh,
# and checkpoint-now.sh. Not executed directly. Pure bash + coreutils, no jq.
# Every function is best-effort: a caller treats a non-zero return as "skip".

# ckpt_sanitize <text> [maxlen] -> neutralized single line.
# Untrusted VCS metadata (commit subjects, PR titles, branch names, the merge
# command) lands in a checkpoint file that the model is later told to read. Flatten
# newlines and tabs to spaces and strip control chars so the text cannot forge
# markdown structure or a fake instruction line, and cap length so a crafted commit
# message cannot flood the context window. This is data-hardening, not a parser:
# callers must still present the result as labeled untrusted data.
ckpt_sanitize() {
  local max="${2:-200}"
  printf '%s' "$1" \
    | tr '\n\r\t' '   ' \
    | tr -d '\000-\010\013\014\016-\037\177' \
    | cut -c1-"$max"
}

# ckpt_resolve_mem_dir <cwd>  -> echoes the auto-memory dir for that cwd.
# Honors CHECKPOINT_PROJECTS_ROOT (default $HOME/.claude/projects).
ckpt_resolve_mem_dir() {
  local cwd="$1"
  local root="${CHECKPOINT_PROJECTS_ROOT:-$HOME/.claude/projects}"
  local sanitized
  sanitized="$(printf '%s' "$cwd" | sed 's#/#-#g')"
  printf '%s' "$root/$sanitized/memory"
}

# ckpt_write_file <mem_dir> <repo> <title> <short_sha> <facts_block>
# Writes the checkpoint file; echoes its path; returns 1 on failure.
ckpt_write_file() {
  local mem_dir="$1" title="$3" short_sha="$4" facts="$5"
  local ckpt_dir="$mem_dir/checkpoints"
  mkdir -p "$ckpt_dir" 2>/dev/null || return 1
  local ts date_h ckpt_file
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  date_h="$(date -u +'%Y-%m-%d %H:%M UTC')"
  # $$ keeps the name unique if two checkpoints land in the same second.
  ckpt_file="$ckpt_dir/$ts-$short_sha-$$.md"
  {
    echo "# $title, $date_h"
    echo
    echo "## Facts"
    printf '%s\n' "$facts"
    echo
    echo "## Resume note"
    echo "<!-- Claude appends: what is in progress, current project state, next steps. -->"
  } > "$ckpt_file" 2>/dev/null || return 1
  # Keep checkpoint history bounded. The rolling pointer exposes only the ten
  # newest entries, and retaining twenty leaves recovery headroom without
  # feeding an ever-growing archive back into future conversations.
  local max_history="${ARKIRA_CHECKPOINT_MAX:-20}"
  case "$max_history" in ''|*[!0-9]*) max_history=20 ;; esac
  [ "$max_history" -gt 0 ] 2>/dev/null || max_history=20
  ls -1t "$ckpt_dir"/*.md 2>/dev/null | tail -n +$((max_history + 1)) | while IFS= read -r old; do
    [ -n "$old" ] && rm -f "$old" 2>/dev/null || true
  done
  printf '%s' "$ckpt_file"
}

# ckpt_refresh_pointer <mem_dir> <repo> <date_h> <ckpt_file>
# Rewrites project_last_checkpoint.md naming the latest and the recent ten.
ckpt_refresh_pointer() {
  local mem_dir="$1" repo="$2" date_h="$3" ckpt_file="$4"
  local ckpt_dir="$mem_dir/checkpoints"
  local pointer="$mem_dir/project_last_checkpoint.md"
  {
    echo "---"
    echo "name: project-last-checkpoint"
    echo "description: Most recent checkpoint (merge, interval, or manual); entry point for resuming after a session clear"
    echo "metadata:"
    echo "  type: project"
    echo "---"
    echo
    echo "Latest checkpoint: \`checkpoints/$(basename "$ckpt_file")\` ($repo, $date_h)."
    echo
    echo "Recent checkpoints:"
    ls -1t "$ckpt_dir"/*.md 2>/dev/null | head -10 | while IFS= read -r f; do
      [ -n "$f" ] && echo "- \`checkpoints/$(basename "$f")\`"
    done
    echo
    echo "To resume after a session clear: read the latest checkpoint file. Older checkpoints are in \`checkpoints/\`."
  } > "$pointer" 2>/dev/null || return 1
}

# ckpt_index_and_migrate <mem_dir>
# Idempotently index project_last_checkpoint.md in MEMORY.md, and silently drop
# the legacy project_last_merge_checkpoint.md file and its index line.
ckpt_index_and_migrate() {
  local mem_dir="$1"
  local memory_md="$mem_dir/MEMORY.md"
  local mem_line="- [Last checkpoint](project_last_checkpoint.md), resume point after a session clear; history in checkpoints/"

  rm -f "$mem_dir/project_last_merge_checkpoint.md" 2>/dev/null || true

  if [ -f "$memory_md" ]; then
    if grep -qF "project_last_merge_checkpoint.md" "$memory_md" 2>/dev/null; then
      grep -vF "project_last_merge_checkpoint.md" "$memory_md" > "$memory_md.tmp" 2>/dev/null \
        && mv "$memory_md.tmp" "$memory_md" 2>/dev/null \
        || rm -f "$memory_md.tmp" 2>/dev/null
    fi
    grep -qF "project_last_checkpoint.md" "$memory_md" 2>/dev/null \
      || printf '%s\n' "$mem_line" >> "$memory_md"
  else
    printf '%s\n' "$mem_line" > "$memory_md"
  fi
}
