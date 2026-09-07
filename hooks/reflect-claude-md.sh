#!/usr/bin/env bash
# Stop hook: reflect on the session and PROPOSE CLAUDE.md edits (propose-only).
# Never edits CLAUDE.md. Runs reflection in the background so it never delays
# the session. Gated by the self_improving_claude_md switch (default off).
# Every failure path exits 0.
set -uo pipefail

# --- recursion guard ---------------------------------------------------
# A concrete verifier may fire Stop hooks again. This exported flag stops recursion.
[ "${ARKIRA_REFLECT_ACTIVE:-0}" = "1" ] && exit 0

# --- testability knobs -------------------------------------------------
HOME_DIR="${ARKIRA_REFLECT_HOME:-$HOME}"
NO_RUN="${ARKIRA_REFLECT_NO_RUN:-}"
THROTTLE_SECONDS="${ARKIRA_REFLECT_THROTTLE_SECONDS:-300}"
TIMEOUT_SECONDS="${ARKIRA_REFLECT_TIMEOUT_SECONDS:-120}"
MIN_CHANGES="${ARKIRA_REFLECT_MIN_CHANGES:-2}"

lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib"
json_lib="$lib_dir/json-lib.sh"
[ -f "$json_lib" ] || exit 0
# shellcheck source=/dev/null
. "$json_lib"
retention_script="$lib_dir/proposal-retention.sh"
[ -f "$retention_script" ] || exit 0
role_run="$lib_dir/../../ai-engineering/runtime/role-run.sh"
role_runtime="$lib_dir/../../ai-engineering/runtime/role-runtime.sh"

payload_cwd_simple() {
  printf '%s' "$1" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p'
}

payload_has_cwd_key() {
  printf '%s' "$1" | grep -q '"cwd"[[:space:]]*:'
}

payload_stop_active_true() {
  printf '%s' "$1" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'
}

reflect_switch_present() {
  local root="$1" repo_cfg home_cfg
  repo_cfg="$root/.arkira/config.json"
  home_cfg="$HOME_DIR/.arkira/config.json"
  if [ -f "$repo_cfg" ]; then
    grep -q '"self_improving_claude_md"[[:space:]]*:[[:space:]]*true' "$repo_cfg" 2>/dev/null
    return $?
  fi
  [ -f "$home_cfg" ] && grep -q '"self_improving_claude_md"[[:space:]]*:[[:space:]]*true' "$home_cfg" 2>/dev/null
}

# --- read the Stop payload ---------------------------------------------
payload="$(cat 2>/dev/null || true)"
payload_stop_active_true "$payload" && exit 0

# tool gates
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
if [ -z "$NO_RUN" ]; then [ -x "$role_run" ] || exit 0; fi

repo_root=""
switch_checked=0
quick_cwd="$(payload_cwd_simple "$payload")"
if [ -n "$quick_cwd" ] || ! payload_has_cwd_key "$payload"; then
  [ -n "$quick_cwd" ] || quick_cwd="$PWD"
  repo_root="$(git -C "$quick_cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
  reflect_switch_present "$repo_root" || exit 0
  project_scope="$repo_root"
  home_scope=""
  if [ ! -f "$repo_root/.arkira/config.json" ]; then
    project_scope="$HOME_DIR/.arkira/no-project"
    home_scope="$HOME_DIR"
  fi
  val="$(CLAUDE_PROJECT_DIR="$project_scope" HOME="$home_scope" arkira_switch self_improving_claude_md unset)"
  [ "$val" = "true" ] || exit 0
  switch_checked=1
fi

payload_fields="$(arkira_payload_fields "$payload" cwd session_id stop_hook_active transcript_path)"
cwd=""; session_id=""; stop_active=""; transcript=""
idx=0
while IFS= read -r field; do
  case "$idx" in
    0) cwd="$field" ;;
    1) session_id="$field" ;;
    2) stop_active="$field" ;;
    3) transcript="$field" ;;
  esac
  idx=$((idx + 1))
done <<< "$payload_fields"
[ -n "$cwd" ] || cwd="$PWD"
[ -n "$session_id" ] || session_id="nosession"
[ "$stop_active" = "true" ] && exit 0

# --- repo root ---------------------------------------------------------
if [ -n "${quick_cwd:-}" ] && [ "$cwd" != "$quick_cwd" ]; then
  switch_checked=0
  repo_root=""
fi
[ -n "$repo_root" ] || repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# --- switch gate -------------------------------------------------------
if [ "$switch_checked" -ne 1 ]; then
  cfg=""
  project_scope="$repo_root"
  home_scope=""
  [ -f "$repo_root/.arkira/config.json" ] && cfg="$repo_root/.arkira/config.json"
  if [ -z "$cfg" ] && [ -f "$HOME_DIR/.arkira/config.json" ]; then
    cfg="$HOME_DIR/.arkira/config.json"
    project_scope="$HOME_DIR/.arkira/no-project"
    home_scope="$HOME_DIR"
  fi
  [ -n "$cfg" ] || exit 0
  grep -q '"self_improving_claude_md"[[:space:]]*:[[:space:]]*true' "$cfg" 2>/dev/null || exit 0
  val="$(CLAUDE_PROJECT_DIR="$project_scope" HOME="$home_scope" arkira_switch self_improving_claude_md unset)"
  [ "$val" = "true" ] || exit 0
fi

# --- verifier gate: the reflection is a dispatched call, so it needs a dispatchable role ----
# The mission-default Verifier is host-session, which by definition cannot be dispatched from a
# background hook. role-run.sh correctly refuses with exit 12, but the worker below discards a
# non-ok envelope, so an operator who enables the switch on a default config would get silence
# forever. Fail here instead, once, with the fix. `arkira-role doctor` reports the same mismatch.
if [ -z "$NO_RUN" ]; then
  [ -f "$role_runtime" ] || exit 0
  # shellcheck source=/dev/null
  . "$role_runtime"
  verifier_provider="$(ARKIRA_REPO_ROOT="$repo_root" arkira_resolve_role verifier provider 2>/dev/null || true)"
  if [ "$verifier_provider" = "host-session" ] || [ -z "$verifier_provider" ]; then
    printf 'Arkira: self_improving_claude_md is on but the Verifier role resolves to %s, which cannot be dispatched from a hook. Run "%s set verifier <provider>" or turn the switch off.\n' \
      "${verifier_provider:-unresolvable}" "ai-engineering/runtime/role-manage.sh" >&2
    exit 0
  fi
fi

# --- change gate: only reflect if the session changed enough tracked files ----
changed_count="$(git -C "$repo_root" status --porcelain --ignore-submodules 2>/dev/null | grep -c .)"
[ "$changed_count" -ge "$MIN_CHANGES" ] || exit 0

# --- throttle ----------------------------------------------------------
mkdir -p "${TMPDIR:-/tmp}/arkira-reflect" 2>/dev/null || true
repo_key="$(printf '%s' "$repo_root" | tr '/ ' '__')"
marker="${TMPDIR:-/tmp}/arkira-reflect/${repo_key}.last"
now="$(date +%s)"
if [ -f "$marker" ]; then
  last="$(cat "$marker" 2>/dev/null || echo 0)"; case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( now - last )) -lt "$THROTTLE_SECONDS" ] && exit 0
fi
echo "$now" > "$marker" 2>/dev/null || true

# --- proposal target ---------------------------------------------------
prop_dir="$repo_root/.arkira/proposals/claude-md"
for proposal_component in "$repo_root/.arkira" "$repo_root/.arkira/proposals" "$prop_dir"; do
  [ ! -L "$proposal_component" ] || exit 0
  if [ ! -e "$proposal_component" ]; then
    mkdir "$proposal_component" 2>/dev/null || exit 0
  fi
  [ -d "$proposal_component" ] && [ ! -L "$proposal_component" ] || exit 0
done
ts="$(date -u +%Y%m%dT%H%M%SZ)"
session_key="$(printf '%s' "$session_id" | shasum -a 256 2>/dev/null | cut -c1-16)"
[ -n "$session_key" ] || session_key="nosession"
out_file="$prop_dir/$ts-$session_key.patch"
[ ! -e "$out_file" ] && [ ! -L "$out_file" ] || exit 0

# --- NO_RUN path (tests): write a stub, do not call claude -------------
if [ -n "$NO_RUN" ]; then
  {
    printf -- '--- a/CLAUDE.md\n'
    printf -- '+++ b/CLAUDE.md\n'
    printf -- '@@ -1 +1,2 @@\n'
    printf -- ' # CLAUDE.md\n'
    printf -- '+- session %s repo %s\n' "$session_id" "$repo_root"
  } > "$out_file" 2>/dev/null || true
  bash "$retention_script" "$prop_dir" >/dev/null 2>&1 || true
  exit 0
fi

# --- build the reflection prompt --------------------------------------
claude_md_list="$(find "$repo_root" -maxdepth 3 -name CLAUDE.md -not -path '*/node_modules/*' 2>/dev/null | head -20)"
# Namespace the prompt tempfile under the arkira-reflect dir created above rather
# than dropping it in the bare temp root. An explicit template is honored across
# GNU and BSD mktemp (BSD ignores TMPDIR for the no-arg form).
prompt_file="$(mktemp "${TMPDIR:-/tmp}/arkira-reflect/reflect.XXXXXX" 2>/dev/null)" || exit 0
# Own the tempfile until it is handed to the background job below. If this
# foreground exits first (a signal, or any early return before the launch), the
# trap removes it so it never leaks; the trap is cleared right after the launch so
# the background job, which reads and then removes the file, keeps its input.
trap 'rm -f "$prompt_file" 2>/dev/null' EXIT
{
  echo "You are reviewing a finished Claude Code session to propose updates to this repo's CLAUDE.md files."
  echo "Output a single git-apply-compatible unified diff against the repo's CLAUDE.md that makes one concrete, minimal, durable improvement learned this session."
  echo "Use correct paths and context lines. Do NOT propose ephemeral task details. If nothing is worth changing, output exactly: NONE"
  echo
  echo "Current CLAUDE.md files:"
  while IFS= read -r f; do [ -n "$f" ] && { echo "=== $f ==="; cat "$f" 2>/dev/null; }; done <<< "$claude_md_list"
  echo
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    echo "Session transcript: $transcript"
  else
    echo "Session diff (stat):"; git -C "$repo_root" diff --stat 2>/dev/null | head -50
  fi
} > "$prompt_file" 2>/dev/null

# --- reflect in the background: never delays the session --------------
# shellcheck disable=SC2016  # The single-quoted worker script expands in its own process.
nohup bash -c '
  set -uo pipefail
  export ARKIRA_REFLECT_ACTIVE=1
  pf="$1"; out="$2"; tmo="$3"; retention="$4"; prop_dir="$5"; role_run="$6"; repo="$7"
  export ARKIRA_REPO_ROOT="$repo"
  # Remove the prompt tempfile on any exit, not just after the verifier returns, so a
  # kill (timeout overrun, shutdown) mid-reflection cannot leak it. Use a function,
  # not an interpolated trap string: the path comes from TMPDIR, so baking it into
  # the trap would re-evaluate any shell metacharacters in it when the trap fires.
  cleanup_prompt() { rm -f -- "$pf" 2>/dev/null || true; }
  trap cleanup_prompt EXIT
  trap "exit 130" INT
  trap "exit 143" TERM
  response="$("$role_run" verifier repo_reading --timeout "$tmo" --prompt-file "$pf" 2>/dev/null || true)"
  result="$(printf "%s" "$response" | jq -r "select(.ok == true) | .output" 2>/dev/null || true)"
  [ -z "$result" ] && exit 0
  printf "%s\n" "$result" | grep -qx "NONE" && exit 0
  printf "%s\n" "$result" > "$out" 2>/dev/null || exit 0
  bash "$retention" "$prop_dir" >/dev/null 2>&1 || true
' _ "$prompt_file" "$out_file" "$TIMEOUT_SECONDS" "$retention_script" "$prop_dir" \
  "$role_run" "$repo_root" >/dev/null 2>&1 &

# Ownership of the tempfile is now the background job's; do not delete it here.
trap - EXIT
exit 0
