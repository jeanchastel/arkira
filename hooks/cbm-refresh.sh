#!/usr/bin/env bash
# Stop and SessionStart: refresh the codebase-memory-mcp graph for this repo,
# then delete every graph project whose root directory is gone. The work runs
# in a detached background job, so the hook prints nothing, never blocks, and
# always exits 0. This replaces the server's own watcher (auto_watch stays off).
#
# Test knobs: ARKIRA_CBM_BIN (binary), ARKIRA_CBM_LOCK (lock dir),
# ARKIRA_CBM_FOREGROUND=1 (run the job inline instead of detaching).
set -uo pipefail

cbm="${ARKIRA_CBM_BIN:-codebase-memory-mcp}"
command -v "$cbm" >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
top="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$top" ] || exit 0

lock="${ARKIRA_CBM_LOCK:-${TMPDIR:-/tmp}/arkira-cbm-refresh.lock}"
# A lock older than 10 minutes belongs to a job that died without cleaning up.
[ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
mkdir "$lock" 2>/dev/null || exit 0

# list_projects text: unindented `key: ...` lines open a section; indented
# lines are whitespace-separated rows. projects_refs rows are `id prefix`;
# projects rows are `name root_path branch`, and root_path `@N+suffix` means
# ref N's prefix followed by suffix. Prints name<TAB>root for every row whose
# root resolves to an absolute path; anything unresolved is left out, so a
# format change never deletes.
project_roots() {
  awk '
    /^[^ \t]/ { mode = ($1 == "projects_refs:") ? "r" : ($1 == "projects:") ? "p" : ""; next }
    mode == "r" && $1 ~ /^[0-9]+$/ && NF >= 2 { ref[$1 + 0] = $2; next }
    mode == "p" && NF >= 2 { rows++; pname[rows] = $1; proot[rows] = $2 }
    END {
      for (i = 1; i <= rows; i++) {
        r = proot[i]
        if (match(r, /^@[0-9]+\+/)) {
          id = substr(r, 2, RLENGTH - 2) + 0
          if (!(id in ref)) continue
          r = ref[id] substr(r, RLENGTH + 1)
        }
        if (pname[i] != "" && r ~ /^\//) printf "%s\t%s\n", pname[i], r
      }
    }
  '
}

refresh() {
  local raw text name root
  "$cbm" cli --quiet index_repository "$(jq -nc --arg p "$top" '{repo_path:$p}')"
  raw="$("$cbm" cli --json list_projects)" || return 0
  text="$(printf '%s' "$raw" | jq -r '[.. | objects | .text? | strings] | join("\n")' 2>/dev/null)"
  [ -n "$text" ] || text="$raw"
  while IFS=$'\t' read -r name root; do
    [ -d "$root" ] && continue
    "$cbm" cli --quiet delete_project "$(jq -nc --arg n "$name" '{project_name:$n}')"
  done < <(printf '%s\n' "$text" | project_roots)
}

if [ "${ARKIRA_CBM_FOREGROUND:-}" = 1 ]; then
  refresh </dev/null >/dev/null 2>&1
  rmdir "$lock" 2>/dev/null
else
  ( trap 'rmdir "$lock" 2>/dev/null' EXIT; refresh ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi
exit 0
