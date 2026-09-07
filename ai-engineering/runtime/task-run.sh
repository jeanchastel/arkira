#!/usr/bin/env bash
set -uo pipefail

runtime_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/role-runtime.sh
. "$runtime_dir/role-runtime.sh"
# shellcheck source=ai-engineering/runtime/job-control.sh
. "$runtime_dir/job-control.sh"
# shellcheck source=ai-engineering/runtime/task-contract.sh
. "$runtime_dir/task-contract.sh"

task_usage() {
  printf 'usage: task-run.sh <repo> dispatch --contract <file> [--timeout seconds] | status <job-id> | recover | watch [job-id] | checks [<pr-number>] [--watch]\n' >&2
  return 2
}

task_report() {
  local document=$1
  jq -r '
    (.state // .mode // "unknown") as $state |
    (.elapsed_seconds // 0) as $record_elapsed |
    (if ($state | IN("running", "reserved")) and
        ((.started_epoch | type) == "number") and .started_epoch > 0
      then ([((now - .started_epoch) | floor), 0] | max)
      else $record_elapsed
    end) as $elapsed |
    ([
      "job=\(.job_id // .active_job_id // "-")",
      "state=\($state)",
      "exit=\(.exit_code // "-")",
      "provider=\(.provider // .execution.provider // "-")",
      "model=\(.model // .execution.model // "-")",
      "effort=\(.effort // .execution.effort // "-")",
      "elapsed=\($elapsed)s"
    ] | join(" ")) as $summary |
    $summary,
    if ($state | IN("done", "failed", "timed_out", "terminated")) then
      if (.output_file // null) != null then "output=\(.output_file)" else empty end,
      "error=\(
        if (.error // "") == "" then "-"
        else (.error | split("\n")[0] | if length == 0 then "-" else . end)
        end
      )",
      if (.receipt_file // null) != null then "receipt=\(.receipt_file)" else empty end
    else empty end
  ' <<<"$document"
}

task_terminal_result() {
  local repo=$1 status=$2 workspace
  workspace="$(job_workspace_lookup "$repo" 2>/dev/null || true)"
  if [[ -n "$workspace" &&
    "$(jq -r '.job_id // empty' <<<"$workspace")" == "$(jq -r '.job_id // empty' <<<"$status")" ]]; then
    printf '%s' "$workspace"
  else
    printf '%s' "$status"
  fi
}

task_dispatch() {
  local contract="" timeout=1800 brief model effort result rc digest capability=code_editing
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --contract)
        [[ "$#" -ge 2 ]] || { task_usage; return; }
        contract=$2
        shift 2
        ;;
      --timeout)
        [[ "$#" -ge 2 ]] || { task_usage; return; }
        timeout=$2
        shift 2
        ;;
      *) task_usage; return ;;
    esac
  done
  [[ -n "$contract" && "$timeout" =~ ^[1-9][0-9]*$ ]] || { task_usage; return; }
  arkira_task_contract_validate "$contract" || return
  digest="$(arkira_task_contract_bind "$ARKIRA_REPO_ROOT" "$contract")" || return
  brief="$(mktemp "${TMPDIR:-/tmp}/arkira-task-brief.XXXXXX")" || return 1
  chmod 600 "$brief" || { rm -f -- "$brief"; return 1; }
  arkira_task_contract_render "$contract" > "$brief" || {
    rc=$?
    rm -f -- "$brief"
    return "$rc"
  }
  model="$(jq -r '.dispatch.model' "$contract")"
  effort="$(jq -r '.dispatch.effort' "$contract")"
  if [[ "$(jq -r '.ui.mode' "$contract")" == browser ]]; then
    capability=test_execution
  fi
  result="$("$runtime_dir/role-run.sh" executor "$capability" --timeout "$timeout" \
    --prompt-file "$brief" --model "$model" --effort "$effort" --contract-digest "$digest")"
  rc=$?
  rm -f -- "$brief"
  if [[ -n "$result" ]]; then
    task_report "$result"
    printf '%s\n' "$result"
  fi
  return "$rc"
}

task_status() {
  local job_id=${1:-} result state
  [[ "$#" -eq 1 ]] || { task_usage; return; }
  result="$(job_status "$job_id")" || return
  state="$(jq -r '.state' <<<"$result")"
  if [[ "$state" != running && "$state" != reserved ]]; then
    result="$(task_terminal_result "$ARKIRA_REPO_ROOT" "$result")"
  fi
  task_report "$result"
}

task_recover() {
  local result
  [[ "$#" -eq 0 ]] || { task_usage; return; }
  result="$(job_workspace_lookup "$ARKIRA_REPO_ROOT")" || return
  task_report "$result"
}

task_watch() {
  local job_id=${1:-} result state previous="" interval terminal_result exit_code
  [[ "$#" -le 1 ]] || { task_usage; return; }
  if [[ -z "$job_id" ]]; then
    job_id="$(job_active_workspace "$ARKIRA_REPO_ROOT" 2>/dev/null)" || {
      job_fail_unknown
      return
    }
  fi
  interval=${ARKIRA_TASK_WATCH_POLL_SECONDS:-5}
  [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ && "$interval" =~ [1-9] ]] || interval=5
  while :; do
    result="$(job_status "$job_id")" || return
    state="$(jq -r '.state' <<<"$result")"
    if [[ "$state" != "$previous" ]]; then
      printf 'state=%s\n' "$state"
      previous=$state
    fi
    case "$state" in
      running|reserved) sleep "$interval" ;;
      *) break ;;
    esac
  done
  terminal_result="$(task_terminal_result "$ARKIRA_REPO_ROOT" "$result")"
  task_report "$terminal_result"
  [[ "$state" == "done" ]] && return 0
  exit_code="$(jq -r '.exit_code // 1' <<<"$result")"
  [[ "$exit_code" =~ ^[1-9][0-9]*$ && "$exit_code" -le 125 ]] || exit_code=1
  return "$exit_code"
}

arkira_checks_read() {
  local pr_number=$1 output
  output="$(cd -- "$ARKIRA_REPO_ROOT" &&
    gh pr checks "$pr_number" --json name,state,bucket 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1 || return 1
  printf '%s' "$output"
}

arkira_checks_line() {
  local checks=$1 pr_number=$2 elapsed=$3
  jq -r --arg pr "$pr_number" --argjson elapsed "$elapsed" '
    def safe_names($bucket):
      [
        .[] |
        select(.bucket == $bucket) |
        (.name | tostring | gsub("[\u007f-\u009f]"; ""))
      ] | sort;
    . as $checks |
    ($checks | length) as $total |
    ([$checks[] | select(.bucket == "pass")] | length) as $passed |
    ([$checks[] | select(.bucket == "pending")] | length) as $pending |
    ([$checks[] | select(.bucket == "fail" or .bucket == "cancel")] | length) as $failed |
    ([$checks[] | select(.bucket == "skipping")] | length) as $skipped |
    ($checks | safe_names("pending")) as $waiting |
    ($checks | safe_names("fail")) as $failing |
    ($checks | safe_names("cancel")) as $cancelled |
    (if $pending > 0 then "running" elif $failed > 0 then "failed" else "passed" end) as $state |
    "ci pr=\($pr) state=\($state) passed=\($passed)/\($total) pending=\($pending) failed=\($failed)" +
    (if $skipped > 0 then " skipped=\($skipped)" else "" end) +
    " elapsed=\($elapsed)s" +
    (if ($waiting | length) > 0 then " waiting=\($waiting | tojson)" else "" end) +
    (if ($failing | length) > 0 then " failing=\($failing | tojson)" else "" end) +
    (if ($cancelled | length) > 0 then " cancelled=\($cancelled | tojson)" else "" end)
  ' <<<"$checks"
}

task_checks() {
  local pr_number="" watch=false checks line state interval elapsed signature pr_document
  local previous_signature="" start_seconds transient_reads=0
  start_seconds=$SECONDS
  if [[ "$#" -gt 0 && "$1" != --watch ]]; then
    pr_number=$1
    shift
    [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || { task_usage; return; }
  fi
  if [[ "$#" -gt 0 && "$1" == --watch ]]; then
    watch=true
    shift
  fi
  [[ "$#" -eq 0 ]] || { task_usage; return; }
  command -v gh >/dev/null 2>&1 || {
    printf 'error: gh is not installed\n' >&2
    return 20
  }
  gh auth status >/dev/null 2>&1 || {
    printf 'error: gh is not authenticated\n' >&2
    return 20
  }
  if [[ -z "$pr_number" ]]; then
    pr_document="$(cd -- "$ARKIRA_REPO_ROOT" && gh pr view --json number 2>/dev/null)" || {
      printf 'error: no pull request found for current branch\n' >&2
      return 20
    }
    pr_number="$(jq -r '.number // empty' <<<"$pr_document" 2>/dev/null)"
    [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || {
      printf 'error: no pull request found for current branch\n' >&2
      return 20
    }
  fi
  interval=${ARKIRA_TASK_CHECKS_POLL_SECONDS:-15}
  [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ && "$interval" =~ [1-9] ]] || interval=15
  while :; do
    if ! checks="$(arkira_checks_read "$pr_number")"; then
      if [[ "$watch" != true ]]; then
        printf 'error: unable to read PR checks\n' >&2
        return 20
      fi
      transient_reads=$((transient_reads + 1))
      if [[ "$transient_reads" -gt 5 ]]; then
        printf 'error: unable to read PR checks after 6 attempts\n' >&2
        return 20
      fi
      sleep "$interval"
      continue
    fi
    transient_reads=0
    if [[ "$watch" == true ]]; then elapsed=$((SECONDS - start_seconds)); else elapsed=0; fi
    line="$(arkira_checks_line "$checks" "$pr_number" "$elapsed")" || return 20
    signature="$(sed -E 's/ elapsed=[0-9]+s//' <<<"$line")"
    if [[ "$signature" != "$previous_signature" ]]; then
      printf '%s\n' "$line"
      previous_signature=$signature
    fi
    state=${line#* state=}
    state=${state%% *}
    if [[ "$watch" != true || "$state" != running ]]; then break; fi
    sleep "$interval"
  done
  [[ "$state" != failed ]] || return 21
}

task_run_main() {
  local repo=${1:-} command=${2:-}
  [[ -d "$repo" && ! -L "$repo" ]] || { task_usage; return; }
  repo="$(cd -- "$repo" && pwd -P)" || return 2
  export ARKIRA_REPO_ROOT="$repo"
  [[ "$#" -ge 2 ]] || { task_usage; return; }
  shift 2
  case "$command" in
    dispatch) task_dispatch "$repo" "$@" ;;
    status) task_status "$@" ;;
    recover) task_recover "$@" ;;
    watch) task_watch "$@" ;;
    checks) task_checks "$@" ;;
    *) task_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then task_run_main "$@"; fi
