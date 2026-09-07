#!/usr/bin/env bash
# Worker for the /checkpoint command: write a manual checkpoint to auto-memory
# and print the checkpoint file path so Claude can append a resume note.
# Usage: checkpoint-now.sh ["optional note"]
# Prints the path on success; exits non-zero with a message if not in a git repo.
set -uo pipefail

HOME_DIR="${ARKIRA_CHECKPOINT_NOW_HOME:-$HOME}"
PROJECTS_ROOT="${CHECKPOINT_PROJECTS_ROOT:-$HOME_DIR/.claude/projects}"
export CHECKPOINT_PROJECTS_ROOT="$PROJECTS_ROOT"
note="${1:-}"

lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/checkpoint-lib.sh"
[ -f "$lib" ] || { echo "checkpoint: library missing" >&2; exit 1; }
# shellcheck source=/dev/null
. "$lib"

cwd="${CHECKPOINT_NOW_CWD:-$PWD}"
repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "checkpoint: not inside a git repository ($cwd)" >&2
  exit 1
fi
repo_name="$(basename "$repo_root")"

branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
head_sha="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || echo 000000000000)"
head_sub="$(git -C "$repo_root" log -1 --pretty='%s' 2>/dev/null || true)"
dirty_n="$(git -C "$repo_root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ "${dirty_n:-0}" -eq 0 ]; then tree="clean"; else tree="$dirty_n file(s) changed"; fi
recent="$(git -C "$repo_root" log -5 --pretty='%h %s' 2>/dev/null || true)"

facts="$(
  echo "- Repo: $repo_name"
  echo "- Trigger: manual /checkpoint"
  echo "- Branch: $branch"
  echo "- HEAD: $head_sha $head_sub"
  echo "- Working tree: $tree"
  echo "- Recent commits:"
  printf '%s\n' "$recent" | while IFS= read -r line; do
    [ -n "$line" ] && echo "  - $line"
  done
  [ -n "$note" ] && echo "- Note: $note"
)"

mem_dir="$(ckpt_resolve_mem_dir "$cwd")"
date_h="$(date -u +'%Y-%m-%d %H:%M UTC')"
ckpt_file="$(ckpt_write_file "$mem_dir" "$repo_name" "Manual checkpoint" "$head_sha" "$facts")"
[ -n "$ckpt_file" ] || { echo "checkpoint: failed to write" >&2; exit 1; }
ckpt_refresh_pointer "$mem_dir" "$repo_name" "$date_h" "$ckpt_file"
ckpt_index_and_migrate "$mem_dir"

printf '%s\n' "$ckpt_file"
exit 0
