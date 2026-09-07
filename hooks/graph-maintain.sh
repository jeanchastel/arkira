#!/usr/bin/env bash
# Knowledge-graph auto-maintenance. SessionStart hook that provisions, self-heals,
# and self-updates a per-repo code knowledge graph through the external
# code-review-graph CLI. The CLI (and its GPL igraph/Leiden builder) is an
# operator-installed, operator-global tool. It is never bundled or linked by
# this MIT plugin; the hook only shells out to it when present, exactly like the
# CLI-freshness hook shells out to vercel/supabase.
#
# Gated by an explicit repo-local knowledge_graph switch. Throttled once per 24h
# per repo. Health-checks the graph: missing/empty/unhealthy -> full build
# (self-heal); otherwise -> incremental update (self-update). No-op when the CLI
# is absent, jq/git are absent, or the cwd is not a git repo. Backgrounds the
# build/update so it never blocks the session. Exit 0 always.
set -uo pipefail

# Drain the hook stdin payload so the producer never blocks on a full pipe.
# Only drain when stdin is not a terminal: in production stdin is a pipe from
# the producer, so this drains and unblocks it; on an interactive TTY there is
# no producer and an unbounded cat would hang (this is what made the local test
# suite hang when run from a terminal). A TTY has nothing to drain, so skip it.
[ -t 0 ] || cat >/dev/null 2>&1 || true

[ -n "${ARKIRA_GRAPH_SKIP:-}" ] && exit 0

HOME_DIR="${ARKIRA_GRAPH_HOME:-$HOME}"
CLI="${ARKIRA_GRAPH_CLI:-code-review-graph}"
THROTTLE="${ARKIRA_GRAPH_THROTTLE:-86400}"   # 24h window, override for tests

command -v git >/dev/null 2>&1 || exit 0
command -v jq  >/dev/null 2>&1 || exit 0
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$repo_root" ] || exit 0

# --- switch gate -----------------------------------------------------------
cfg="$repo_root/.arkira/config.json"
[ -f "$cfg" ] || exit 0
val="$(jq -r 'if (.switches | type == "object") and (.switches | has("knowledge_graph")) then (.switches.knowledge_graph | tostring) else "unset" end' "$cfg" 2>/dev/null || echo unset)"
[ "$val" = "true" ] || exit 0

# --- CLI presence (no-op if the external tool is not installed) ------------
command -v "$CLI" >/dev/null 2>&1 || exit 0

now_epoch() {
  if [ -n "${ARKIRA_GRAPH_NOW:-}" ]; then echo "$ARKIRA_GRAPH_NOW"; else date +%s; fi
}

# --- throttle: at most once per window, per repo ---------------------------
# Hook bookkeeping lives in the git dir, not in the working tree or graph
# cache. It therefore survives graph rebuilds without becoming chat context.
git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || true)"
[ -n "$git_dir" ] || exit 0
stamp="$git_dir/arkira-graph-maintain"
notice_state="$git_dir/arkira-graph-notice-state"
cur="$(now_epoch)"
if [ -f "$stamp" ]; then
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ "$((cur - last))" -ge 0 ] && [ "$((cur - last))" -lt "$THROTTLE" ]; then
    exit 0
  fi
fi

# --- decide: self-heal (build) vs self-update ------------------------------
# A healthy graph makes `status` exit 0. Missing/empty/corrupt -> non-zero,
# which routes to a full build.
if "$CLI" status --repo "$repo_root" >/dev/null 2>&1; then
  action="update"
else
  action="build"
fi

# Stamp before launching so concurrent sessions do not pile up builds.
stamp_tmp="$(mktemp "$stamp.XXXXXX" 2>/dev/null || true)"
if [ -n "$stamp_tmp" ] && printf '%s\n' "$cur" > "$stamp_tmp" 2>/dev/null; then
  mv "$stamp_tmp" "$stamp" 2>/dev/null || rm -f "$stamp_tmp" 2>/dev/null || true
else
  [ -n "$stamp_tmp" ] && rm -f "$stamp_tmp" 2>/dev/null || true
fi

graph_notice_changed() {
  local next="$1" prior="" tmp=""
  [ -f "$notice_state" ] && prior="$(cat "$notice_state" 2>/dev/null || true)"
  [ "$prior" != "$next" ] || return 1
  tmp="$(mktemp "$notice_state.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || return 0
  if printf '%s\n' "$next" > "$tmp" 2>/dev/null \
     && mv "$tmp" "$notice_state" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

notice_changed=0
if graph_notice_changed "$action"; then
  notice_changed=1
fi

log_dir="$HOME_DIR/.arkira"
log="$log_dir/graph-maintain.log"
mkdir -p "$log_dir" 2>/dev/null || true

if [ "$action" = "build" ]; then
  printf '[%s] %s: build (self-heal)\n' "$cur" "$repo_root" >> "$log" 2>/dev/null || true
  if [ -f "$log" ] && [ "$(wc -l < "$log" | tr -d ' ')" -gt 50 ] 2>/dev/null; then
    log_tmp="$(mktemp "$log_dir/.graph-maintain.XXXXXX" 2>/dev/null || true)"
    if [ -n "$log_tmp" ] && tail -n 50 "$log" > "$log_tmp" 2>/dev/null; then
      mv "$log_tmp" "$log" 2>/dev/null || rm -f "$log_tmp" 2>/dev/null || true
    else
      [ -n "$log_tmp" ] && rm -f "$log_tmp" 2>/dev/null || true
    fi
  fi
  ( "$CLI" build --skip-flows --repo "$repo_root" >/dev/null 2>&1 & ) >/dev/null 2>&1
  if [ "$notice_changed" -eq 1 ]; then
    echo "knowledge graph: building for $(basename "$repo_root") (first run or self-heal); runs in the background."
  fi
else
  ( "$CLI" update --skip-flows --repo "$repo_root" >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

exit 0
