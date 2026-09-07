#!/usr/bin/env bash
# Stop hook for the runtime-owned Executor job. Every failure path is silent.
set -uo pipefail

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
job_control="$hook_dir/../ai-engineering/runtime/job-control.sh"
[[ -f "$job_control" ]] || exit 0
# shellcheck source=ai-engineering/runtime/job-control.sh
. "$job_control"
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd=$PWD
repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo" ]] || exit 0

job_id="$(job_active_workspace "$repo" 2>/dev/null || true)"
[[ -n "$job_id" ]] || exit 0
status_json="$(job_status "$job_id" 2>/dev/null || true)"
if [[ -z "$status_json" ]]; then
  job_clear_workspace "$repo" >/dev/null 2>&1 || true
  exit 0
fi
state="$(printf '%s' "$status_json" | jq -r '.state')"
if [[ "$state" == running ]]; then
  poll_seconds="${ARKIRA_EXECUTOR_WATCH_POLL_SECONDS:-20}"
  max_wait_seconds="${ARKIRA_EXECUTOR_WATCH_MAX_WAIT_SECONDS:-300}"
  [[ "$poll_seconds" =~ ^[0-9]+$ ]] || poll_seconds=20
  [[ "$max_wait_seconds" =~ ^[0-9]+$ ]] || max_wait_seconds=300
  started=$SECONDS
  while [[ "$state" == running && "$poll_seconds" -gt 0 \
    && $((SECONDS - started)) -lt "$max_wait_seconds" ]]; do
    remaining=$((max_wait_seconds - (SECONDS - started)))
    sleep_seconds=$poll_seconds
    (( sleep_seconds <= remaining )) || sleep_seconds=$remaining
    (( sleep_seconds > 0 )) || break
    sleep "$sleep_seconds"
    status_json="$(job_status "$job_id" 2>/dev/null || true)"
    [[ -n "$status_json" ]] || exit 0
    state="$(printf '%s' "$status_json" | jq -r '.state')"
  done
fi

if [[ "$state" == running ]]; then
  jq -cn --arg reason "Executor job $job_id is still running. Keep this task open and check the same runtime job again; do not dispatch a duplicate." \
    '{decision:"block",reason:$reason}'
  exit 0
fi

reported_marker="$(job_runtime_root)/jobs/$job_id.reported"
if [[ -f "$reported_marker" && ! -L "$reported_marker" ]]; then
  job_clear_workspace_if "$repo" "$job_id" >/dev/null 2>&1 || true
  exit 0
fi
output_file="$(printf '%s' "$status_json" | jq -r '.output_file // empty')"
error_file="$(printf '%s' "$status_json" | jq -r '.error_file // empty')"
output=""
error=""
[[ -f "$output_file" && ! -L "$output_file" ]] && output="$(head -c 1200 "$output_file" 2>/dev/null || true)"
[[ -f "$error_file" && ! -L "$error_file" ]] && error="$(head -c 600 "$error_file" 2>/dev/null || true)"
job_create_marker "$reported_marker" >/dev/null 2>&1 || true
job_clear_workspace_if "$repo" "$job_id" >/dev/null 2>&1 || true
reason="Executor job $job_id finished with state $state. Output: ${output:-none}. Error: ${error:-none}. Inspect the shared tree and this exact job before continuing."
jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}'
exit 0
