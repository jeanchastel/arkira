#!/usr/bin/env bash
# SessionStart + /arkira-sync helper: report vendored
# third-party components current WITHOUT auto-merging upstream content.
#
# Modes:
#   (default)  auto: throttled 24h; prints only when a behind/failed state
#              changes. Detect-only, never writes skill files.
#   --report   read-only: ignores throttle, prints full table. Used by
#              /arkira-sync.
#   --prepare  disabled for this release. Fails before any mutation.
#
# Gated by an explicit repo-local vendored_freshness switch.
set -uo pipefail
MODE="auto"
case "${1:-}" in
  --report) MODE="report" ;;
  --prepare)
    echo "Re-vendoring is disabled for this release. Use detect-only mode or --report." >&2
    exit 1
    ;;
esac
[ -n "${ARKIRA_VENDORED_FRESHNESS_SKIP:-}" ] && exit 0

NOW_OVERRIDE="${ARKIRA_VENDORED_FRESHNESS_NOW:-}"
[ -n "${ARKIRA_VENDORED_FRESHNESS_PATH_BIN:-}" ] && PATH="$ARKIRA_VENDORED_FRESHNESS_PATH_BIN:$PATH"
script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 0
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(CDPATH='' cd -- "$script_dir/.." && pwd -P)}"

command -v jq >/dev/null 2>&1 || exit 0

# --- switch gate -------------------------------------------------------
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
command -v git >/dev/null 2>&1 || exit 0
repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
cfg="$repo_root/.arkira/config.json"
[ -f "$cfg" ] || exit 0
val="$(jq -r 'if (.switches | type == "object") and (.switches | has("vendored_freshness")) then (.switches.vendored_freshness | tostring) else "unset" end' "$cfg" 2>/dev/null || echo unset)"
[ "$val" = "true" ] || exit 0

git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
[ -n "$git_dir" ] || exit 0
cache_dir="$git_dir"
cache="$cache_dir/arkira-vendored-freshness.json"
previous_fingerprint=""

now_epoch() { [ -n "$NOW_OVERRIDE" ] && { echo "$NOW_OVERRIDE"; return; }; date +%s; }
now_iso() {
  local e; e="$(now_epoch)"
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ
}
iso_to_epoch() {  # iso_to_epoch <iso>; prints epoch or 0
  [ -n "$1" ] || { echo 0; return; }
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || echo 0
}

# --- throttle (auto mode only) -----------------------------------------
if [ "$MODE" = "auto" ] && [ -f "$cache" ]; then
  checked_at="$(jq -r '.checked_at // empty' "$cache" 2>/dev/null || true)"
  previous_fingerprint="$(jq -r '.notice_fingerprint // empty' "$cache" 2>/dev/null || true)"
  if [ -n "$checked_at" ]; then
    ce="$(iso_to_epoch "$checked_at")"
    cur="$(now_epoch)"
    if [ "$ce" -gt 0 ] 2>/dev/null && [ "$((cur - ce))" -lt 86400 ] && [ "$((cur - ce))" -ge 0 ]; then
      exit 0
    fi
  fi
fi

PINS="${ARKIRA_VENDORED_PINS:-$plugin_root/ai-engineering/bootstrap/vendored-pins.json}"
[ -f "$PINS" ] || { [ "$MODE" = "auto" ] && exit 0; echo "no pins file: $PINS" >&2; exit 1; }

# latest_pin <source> <repo> <path>; prints latest SHA (github) / version (pypi) or empty
latest_pin() {
  case "$1" in
    github)
      # default-branch HEAD sha, no clone
      git ls-remote "https://github.com/$2" HEAD 2>/dev/null | awk '{print $1; exit}'
      ;;
    pypi)
      curl -fsSL "https://pypi.org/pypi/$2/json" 2>/dev/null \
        | jq -r '.info.version // empty' 2>/dev/null
      ;;
  esac
}

# pin_state <pinned> <latest>; current if equal, unknown if latest empty, else behind
pin_state() {
  [ -n "$2" ] || { echo unknown; return; }
  [ "$1" = "$2" ] && { echo current; return; }
  echo behind
}

behind_lines=""; unknown_lines=""; any=0
while IFS=$'\t' read -r name source repo _path pin; do
  latest="$(latest_pin "$source" "$repo")"
  state="$(pin_state "$pin" "$latest")"
  case "$state" in
    behind)  behind_lines+="  $name  $source:$repo  pinned=${pin:0:12}  latest=${latest:0:12}"$'\n'; any=1 ;;
    unknown) unknown_lines+="  $name  $source:$repo  (check failed)"$'\n'; any=1 ;;
  esac
done < <(jq -r '.[] | [.name,.source,.repo,.path,.pin] | @tsv' "$PINS")

# Write the throttle and last observed state atomically. The timestamp limits
# network work; the fingerprint suppresses an unchanged warning after that
# throttle expires. A transition through current gets its own fingerprint, so
# a later regression is actionable again.
state_fingerprint="$(printf 'behind\n%sunknown\n%s' "$behind_lines" "$unknown_lines" \
  | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -n "$state_fingerprint" ] || state_fingerprint="state-$any"
if [ "$MODE" = "auto" ]; then
  cache_tmp="$(mktemp "$cache_dir/.vendored-freshness.XXXXXX" 2>/dev/null || true)"
  if [ -n "$cache_tmp" ] \
     && jq -n --arg checked_at "$(now_iso)" --arg fingerprint "$state_fingerprint" \
       '{checked_at:$checked_at,notice_fingerprint:$fingerprint}' > "$cache_tmp" 2>/dev/null; then
    chmod 600 "$cache_tmp" 2>/dev/null || true
    mv "$cache_tmp" "$cache" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null || true
  else
    [ -n "$cache_tmp" ] && rm -f "$cache_tmp" 2>/dev/null || true
  fi
fi

emit_report() {
  [ -n "$behind_lines" ]  && printf 'Vendored components behind upstream:\n%s' "$behind_lines"
  [ -n "$unknown_lines" ] && printf 'Vendored freshness checks that failed:\n%s' "$unknown_lines"
  [ -n "$behind_lines" ] && printf 'Re-vendoring is disabled for this release. Use this detect-only report for review.\n'
}

if [ "$MODE" = "report" ]; then
  if [ "$any" = "0" ]; then echo "All vendored components current."; else emit_report; fi
  exit 0
fi
if [ "$MODE" = "auto" ]; then
  [ "$any" = "1" ] && [ "$state_fingerprint" != "$previous_fingerprint" ] && emit_report
  exit 0
fi

exit 0
