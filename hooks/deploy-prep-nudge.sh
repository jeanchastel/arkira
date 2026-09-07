#!/usr/bin/env bash
# PreToolUse hook: before a static-site deploy command runs, nudge the user
# to run /deploy-prep first.
#
# Scope:
#   - Fires only on Bash tool calls.
#   - Fires only for static-web profile repos. Profile is read from
#     .arkira/config.json (.profile). If absent, the hook falls back to a
#     heuristic: command path includes deploy/deploy.sh, or the repo has
#     _headers / .htaccess at root.
#   - Fires once per (session, cwd) pair so repeated deploys in the same
#     session do not re-nudge.
#   - Never blocks: every path exits 0 to keep the session moving.
set -uo pipefail

lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib"
json_lib="$lib_dir/json-lib.sh"
[ -f "$json_lib" ] || exit 0
# shellcheck source=/dev/null
. "$json_lib"

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

case "$payload" in
  *deploy/deploy.sh*|*"netlify deploy"*|*lftp*|*rsync*) : ;;
  *) exit 0 ;;
esac

command -v node >/dev/null 2>&1 || exit 0

payload_fields="$(arkira_payload_fields "$payload" tool_name tool_input.command cwd)"
tool=""; cmd=""; cwd=""
idx=0
while IFS= read -r field; do
  case "$idx" in
    0) tool="$field" ;;
    1) cmd="$field" ;;
    2) cwd="$field" ;;
  esac
  idx=$((idx + 1))
done <<< "$payload_fields"

[ "$tool" = "Bash" ] || exit 0

[ -n "$cwd" ] || cwd="$PWD"

# Match static-site deploy patterns. Add to this list as new hosts surface.
case "$cmd" in
  *deploy/deploy.sh*|*"netlify deploy"*|*"lftp "*|*"rsync"*"ftp"*) : ;;
  *) exit 0 ;;
esac

# Profile gate. Prefer the explicit profile when present; fall back to a
# heuristic for repos that have not been initialized through /arkira-init-web yet.
profile=""
cfg="$cwd/.arkira/config.json"
if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
  profile="$(jq -r '.profile // ""' "$cfg" 2>/dev/null || true)"
fi

if [ -n "$profile" ]; then
  # Explicit profile wins; only fire for static-web.
  [ "$profile" = "static-web" ] || exit 0
else
  # Profile unset (legacy or pre-init repo). Use a heuristic: command path
  # implies a static deploy, or the repo carries a static-host headers file.
  static_marker=0
  case "$cmd" in
    *deploy/deploy.sh*) static_marker=1 ;;
  esac
  [ -f "$cwd/_headers" ] && static_marker=1
  [ -f "$cwd/.htaccess" ] && static_marker=1
  [ "$static_marker" = 1 ] || exit 0
fi

# Rate-limit: once per (session, cwd). Markers live in one private bounded
# directory, use hashed names, and expire silently.
sess="${CLAUDE_SESSION_ID:-default}"
key="$(printf '%s\n%s' "$sess" "$cwd" | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -z "$key" ] && key="default"
mark_dir="${ARKIRA_DEPLOY_NUDGE_DIR:-${TMPDIR:-/tmp}/arkira-deploy-nudges-${UID:-0}}"
[ ! -L "$mark_dir" ] || exit 0
if [ ! -e "$mark_dir" ]; then
  mkdir -m 700 "$mark_dir" 2>/dev/null || exit 0
fi
[ -d "$mark_dir" ] && [ ! -L "$mark_dir" ] || exit 0
mark_mode="$(if stat -f '%Lp' "$mark_dir" >/dev/null 2>&1; then
  stat -f '%Lp' "$mark_dir"
else
  stat -c '%a' "$mark_dir" 2>/dev/null || true
fi)"
[ "$mark_mode" = "700" ] || exit 0

max_markers="${ARKIRA_DEPLOY_NUDGE_MAX_MARKERS:-100}"
ttl_seconds="${ARKIRA_DEPLOY_NUDGE_TTL_SECONDS:-172800}"
case "$max_markers" in ''|*[!0-9]*) max_markers=100 ;; esac
case "$ttl_seconds" in ''|*[!0-9]*) ttl_seconds=172800 ;; esac
[ "$max_markers" -gt 0 ] 2>/dev/null || max_markers=100
[ "$ttl_seconds" -gt 0 ] 2>/dev/null || ttl_seconds=172800

node -e '
const fs = require("fs");
const [dir, maxRaw, ttlRaw] = process.argv.slice(1);
const max = Math.max(1, Number(maxRaw) || 100);
const ttlMs = Math.max(1, Number(ttlRaw) || 172800) * 1000;
const now = Date.now();
let files = [];
try {
  for (const name of fs.readdirSync(dir)) {
    if (!/^[0-9a-f]{64}\.mark$/.test(name)) continue;
    const path = dir + "/" + name;
    try {
      const stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink()) continue;
      if (now - stat.mtimeMs > ttlMs) fs.unlinkSync(path);
      else files.push([path, stat.mtimeMs]);
    } catch {}
  }
  files.sort((a, b) => b[1] - a[1]);
  // Reserve one slot for the marker written by this invocation.
  for (const [path] of files.slice(Math.max(0, max - 1))) {
    try { fs.unlinkSync(path); } catch {}
  }
} catch {}
' "$mark_dir" "$max_markers" "$ttl_seconds" 2>/dev/null || true

mark="$mark_dir/$key.mark"
(set -o noclobber; umask 077; : > "$mark") 2>/dev/null || exit 0
chmod 600 "$mark" 2>/dev/null || true

node -e '
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: "[arkira] About to run a static-site deploy. Run /deploy-prep first if you have not already. It composes the html-semantics, a11y, performance-budget, and responsive audits and gates on sitemap, robots, headers, OG/canonical, no committed secrets, and 404 presence. Skip with intent if confident."
  }
}));'
exit 0
