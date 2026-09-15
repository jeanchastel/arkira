#!/usr/bin/env bash
# Detect and report first-party CLI updates. Applies upgrades only in --apply mode.
#
# Modes:
#   --report    read-only: prints full table and warns on stale apply history.
#   --apply     installs tracked updates and records apply attempts.
#
# Gated by the cli_version_freshness switch (default true).
set -uo pipefail

# --- skip knob (tests) -------------------------------------------------
[ -n "${ARKIRA_CLI_FRESHNESS_SKIP:-}" ] && exit 0

MODE="report"
case "${1:-}" in
  ''|--report) MODE="report" ;;
  --apply) MODE="apply" ;;
  *) printf 'usage: cli-freshness-check.sh [--report|--apply]\n' >&2; exit 2 ;;
esac

HOME_DIR="${ARKIRA_CLI_FRESHNESS_HOME:-$HOME}"
NOW_OVERRIDE="${ARKIRA_CLI_FRESHNESS_NOW:-}"
[ -n "${ARKIRA_CLI_FRESHNESS_PATH_BIN:-}" ] && PATH="$ARKIRA_CLI_FRESHNESS_PATH_BIN:$PATH"

PROBE_TIMEOUT_SECONDS=30
MUTATE_TIMEOUT_SECONDS=180

command -v jq >/dev/null 2>&1 || exit 0

run_with_timeout() {
  local timeout_seconds=$1
  shift
  local -a command=($@)
  local stdout_path stderr_path marker pid watcher owner program status
  local out

  stdout_path="$(mktemp "${TMPDIR:-/tmp}/arkira-hook.out.XXXXXX")" || return 1
  stderr_path="$(mktemp "${TMPDIR:-/tmp}/arkira-hook.err.XXXXXX")" || { rm -f -- "$stdout_path"; return 1; }
  marker="$(mktemp "${TMPDIR:-/tmp}/arkira-timeout.XXXXXX")" || { rm -f -- "$stdout_path" "$stderr_path"; return 1; }
  rm -f -- "$marker"

  if command -v setsid >/dev/null 2>&1; then
    setsid "${command[@]}" > "$stdout_path" 2> "$stderr_path" &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!"; exec @ARGV' -- "${command[@]}" > "$stdout_path" 2> "$stderr_path" &
  else
    rm -f -- "$stdout_path" "$stderr_path" "$marker"
    printf 'Arkira error 13: setsid or perl is required for bounded commands\n' >&2
    return 13
  fi
  pid=$!
  owner=$(exec sh -c 'echo $PPID')
  program='
use strict;
use warnings;
my ($seconds, $pgid, $marker_path, $owner) = @ARGV;
my $deadline = time + $seconds;
while (1) {
  exit 0 if getppid() != $owner;
  my $left = $deadline - time;
  last if $left <= 0;
  sleep($left > 1 ? 1 : $left);
}
exit 0 if getppid() != $owner;
open my $handle, ">", $marker_path or exit 1;
close $handle;
kill "TERM", -$pgid;
select undef, undef, undef, 1;
kill "KILL", -$pgid;
'
  (
    trap - EXIT
    exec perl -e "$program" "$timeout_seconds" "$pid" "$marker" "$owner"
  ) &
  watcher=$!

  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true

  out="$(cat "$stdout_path" 2>/dev/null || true)"
  if [ -e "$marker" ]; then
    rm -f -- "$marker" "$stdout_path" "$stderr_path"
    return 14
  fi

  rm -f -- "$marker"
  rm -f -- "$stdout_path" "$stderr_path"

  [ "$status" -eq 0 ] || return "$status"
  printf '%s' "$out"
  return 0
}

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

# --- switch gate -------------------------------------------------------
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
cfg=""
[ -f "$project_dir/.arkira/config.json" ] && cfg="$project_dir/.arkira/config.json"
[ -z "$cfg" ] && [ -f "$HOME_DIR/.arkira/config.json" ] && cfg="$HOME_DIR/.arkira/config.json"
if [ -n "$cfg" ]; then
  val="$(jq -r 'if (.switches | type == "object") and (.switches | has("cli_version_freshness")) then .switches.cli_version_freshness else "unset" end' "$cfg" 2>/dev/null || echo unset)"
  [ "$val" = "false" ] && exit 0
fi
# unset / no config -> default true -> proceed

cache_dir="$HOME_DIR/.arkira"

# --- tracked tools -----------------------------------------------------
# Each row: tool|channel|package
#   npm     -> installed via `<tool> --version`, latest via `npm view`
#   brew    -> latest via `brew` probes; upgrades only when its formula is installed
#   system  -> report only, no latest probe (e.g. Apple git)
#   absent  -> report only if absent; if present treat as npm
TOOLS=(
  "vercel|npm"
  "supabase|brew"
  "claude|npm|@anthropic-ai/claude-code"
  "codex|npm|@openai/codex"
  "gh|brew"
  "node|brew"
  "rtk|brew"
  "pnpm|npm"
  "git|system"
  "bun|absent"
  "wrangler|npm"
)

# --- brew outdated snapshot ---------------------------------------------
brew_outdated_json=""
brew_available() { command -v brew >/dev/null 2>&1; }
brew_manages_formula() {  # brew_manages_formula <formula>
  brew_available || return 1
  run_with_timeout "$PROBE_TIMEOUT_SECONDS" brew list --versions --formula "$1" >/dev/null 2>&1
}
load_brew_outdated() {
  brew_available || { brew_outdated_json='{"formulae":[]}' ; return; }
  brew_outdated_json="$(run_with_timeout "$PROBE_TIMEOUT_SECONDS" brew outdated --json=v2 --formula 2>/dev/null || echo '{"formulae":[]}')"
}
brew_latest() {  # brew_latest <formula>; prints current_version or empty
  local v
  v="$(printf '%s' "$brew_outdated_json" \
    | jq -r --arg n "$1" '.formulae[]? | select(.name==$n) | .current_version // empty' 2>/dev/null \
    | head -1)"
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  # brew outdated lists nothing for a formula that is already current, which is
  # why a current tool previously reported unknown.
  brew_available || return 0
  run_with_timeout "$PROBE_TIMEOUT_SECONDS" brew info --json=v2 --formula "$1" 2>/dev/null \
    | jq -r '.formulae[0].versions.stable // empty' 2>/dev/null | head -1
}

# --- version helpers ---------------------------------------------------
clean_ver() {  # strip a leading v and any trailing junk; first dotted number
  printf '%s' "$1" | tr -d ' \t\r' | sed 's/^v//' | grep -Eo '[0-9]+(\.[0-9]+)*' | head -1
}
ver_gap() {  # ver_gap <installed> <latest>; prints current|safe|major|unknown
  local i l im lm; i="$1"; l="$2"
  { [ -n "$i" ] && [ -n "$l" ]; } || { echo unknown; return; }
  [ "$i" = "$l" ] && { echo current; return; }
  im="${i%%.*}"; lm="${l%%.*}"
  case "$im" in ''|*[!0-9]*) echo unknown; return ;; esac
  case "$lm" in ''|*[!0-9]*) echo unknown; return ;; esac
  if [ "$lm" -gt "$im" ]; then echo major; return; fi
  if [ "$lm" -lt "$im" ]; then echo current; return; fi
  if [ "$(printf '%s\n%s\n' "$i" "$l" | sort -V | tail -1)" = "$l" ]; then
    echo safe
  else
    echo current
  fi
}

installed_ver() {  # installed_ver <tool>; prints cleaned version or empty
  command -v "$1" >/dev/null 2>&1 || return 0
  local raw
  raw="$($1 --version 2>/dev/null | head -1 || true)"
  clean_ver "$raw"
}

latest_ver() {  # latest_ver <tool> <channel>; prints cleaned version or empty
  case "$2" in
    npm|absent)
      command -v npm >/dev/null 2>&1 || return 0
      clean_ver "$(run_with_timeout "$PROBE_TIMEOUT_SECONDS" npm view "$1" version 2>/dev/null || true)"
      ;;
    brew)
      clean_ver "$(brew_latest "$1")"
      ;;
    system) : ;;
  esac
}

# --- collect -----------------------------------------------------------
load_brew_outdated

if [ "$MODE" = "apply" ]; then
  runtime_root="${ARKIRA_RUNTIME_HOME:-${ARKIRA_ROLE_HOME:-$HOME_DIR}/.arkira/runtime}"
  if compgen -G "$runtime_root/active/*.job" > /dev/null; then
    printf 'cli-freshness: an Executor job is active; not upgrading.\n' >&2
    exit 1
  fi

  history="$cache_dir/cli-apply-history.jsonl"
  mkdir -p "$cache_dir" 2>/dev/null || true
  failed=0
  brew_formulas=()

  record_apply() {  # record_apply <tool> <from>
    jq -n --arg ts "$(now_iso)" --arg t "$1" --arg f "${2:-none}" \
      '{applied_at:$ts, tool:$t, from:$f}' >> "$history" 2>/dev/null || true
  }

  for row in "${TOOLS[@]}"; do
    IFS='|' read -r tool chan pkg <<< "$row"
    [ -n "${pkg:-}" ] || pkg="$tool"
    inst="$(installed_ver "$tool")"
    [ -n "$inst" ] || continue
    [ "$chan" = "system" ] && continue

    case "$chan" in
      npm)
        record_apply "$tool" "$inst"
        if ! run_with_timeout "$MUTATE_TIMEOUT_SECONDS" npm i -g "$pkg@latest" >/dev/null 2>&1; then
          printf 'cli-freshness: %s upgrade failed\n' "$tool" >&2
          failed=1
        fi
        ;;
      brew)
        # A binary on PATH is not proof that Homebrew owns it. In particular,
        # gh and node are commonly installed by user-local or version-manager
        # tooling. Do not let an unmanaged binary make the shared brew batch fail.
        brew_manages_formula "$pkg" || continue
        record_apply "$tool" "$inst"
        brew_formulas+=("$pkg")
        ;;
      *) : ;;
    esac
  done

  if [ "${#brew_formulas[@]}" -gt 0 ] && brew_available; then
    if ! run_with_timeout "$MUTATE_TIMEOUT_SECONDS" brew upgrade "${brew_formulas[@]}" >/dev/null 2>&1; then
      printf 'cli-freshness: brew upgrade failed\n' >&2
      failed=1
    fi
  fi

  exit "$failed"
fi

report_rows=""      # tool\tinstalled\tlatest\tgap\taction
available_safe=()   # "tool inst->latest"
held_major=()       # "tool inst->latest"

for row in "${TOOLS[@]}"; do
  IFS='|' read -r tool chan pkg <<< "$row"
  [ -n "${pkg:-}" ] || pkg="$tool"
  inst="$(installed_ver "$tool")"

  if [ -z "$inst" ]; then
    report_rows+="$tool\t-\t-\tabsent\treported\n"
    continue
  fi

  if [ "$chan" = "system" ]; then
    report_rows+="$tool\t$inst\tn/a\tcurrent\tnone\n"
    continue
  fi

  latest="$(latest_ver "$pkg" "$chan")"
  if [ -z "$latest" ]; then
    report_rows+="$tool\t$inst\t?\tunknown\tnone\n"
    continue
  fi

  gap="$(ver_gap "$inst" "$latest")"
  action="none"

  if [ "$gap" = "safe" ]; then
    action="available"
    available_safe+=("$tool $inst->$latest")
  elif [ "$gap" = "major" ]; then
    action="available-major"
    held_major+=("$tool $inst->$latest")
  fi

  report_rows+="$tool\t$inst\t$latest\t$gap\t$action\n"
done

# --- output ------------------------------------------------------------
printf 'Arkira CLI freshness (tracked tools):\n'
printf '%b' "$report_rows" | awk -F'\t' 'NF>=4 {printf "  %-10s %-12s -> %-12s [%s]\n",$1,$2,$3,$4}'
any=0
printf '%b' "$report_rows" | grep -qE '\t(safe|major)\t' && any=1
if [ "$any" -eq 0 ]; then
  printf 'All tracked CLIs current.\n'
fi

last_apply="$(tail -1 "$cache_dir/cli-apply-history.jsonl" 2>/dev/null | jq -r '.applied_at // empty' 2>/dev/null || true)"
last_epoch="$(iso_to_epoch "$last_apply")"
if [ "$last_epoch" -eq 0 ] || [ "$(( $(now_epoch) - last_epoch ))" -gt 604800 ]; then
  printf 'no CLI upgrade has been applied in over 7 days; run cli-freshness-check.sh --apply (or add the weekly cron line from the standard).\n'
fi

exit 0
