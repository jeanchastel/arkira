#!/usr/bin/env bash
set -uo pipefail

JOB_CONTROL_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/job-control.sh"
# Receipt finalization receives a separate 30 second window after its marker is
# published. Reconcile also publishes this bounded lease when the child group
# has exited but the worker has not yet entered finalization. That closes the
# scheduling gap without allowing a hung supervisor to survive indefinitely.
JOB_FINALIZATION_MAX_SECONDS=30

job_runtime_root() {
  printf '%s' "${ARKIRA_RUNTIME_HOME:-${ARKIRA_ROLE_HOME:-$HOME}/.arkira/runtime}"
}

job_fail_unknown() {
  printf 'Arkira error 18: unknown job id; use the id returned by role-run.sh\n' >&2
  return 18
}

job_validate_id() {
  [[ "${1:-}" =~ ^job-[0-9]+-[0-9]+-[A-Za-z0-9]+$ ]]
}

job_prepare_dirs() {
  local root jobs active
  root="$(job_runtime_root)"
  jobs="$root/jobs"
  active="$root/active"
  if [[ -L "$root" || -L "$jobs" || -L "$active" ]]; then return 1; fi
  mkdir -p -- "$jobs" "$active" || return 1
  [[ -d "$root" && -d "$jobs" && -d "$active" && ! -L "$root" && ! -L "$jobs" \
    && ! -L "$active" ]] || return 1
  chmod 700 "$root" "$jobs" "$active" || return 1
}

job_workspace_key() {
  local repo=${1:-}
  [[ -d "$repo" && ! -L "$repo" ]] || return 1
  (cd -- "$repo" && pwd -P) | shasum -a 256 | awk '{print $1}'
}

# The marker asserts that a job owns this worktree. A record that no longer
# exists cannot describe a live process, so a missing record is not live.
job_workspace_owner_is_live() {
  local job_id=${1:-} record state pgid supervisor
  job_validate_id "$job_id" || return 1
  record="$(job_record_path "$job_id")" || return 1
  [[ -f "$record" && ! -L "$record" ]] || return 1
  state="$(jq -r '.state // empty' "$record" 2>/dev/null)" || return 1
  [[ "$state" == running || "$state" == reserved ]] || return 1
  supervisor="$(jq -r '.supervisor_pid // 0' "$record" 2>/dev/null)"
  pgid="$(jq -r '.pgid // 0' "$record" 2>/dev/null)"
  if [[ "$supervisor" =~ ^[1-9][0-9]*$ ]] && kill -0 "$supervisor" 2>/dev/null; then return 0; fi
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]] && kill -0 "-$pgid" 2>/dev/null; then return 0; fi
  return 1
}

job_track_workspace() {
  local repo=$1 job_id=$2 key target temp current
  job_validate_id "$job_id" || return 1
  job_prepare_dirs || return 1
  key="$(job_workspace_key "$repo")" || return 1
  target="$(job_runtime_root)/active/$key.job"
  [[ ! -L "$target" ]] || return 1
  # The workspace lock is released at spawn, so the marker is what guards the rest
  # of a job's life. Overwriting a live job's marker leaves two writers on one
  # worktree with the runtime naming only the second.
  # This marker write is check-then-act, not compare-and-swap. Concurrent provider
  # creation is prevented when job_worker reclaims job_claim_workspace_lock and
  # re-verifies that the marker names its own job id before creating the provider.
  current="$(job_active_workspace "$repo" 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != "$job_id" ]] && job_workspace_owner_is_live "$current"; then
    return 1
  fi
  temp="$(mktemp "$(job_runtime_root)/active/.active.XXXXXX")" || return 1
  chmod 600 "$temp"
  printf '%s\n' "$job_id" > "$temp" || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$target"
}

job_claim_workspace_key_lock() {
  local key=$1 lock owner attempts=0
  [[ "$key" =~ ^[a-f0-9]{64}$ ]] || return 1
  job_prepare_dirs || return 1
  lock="$(job_runtime_root)/active/$key.lock"
  while [[ "$attempts" -lt 2 ]]; do
    if mkdir -- "$lock" 2>/dev/null; then
      chmod 700 "$lock" || { rmdir -- "$lock" 2>/dev/null || true; return 1; }
      printf '%s\n' "$$" > "$lock/owner" || {
        rm -f -- "$lock/owner"
        rmdir -- "$lock" 2>/dev/null || true
        return 1
      }
      chmod 600 "$lock/owner" || return 1
      return 0
    fi
    [[ -d "$lock" && ! -L "$lock" && -f "$lock/owner" && ! -L "$lock/owner" ]] || return 1
    IFS= read -r owner < "$lock/owner" || return 1
    [[ "$owner" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$owner" 2>/dev/null && return 1
    rm -f -- "$lock/owner"
    rmdir -- "$lock" 2>/dev/null || return 1
    attempts=$((attempts + 1))
  done
  return 1
}

job_release_workspace_key_lock() {
  local key=$1 lock owner
  [[ "$key" =~ ^[a-f0-9]{64}$ ]] || return 1
  lock="$(job_runtime_root)/active/$key.lock"
  [[ -d "$lock" && ! -L "$lock" && -f "$lock/owner" && ! -L "$lock/owner" ]] || return 1
  IFS= read -r owner < "$lock/owner" || return 1
  [[ "$owner" == "$$" ]] || return 1
  rm -f -- "$lock/owner"
  rmdir -- "$lock"
}

job_claim_workspace_lock() {
  local repo=$1 key
  key="$(job_workspace_key "$repo")" || return 1
  job_claim_workspace_key_lock "$key"
}

job_release_workspace_lock() {
  local repo=$1 key
  key="$(job_workspace_key "$repo")" || return 1
  job_release_workspace_key_lock "$key"
}

job_active_workspace() {
  local repo=$1 key target job_id
  local root jobs active
  root="$(job_runtime_root)"
  jobs="$root/jobs"
  active="$root/active"
  [[ -d "$root" && -d "$jobs" && -d "$active" && ! -L "$root" && ! -L "$jobs" \
    && ! -L "$active" ]] || return 1
  key="$(job_workspace_key "$repo")" || return 1
  target="$(job_runtime_root)/active/$key.job"
  [[ -f "$target" && ! -L "$target" ]] || return 1
  IFS= read -r job_id < "$target" || return 1
  job_validate_id "$job_id" || return 1
  printf '%s' "$job_id"
}

job_clear_workspace() {
  local repo=$1 key target
  job_prepare_dirs || return 1
  key="$(job_workspace_key "$repo")" || return 1
  target="$(job_runtime_root)/active/$key.job"
  if [[ -f "$target" && ! -L "$target" ]]; then rm -f -- "$target"; fi
}

job_clear_workspace_if() {
  local repo=$1 expected=$2 current
  current="$(job_active_workspace "$repo" 2>/dev/null || true)"
  [[ "$current" == "$expected" ]] || return 1
  job_clear_workspace "$repo"
}

job_record_path() {
  job_validate_id "$1" || return 1
  printf '%s/jobs/%s.json' "$(job_runtime_root)" "$1"
}

job_clear_terminal_markers() {
  local job_id=$1 marker
  job_validate_id "$job_id" || return 1
  for marker in "$(job_runtime_root)/jobs/$job_id.terminate" \
    "$(job_runtime_root)/jobs/$job_id.timeout" \
    "$(job_runtime_root)/jobs/$job_id.finalizing" \
    "$(job_runtime_root)/jobs/$job_id.start"; do
    if [[ -f "$marker" && ! -L "$marker" ]]; then rm -f -- "$marker"; fi
  done
}

job_atomic_record() {
  local job_id=$1 state=$2 pgid=$3 provider=$4 started=$5 started_epoch=$6 timeout=$7
  local output=$8 error=$9 exit_code=${10:-null} supervisor=${11:-0}
  local execution=${12:-'{}'} record temp now elapsed=0 barrier attempts
  jq -e 'type == "object"' <<<"$execution" >/dev/null 2>&1 || return 1
  record="$(job_record_path "$job_id")" || return 1
  if [[ "$state" != running && "$state" != reserved ]]; then
    job_clear_terminal_markers "$job_id" || return 1
  fi
  temp="$(mktemp "$(dirname -- "$record")/.job-record.XXXXXX")" || return 1
  chmod 600 "$temp" || {
    rm -f -- "$temp"
    return 1
  }
  if [[ "$state" != running && "$state" != reserved ]]; then
    now="$(date '+%s')"
    [[ "$now" =~ ^[0-9]+$ && "$started_epoch" =~ ^[0-9]+$ && "$now" -ge "$started_epoch" ]] \
      && elapsed=$((now - started_epoch))
  fi
  jq -cn --arg job_id "$job_id" --argjson pgid "$pgid" --arg provider "$provider" \
    --arg state "$state" --arg started "$started" --argjson started_epoch "$started_epoch" \
    --argjson timeout "$timeout" --arg output_file "$output" --arg error_file "$error" \
    --argjson exit_code "$exit_code" --argjson supervisor_pid "$supervisor" \
    --argjson elapsed_seconds "$elapsed" --argjson execution "$execution" \
    '{job_id:$job_id,pgid:$pgid,provider:$provider,state:$state,started:$started,
      started_epoch:$started_epoch,timeout:$timeout,output_file:$output_file,error_file:$error_file,
      exit_code:$exit_code,supervisor_pid:$supervisor_pid,elapsed_seconds:$elapsed_seconds} +
      $execution' > "$temp" || {
      rm -f -- "$temp"
      return 1
    }
  if [[ "$state" != running && "$state" != reserved && \
    "${ARKIRA_JOB_CONTROL_TEST_MODE:-}" == 1 ]]; then
    barrier=${ARKIRA_JOB_CONTROL_TEST_PUBLISH_BARRIER:-}
    if [[ -n "$barrier" && -d "$barrier" ]]; then
      : > "$barrier/reached"
      attempts=0
      while [[ ! -f "$barrier/release" && "$attempts" -lt 500 ]]; do
        sleep 0.02
        attempts=$((attempts + 1))
      done
    fi
  fi
  mv -f -- "$temp" "$record" || {
    rm -f -- "$temp"
    return 1
  }
  if [[ "$state" != running && "$state" != reserved && \
    "${ARKIRA_JOB_CONTROL_TEST_MODE:-}" == 1 ]]; then
    barrier=${ARKIRA_JOB_CONTROL_TEST_PUBLISH_BARRIER:-}
    if [[ -n "$barrier" && -d "$barrier" && -f "$barrier/post" ]]; then
      : > "$barrier/published"
      attempts=0
      while [[ ! -f "$barrier/release-post" && "$attempts" -lt 500 ]]; do
        sleep 0.02
        attempts=$((attempts + 1))
      done
    fi
  fi
  if [[ "$state" != running && "$state" != reserved ]]; then
    job_clear_terminal_markers "$job_id"
  fi
}

job_create_marker() {
  local marker=$1 jobs temp now
  jobs="$(job_runtime_root)/jobs"
  [[ "$marker" == "$jobs/"* && ! -L "$marker" ]] || return 1
  [[ ! -e "$marker" || -f "$marker" ]] || return 1
  temp="$(mktemp "$jobs/.job-marker.XXXXXX")" || return 1
  chmod 600 "$temp" || { rm -f -- "$temp"; return 1; }
  now="$(date '+%s')"
  printf '%s\n' "$now" > "$temp" || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$marker"
}

job_remove_marker() {
  local marker=$1
  if [[ -f "$marker" && ! -L "$marker" ]]; then rm -f -- "$marker"; fi
}

job_marker_age() {
  local marker=$1 started now
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  IFS= read -r started < "$marker" || return 1
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  now="$(date '+%s')"
  [[ "$now" =~ ^[0-9]+$ && "$now" -ge "$started" ]] || return 1
  printf '%s' $((now - started))
}

job_worker() {
  local job_id=$1 provider=$2 timeout=$3 stdin_path=$4 output=$5 error=$6
  shift 6
  local execution='{}'
  local workspace_repo=""
  local receipt_repo="" receipt_pre="" receipt_role="" receipt_provider="" receipt_model="" receipt_effort=""
  local receipt_contract_digest=""
  if [[ "${1:-}" == --execution-json ]]; then
    execution=${2:-}
    jq -e 'type == "object"' <<<"$execution" >/dev/null 2>&1 || return 2
    shift 2
  fi
  if [[ "${1:-}" == --workspace-repo ]]; then
    workspace_repo=${2:-}
    [[ -d "$workspace_repo" && ! -L "$workspace_repo" ]] || return 2
    shift 2
  fi
  if [[ "${1:-}" == --receipt ]]; then
    receipt_repo=${2:-}
    receipt_pre=${3:-}
    receipt_role=${4:-}
    receipt_provider=${5:-}
    receipt_model=${6:-}
    receipt_effort=${7:-}
    receipt_contract_digest=${8:-}
    shift 8
  fi
  local started started_epoch child timer status timeout_marker terminate_marker finalization_marker
  local start_marker supervisor receipt_post receipt_metadata active_job attempts=0 worker_lock_held=0
  local receipt_failed=0 typescript_emit_failed=0 typescript_emit_paths='[]'
  local job_control_dir
  job_control_dir="$(cd -- "$(dirname -- "$JOB_CONTROL_SCRIPT")" && pwd -P)" || return 1
  # shellcheck source=ai-engineering/runtime/receipt-lib.sh
  . "$job_control_dir/receipt-lib.sh"
  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  started_epoch="$(date '+%s')"
  supervisor=$$
  timeout_marker="$(job_runtime_root)/jobs/$job_id.timeout"
  terminate_marker="$(job_runtime_root)/jobs/$job_id.terminate"
  finalization_marker="$(job_runtime_root)/jobs/$job_id.finalizing"
  start_marker="$(job_runtime_root)/jobs/$job_id.start"
  job_remove_receipt_pre() {
    [[ -n "$receipt_pre" && "$receipt_pre" == "$(job_runtime_root)/jobs/"* ]] || return 0
    if [[ -f "$receipt_pre" && ! -L "$receipt_pre" ]]; then rm -f -- "$receipt_pre"; fi
  }
  job_worker_release_lock() {
    if [[ "$worker_lock_held" -eq 1 ]]; then
      job_release_workspace_lock "$workspace_repo" >/dev/null 2>&1 || true
      worker_lock_held=0
    fi
  }
  job_worker_interrupt() {
    local terminal=terminated exit_code=143
    if [[ "${child:-}" =~ ^[1-9][0-9]*$ ]]; then
      kill -TERM "-$child" 2>/dev/null || true
      sleep 1
      kill -KILL "-$child" 2>/dev/null || true
    fi
    if [[ -f "$terminate_marker" && ! -L "$terminate_marker" ]]; then
      terminal=terminated
    elif [[ -f "$timeout_marker" && ! -L "$timeout_marker" ]]; then
      terminal=timed_out
      exit_code=14
    fi
    job_remove_marker "$terminate_marker"
    job_remove_marker "$timeout_marker"
    job_remove_marker "$finalization_marker"
    job_remove_marker "$start_marker"
    job_remove_receipt_pre
    job_atomic_record "$job_id" "$terminal" "${child:-0}" "$provider" "$started" \
      "$started_epoch" "$timeout" "$output" "$error" "$exit_code" "$supervisor" "$execution"
    job_worker_release_lock
    exit "$exit_code"
  }
  trap job_worker_interrupt HUP INT TERM
  if [[ -n "$workspace_repo" ]]; then
    # The worker must own the workspace lock and matching reservation before it
    # can create a provider process. A delayed worker cannot become an orphaned writer.
    while [[ "$attempts" -lt 500 ]]; do
      if job_claim_workspace_lock "$workspace_repo"; then
        worker_lock_held=1
        break
      fi
      sleep 0.02
      attempts=$((attempts + 1))
    done
    if [[ "$worker_lock_held" -ne 1 ]]; then
      job_remove_receipt_pre
      job_atomic_record "$job_id" failed 0 "$provider" "$started" "$started_epoch" \
        "$timeout" "$output" "$error" 19 "$supervisor" "$execution"
      return 19
    fi
    active_job="$(job_active_workspace "$workspace_repo" 2>/dev/null || true)"
    if [[ "$active_job" != "$job_id" ]]; then
      job_remove_receipt_pre
      job_atomic_record "$job_id" failed 0 "$provider" "$started" "$started_epoch" \
        "$timeout" "$output" "$error" 19 "$supervisor" "$execution"
      job_worker_release_lock
      return 19
    fi
  fi
  job_remove_marker "$start_marker"
  # The isolated process group waits here until the running record is durable.
  # This keeps provider liveness and recorded ownership from diverging.
  if command -v setsid >/dev/null 2>&1; then
    setsid /bin/bash -c '
      supervisor=$1
      start_marker=$2
      shift 2
      while [[ ! -f "$start_marker" ]]; do
        kill -0 "$supervisor" 2>/dev/null || exit 1
        sleep 0.02
      done
      exec "$@"
    ' arkira-job-gate "$supervisor" "$start_marker" "$@" \
      < "$stdin_path" > "$output" 2> "$error" &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!"; exec @ARGV' -- \
      /bin/bash -c '
        supervisor=$1
        start_marker=$2
        shift 2
        while [[ ! -f "$start_marker" ]]; do
          kill -0 "$supervisor" 2>/dev/null || exit 1
          sleep 0.02
        done
        exec "$@"
      ' arkira-job-gate "$supervisor" "$start_marker" "$@" \
      < "$stdin_path" > "$output" 2> "$error" &
  else
    job_remove_marker "$terminate_marker"
    job_remove_marker "$timeout_marker"
    job_remove_marker "$finalization_marker"
    job_remove_receipt_pre
    job_atomic_record "$job_id" failed 0 "$provider" "$started" "$started_epoch" \
      "$timeout" "$output" "$error" 13 "$supervisor" "$execution"
    job_worker_release_lock
    return 13
  fi
  child=$!
  if ! job_atomic_record "$job_id" running "$child" "$provider" "$started" "$started_epoch" \
    "$timeout" "$output" "$error" null "$supervisor" "$execution"; then
    kill -TERM "-$child" 2>/dev/null || true
    job_worker_release_lock
    return 1
  fi
  if ! job_create_marker "$start_marker"; then
    kill -TERM "-$child" 2>/dev/null || true
    job_atomic_record "$job_id" failed "$child" "$provider" "$started" "$started_epoch" \
      "$timeout" "$output" "$error" 1 "$supervisor" "$execution"
    job_worker_release_lock
    return 1
  fi
  job_worker_release_lock
  (
    sleep "$timeout"
    job_create_marker "$timeout_marker" || exit 1
    kill -TERM "-$child" 2>/dev/null || true
    sleep 1
    kill -KILL "-$child" 2>/dev/null || true
  ) &
  timer=$!
  if wait "$child"; then status=0; else status=$?; fi
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  if [[ -f "$terminate_marker" && ! -L "$terminate_marker" ]]; then
    job_remove_marker "$terminate_marker"
    job_remove_marker "$timeout_marker"
    job_remove_marker "$finalization_marker"
    job_remove_receipt_pre
    job_atomic_record "$job_id" terminated "$child" "$provider" "$started" "$started_epoch" \
      "$timeout" "$output" "$error" 143 "$supervisor" "$execution"
  elif [[ -f "$timeout_marker" && ! -L "$timeout_marker" ]]; then
    job_remove_marker "$terminate_marker"
    job_remove_marker "$timeout_marker"
    job_remove_marker "$finalization_marker"
    job_remove_receipt_pre
    job_atomic_record "$job_id" timed_out "$child" "$provider" "$started" "$started_epoch" \
      "$timeout" "$output" "$error" 14 "$supervisor" "$execution"
  elif [[ "$status" -eq 0 ]]; then
    if [[ -n "$receipt_pre" ]]; then
      if [[ "${ARKIRA_JOB_CONTROL_TEST_MODE:-}" == 1 && \
        "${ARKIRA_JOB_CONTROL_TEST_FINALIZATION_PRE_MARKER_DELAY_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
        sleep "$ARKIRA_JOB_CONTROL_TEST_FINALIZATION_PRE_MARKER_DELAY_SECONDS"
      fi
      if ! job_create_marker "$finalization_marker"; then
        printf 'Arkira warning: async executor finalization marker write failed\n' >&2
      fi
      if [[ "${ARKIRA_JOB_CONTROL_TEST_MODE:-}" == 1 && \
        "${ARKIRA_JOB_CONTROL_TEST_FINALIZATION_HANG:-}" == 1 ]]; then
        while :; do sleep 1; done
      fi
      if [[ "${ARKIRA_JOB_CONTROL_TEST_MODE:-}" == 1 && \
        "${ARKIRA_JOB_CONTROL_TEST_FINALIZATION_DELAY_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
        sleep "$ARKIRA_JOB_CONTROL_TEST_FINALIZATION_DELAY_SECONDS"
      fi
      receipt_post="$(mktemp "$(job_runtime_root)/jobs/.receipt-post.XXXXXX")" || true
      if [[ -n "$receipt_post" ]]; then
        chmod 600 "$receipt_post" || true
        receipt_metadata="$(jq -cn --arg role "$receipt_role" --arg provider "$receipt_provider" \
          --arg model "$receipt_model" --arg effort "$receipt_effort" --arg job_id "$job_id" \
          --arg contract_digest "$receipt_contract_digest" \
          '{author_role:$role,author_provider:$provider,author_model:$model,
            author_effort:$effort,job_id:$job_id}
            + (if $contract_digest == "" then {} else {contract_digest:$contract_digest} end)')"
        if [[ ! -f "$receipt_pre" ]]; then
          if [[ -n "$receipt_contract_digest" ]]; then
            printf 'Arkira error: governed async executor receipt pre-snapshot is missing\n' >&2
          else
            printf 'Arkira warning: async executor receipt pre-snapshot is missing\n' >&2
          fi
        fi
        if ! arkira_receipt_snapshot "$receipt_repo" "$receipt_post" || \
          ! arkira_receipt_write "$receipt_repo" "$receipt_pre" "$receipt_post" "$receipt_metadata" >/dev/null; then
          if [[ -n "$receipt_contract_digest" ]]; then
            printf 'Arkira error: governed async executor receipt write failed\n' >&2
            receipt_failed=1
          else
            printf 'Arkira warning: async executor receipt write failed\n' >&2
          fi
        elif ! typescript_emit_paths="$(
          arkira_receipt_new_typescript_emit_paths "$receipt_pre" "$receipt_post"
        )"; then
          if [[ -n "$receipt_contract_digest" ]]; then
            printf 'Arkira error: governed async executor residue check failed\n' >&2
            receipt_failed=1
          else
            printf 'Arkira warning: async executor residue check failed\n' >&2
          fi
        elif jq -e 'length > 0' <<< "$typescript_emit_paths" >/dev/null; then
          printf 'Arkira error: Executor created TypeScript compiler residue next to source files: %s\n' \
            "$typescript_emit_paths" >&2
          printf 'Remove unintended files before retrying. Review intentional outputs before a new dispatch.\n' >&2
          typescript_emit_failed=1
        fi
        rm -f -- "$receipt_post"
      else
        if [[ -n "$receipt_contract_digest" ]]; then
          printf 'Arkira error: governed async executor receipt write failed\n' >&2
          receipt_failed=1
        else
          printf 'Arkira warning: async executor receipt write failed\n' >&2
        fi
      fi
      job_remove_marker "$finalization_marker"
    fi
    job_remove_marker "$terminate_marker"
    job_remove_marker "$timeout_marker"
    job_remove_marker "$finalization_marker"
    job_remove_receipt_pre
    if [[ "$receipt_failed" -eq 1 || "$typescript_emit_failed" -eq 1 ]]; then
      job_atomic_record "$job_id" failed "$child" "$provider" "$started" "$started_epoch" \
        "$timeout" "$output" "$error" 1 "$supervisor" "$execution"
    else
      job_atomic_record "$job_id" "done" "$child" "$provider" "$started" "$started_epoch" \
        "$timeout" "$output" "$error" 0 "$supervisor" "$execution"
    fi
  else
    job_remove_marker "$terminate_marker"
    job_remove_marker "$timeout_marker"
    job_remove_marker "$finalization_marker"
    job_remove_receipt_pre
    job_atomic_record "$job_id" failed "$child" "$provider" "$started" "$started_epoch" \
      "$timeout" "$output" "$error" "$status" "$supervisor" "$execution"
  fi
}

job_prune() {
  local root jobs active now file epoch output error candidate key job_id
  job_prepare_dirs || return 1
  root="$(job_runtime_root)"
  jobs="$root/jobs"
  active="$root/active"
  now="$(date '+%s')"
  for file in "$active"/*.job; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || continue
    key="$(basename -- "$file" .job)"
    [[ "$key" =~ ^[a-f0-9]{64}$ ]] || continue
    job_claim_workspace_key_lock "$key" || continue
    job_id=""
    IFS= read -r job_id < "$file" || true
    if ! job_workspace_owner_is_live "$job_id"; then rm -f -- "$file"; fi
    job_release_workspace_key_lock "$key" || return 1
  done
  for file in "$jobs"/*.json; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || continue
    epoch="$(jq -r '.started_epoch // 0' "$file" 2>/dev/null || printf 0)"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    if [[ $((now - epoch)) -gt 86400 ]]; then
      output="$(jq -r '.output_file // empty' "$file" 2>/dev/null)"
      error="$(jq -r '.error_file // empty' "$file" 2>/dev/null)"
      for candidate in "$output" "$error" "$jobs/$(basename -- "$file" .json).timeout" \
        "$jobs/$(basename -- "$file" .json).terminate" "$jobs/$(basename -- "$file" .json).finalizing" \
        "$jobs/$(basename -- "$file" .json).reported" "$jobs/$(basename -- "$file" .json).start" \
        "$jobs/$(basename -- "$file" .json).supervisor.log" "$jobs/$(basename -- "$file" .json).pre"; do
        case "$candidate" in
          "$jobs"/*)
            if [[ -f "$candidate" && ! -L "$candidate" ]]; then rm -f -- "$candidate"; fi
            ;;
        esac
      done
      rm -f -- "$file"
    fi
  done
  for file in "$jobs"/.receipt-pre-*; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || continue
    if stat -f '%m' "$file" >/dev/null 2>&1; then
      epoch="$(stat -f '%m' "$file")"
    else
      epoch="$(stat -c '%Y' "$file")" || continue
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    if [[ $((now - epoch)) -gt 86400 ]]; then rm -f -- "$file"; fi
  done
  for file in "$jobs"/*.finalizing; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || continue
    if stat -f '%m' "$file" >/dev/null 2>&1; then
      epoch="$(stat -f '%m' "$file")"
    else
      epoch="$(stat -c '%Y' "$file")" || continue
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    if [[ $((now - epoch)) -gt 86400 ]]; then rm -f -- "$file"; fi
  done
  for file in "$jobs"/*.reported; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || continue
    if stat -f '%m' "$file" >/dev/null 2>&1; then
      epoch="$(stat -f '%m' "$file")"
    else
      epoch="$(stat -c '%Y' "$file")" || continue
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    if [[ $((now - epoch)) -gt 86400 ]]; then rm -f -- "$file"; fi
  done
}

job_launch() {
  local provider=${1:-} timeout=${2:-} stdin_path=/dev/null receipt_repo="" receipt_pre=""
  local receipt_role="" receipt_provider="" receipt_model="" receipt_effort=""
  local receipt_contract_digest=""
  local execution='{}' workspace_repo="" launcher=""
  local job_id jobs output error supervisor_log record reserved_started reserved_epoch record_state
  shift 2 || return 2
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --stdin) stdin_path=${2:-}; shift 2 || return 2 ;;
      --receipt-repo) receipt_repo=${2:-}; shift 2 || return 2 ;;
      --receipt-pre) receipt_pre=${2:-}; shift 2 || return 2 ;;
      --receipt-role) receipt_role=${2:-}; shift 2 || return 2 ;;
      --receipt-provider) receipt_provider=${2:-}; shift 2 || return 2 ;;
      --receipt-model) receipt_model=${2:-}; shift 2 || return 2 ;;
      --receipt-effort) receipt_effort=${2:-}; shift 2 || return 2 ;;
      --receipt-contract-digest) receipt_contract_digest=${2:-}; shift 2 || return 2 ;;
      --execution-json) execution=${2:-}; shift 2 || return 2 ;;
      --workspace-repo) workspace_repo=${2:-}; shift 2 || return 2 ;;
      *) return 2 ;;
    esac
  done
  [[ "$timeout" =~ ^[1-9][0-9]*$ && "$#" -gt 0 ]] || return 2
  [[ -r "$stdin_path" && ! -L "$stdin_path" ]] || return 2
  job_prepare_dirs || return 1
  job_prune >/dev/null 2>&1 || true
  jobs="$(job_runtime_root)/jobs"
  job_id="job-$(date '+%s')-$$-${RANDOM}${RANDOM}"
  if [[ -n "$receipt_pre$receipt_repo$receipt_role$receipt_provider$receipt_model$receipt_effort$receipt_contract_digest" ]]; then
    [[ -n "$receipt_repo" && -d "$receipt_repo" && -n "$receipt_role" && -n "$receipt_provider" \
      && -n "$receipt_effort" && -f "$receipt_pre" && ! -L "$receipt_pre" \
      && "$receipt_pre" == "$jobs/"* ]] || return 2
    [[ -z "$receipt_contract_digest" || "$receipt_contract_digest" =~ ^[a-f0-9]{64}$ ]] || return 2
    chmod 600 "$receipt_pre" || { rm -f -- "$receipt_pre"; return 1; }
  fi
  local -a worker_execution_args=() worker_receipt_args=() worker_workspace_args=()
  if [[ "$execution" != '{}' ]]; then
    jq -e 'type == "object" and (.role,.capability,.model,.effort | type == "string" and length > 0)' \
      <<<"$execution" >/dev/null 2>&1 || return 2
    worker_execution_args=(--execution-json "$execution")
  fi
  if [[ -n "$workspace_repo" ]]; then
    [[ -d "$workspace_repo" && ! -L "$workspace_repo" ]] || return 2
    jq -e '.role == "executor"' <<<"$execution" >/dev/null 2>&1 || return 2
    worker_workspace_args=(--workspace-repo "$workspace_repo")
  fi
  if [[ -n "$receipt_pre" ]]; then
    worker_receipt_args=(--receipt "$receipt_repo" "$receipt_pre" "$receipt_role" \
      "$receipt_provider" "$receipt_model" "$receipt_effort" "$receipt_contract_digest")
  fi
  output="$jobs/$job_id.stdout"
  error="$jobs/$job_id.stderr"
  supervisor_log="$jobs/$job_id.supervisor.log"
  : > "$output" && : > "$error" && : > "$supervisor_log" || return 1
  chmod 600 "$output" "$error" "$supervisor_log" || return 1
  if command -v perl >/dev/null 2>&1; then launcher=perl
  elif command -v setsid >/dev/null 2>&1; then launcher=setsid
  else
    printf 'Arkira error 13: setsid or perl is required for async process isolation\n' >&2
    return 13
  fi
  if [[ -n "$workspace_repo" ]]; then
    reserved_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    reserved_epoch="$(date '+%s')"
    # Publish durable ownership before opening the detached-launch crash window.
    job_atomic_record "$job_id" reserved 0 "$provider" "$reserved_started" "$reserved_epoch" \
      "$timeout" "$output" "$error" null "$$" "$execution" || return 1
    job_track_workspace "$workspace_repo" "$job_id" || {
      rm -f -- "$jobs/$job_id.json"
      return 1
    }
  fi
  if [[ "$launcher" == perl ]]; then
    perl -MPOSIX -e '
      $SIG{INT} = "DEFAULT";
      $SIG{TERM} = "DEFAULT";
      $SIG{HUP} = "DEFAULT";
      POSIX::setsid() or die "setsid failed: $!";
      exec @ARGV;
    ' -- /bin/bash "$JOB_CONTROL_SCRIPT" _worker "$job_id" "$provider" "$timeout" \
      "$stdin_path" "$output" "$error" "${worker_execution_args[@]}" \
      "${worker_workspace_args[@]}" "${worker_receipt_args[@]}" "$@" \
      </dev/null >>"$supervisor_log" 2>&1 &
  else
    setsid /bin/bash "$JOB_CONTROL_SCRIPT" _worker "$job_id" "$provider" "$timeout" \
      "$stdin_path" "$output" "$error" "${worker_execution_args[@]}" \
      "${worker_workspace_args[@]}" "${worker_receipt_args[@]}" "$@" \
      </dev/null >>"$supervisor_log" 2>&1 &
  fi
  local worker=$! attempts=0
  if [[ -n "$workspace_repo" ]]; then
    job_release_workspace_lock "$workspace_repo" >/dev/null 2>&1 || true
  fi
  if [[ "${ARKIRA_JOB_CONTROL_TEST_AFTER_SPAWN_DELAY_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
    sleep "$ARKIRA_JOB_CONTROL_TEST_AFTER_SPAWN_DELAY_SECONDS"
  fi
  record="$jobs/$job_id.json"
  while [[ "$attempts" -lt 500 ]]; do
    record_state="$(jq -r '.state // empty' "$record" 2>/dev/null || true)"
    [[ -n "$record_state" && "$record_state" != reserved ]] && break
    kill -0 "$worker" 2>/dev/null || break
    sleep 0.02
    attempts=$((attempts + 1))
  done
  record_state="$(jq -r '.state // empty' "$record" 2>/dev/null || true)"
  if [[ ! -f "$record" || -L "$record" || -z "$record_state" || "$record_state" == reserved ]]; then
    if ! kill -0 "$worker" 2>/dev/null && [[ -n "$workspace_repo" ]]; then
      job_clear_workspace_if "$workspace_repo" "$job_id" >/dev/null 2>&1 || true
    fi
    return 1
  fi
  jq -c '.' "$record"
}

job_reconcile_running() {
  local record=$1 json state pgid provider started started_epoch timeout output error supervisor job_id
  local execution
  local finalization_marker terminate_marker timeout_marker finalization_age terminal exit_code
  local group_alive=0 supervisor_alive=0 attempts=0
  json="$(jq -c '.' "$record" 2>/dev/null)" || return 1
  state="$(printf '%s' "$json" | jq -r '.state // empty')"
  [[ "$state" == running ]] || return 0
  pgid="$(printf '%s' "$json" | jq -r '.pgid // 0')"
  provider="$(printf '%s' "$json" | jq -r '.provider // empty')"
  started="$(printf '%s' "$json" | jq -r '.started // empty')"
  started_epoch="$(printf '%s' "$json" | jq -r '.started_epoch // 0')"
  timeout="$(printf '%s' "$json" | jq -r '.timeout // 0')"
  output="$(printf '%s' "$json" | jq -r '.output_file // empty')"
  error="$(printf '%s' "$json" | jq -r '.error_file // empty')"
  supervisor="$(printf '%s' "$json" | jq -r '.supervisor_pid // 0')"
  job_id="$(printf '%s' "$json" | jq -r '.job_id // empty')"
  execution="$(printf '%s' "$json" | jq -c \
    'if (.role // "") == "" then {} else {role,capability,model,effort} end')"
  [[ "$pgid" =~ ^[1-9][0-9]*$ && "$supervisor" =~ ^[1-9][0-9]*$ \
    && "$started_epoch" =~ ^[0-9]+$ && "$timeout" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$supervisor" 2>/dev/null && supervisor_alive=1
  kill -0 "-$pgid" 2>/dev/null && group_alive=1
  finalization_marker="$(job_runtime_root)/jobs/$job_id.finalizing"
  terminate_marker="$(job_runtime_root)/jobs/$job_id.terminate"
  timeout_marker="$(job_runtime_root)/jobs/$job_id.timeout"
  finalization_age="$(job_marker_age "$finalization_marker" 2>/dev/null || true)"
  if [[ "$supervisor_alive" -eq 1 ]]; then
    if [[ "$finalization_age" =~ ^[0-9]+$ && "$finalization_age" -le "$JOB_FINALIZATION_MAX_SECONDS" ]]; then
      return 0
    fi
    if [[ "$group_alive" -eq 1 ]]; then
      # The provider timer owns a live child process group. Reconcile starts
      # the finalization bound only after that group has exited.
      return 0
    fi
    if [[ ! "$finalization_age" =~ ^[0-9]+$ ]]; then
      # A worker can be scheduled after wait returns but before it publishes
      # finalizing. This lease gives it the same bounded window it would have
      # published itself, then the next reconcile reaps a genuine hang.
      state="$(jq -r '.state // empty' "$record" 2>/dev/null)"
      [[ "$state" != running ]] && return 0
      job_create_marker "$finalization_marker" || return 1
      state="$(jq -r '.state // empty' "$record" 2>/dev/null)"
      if [[ "$state" != running ]]; then
        job_remove_marker "$finalization_marker"
      fi
      return 0
    fi
  fi
  if [[ "$supervisor_alive" -eq 0 ]]; then
    # The worker publishes its terminal record immediately before exit. If status
    # observed the old running record during that atomic handoff, let the publish
    # complete before declaring the supervisor lost.
    attempts=0
    while [[ "$attempts" -lt 10 ]]; do
      state="$(jq -r '.state // empty' "$record" 2>/dev/null)"
      [[ "$state" != running ]] && return 0
      sleep 0.02
      attempts=$((attempts + 1))
    done
    terminal=failed
    exit_code=1
  else
    if [[ -f "$terminate_marker" && ! -L "$terminate_marker" ]]; then
      terminal=terminated
      exit_code=143
    else
      # Publish intent before TERM so the worker trap records the same state.
      job_create_marker "$timeout_marker" || return 1
      terminal=timed_out
      exit_code=14
    fi
  fi
  if [[ "$group_alive" -eq 1 ]]; then
    kill -TERM "-$pgid" 2>/dev/null || true
    sleep 1
    kill -KILL "-$pgid" 2>/dev/null || true
  fi
  if [[ "$supervisor_alive" -eq 1 ]]; then
    kill -TERM "$supervisor" 2>/dev/null || true
    attempts=0
    while kill -0 "$supervisor" 2>/dev/null && [[ "$attempts" -lt 20 ]]; do
      state="$(jq -r '.state // empty' "$record" 2>/dev/null)"
      [[ "$state" != running ]] && return 0
      sleep 0.05
      attempts=$((attempts + 1))
    done
    state="$(jq -r '.state // empty' "$record" 2>/dev/null)"
    [[ "$state" != running ]] && return 0
    kill -KILL "$supervisor" 2>/dev/null || true
    attempts=0
    while [[ "$attempts" -lt 20 ]]; do
      state="$(jq -r '.state // empty' "$record" 2>/dev/null)"
      [[ "$state" != running ]] && return 0
      sleep 0.05
      attempts=$((attempts + 1))
    done
  fi
  job_remove_marker "$terminate_marker"
  job_remove_marker "$timeout_marker"
  job_remove_marker "$finalization_marker"
  job_atomic_record "$(printf '%s' "$json" | jq -r '.job_id')" "$terminal" "$pgid" \
    "$provider" "$started" "$started_epoch" "$timeout" "$output" "$error" \
    "$exit_code" "$supervisor" "$execution"
}

job_status() {
  local job_id=${1:-} record snapshot state barrier attempts
  job_prepare_dirs || return 1
  job_validate_id "$job_id" || { job_fail_unknown; return; }
  record="$(job_record_path "$job_id")" || { job_fail_unknown; return; }
  [[ -f "$record" && ! -L "$record" ]] || { job_fail_unknown; return; }
  jq -e --arg job_id "$job_id" '.job_id == $job_id' "$record" >/dev/null 2>&1 || {
    job_fail_unknown
    return
  }
  job_reconcile_running "$record" || return 1
  snapshot="$(jq -c '.' "$record")" || return 1
  state="$(printf '%s' "$snapshot" | jq -r '.state // empty')"
  if [[ "${ARKIRA_JOB_CONTROL_TEST_MODE:-}" == 1 ]]; then
    barrier=${ARKIRA_JOB_CONTROL_TEST_STATUS_BARRIER:-}
    if [[ -n "$barrier" && -d "$barrier" ]]; then
      : > "$barrier/reached"
      attempts=0
      while [[ ! -f "$barrier/release" && "$attempts" -lt 500 ]]; do
        sleep 0.02
        attempts=$((attempts + 1))
      done
    fi
  fi
  if [[ "$state" != running && "$state" != reserved ]]; then
    job_remove_marker "$(job_runtime_root)/jobs/$job_id.finalizing"
  fi
  # A second read can return terminal before its finalization marker is swept.
  printf '%s\n' "$snapshot"
}

job_workspace_lookup() {
  local repo=${1:-} job_id record snapshot jobs job_control_dir identity receipt_dir receipt receipt_file=""
  local state error_file error_text="" has_error=false
  job_id="$(job_active_workspace "$repo" 2>/dev/null)" || { job_fail_unknown; return; }
  record="$(job_record_path "$job_id")" || { job_fail_unknown; return; }
  [[ -f "$record" && ! -L "$record" ]] || { job_fail_unknown; return; }
  jq -e --arg job_id "$job_id" '.job_id == $job_id' "$record" >/dev/null 2>&1 || {
    job_fail_unknown
    return
  }
  job_reconcile_running "$record" || return 1
  snapshot="$(jq -c '.' "$record")" || return 1
  state="$(printf '%s' "$snapshot" | jq -r '.state // empty')"
  if [[ "$state" != running && "$state" != reserved ]]; then
    job_remove_marker "$(job_runtime_root)/jobs/$job_id.finalizing"
  fi
  job_control_dir="$(cd -- "$(dirname -- "$JOB_CONTROL_SCRIPT")" && pwd -P)" || return 1
  # shellcheck source=ai-engineering/runtime/receipt-lib.sh
  . "$job_control_dir/receipt-lib.sh"
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  receipt_dir="$(arkira_receipt_runtime_root)/receipts/$identity"
  if [[ -d "$receipt_dir" && ! -L "$(arkira_receipt_runtime_root)" \
    && ! -L "$(arkira_receipt_runtime_root)/receipts" && ! -L "$receipt_dir" ]]; then
    for receipt in "$receipt_dir"/receipt-*.json; do
      [[ -f "$receipt" && ! -L "$receipt" ]] || continue
      if jq -e --arg job_id "$job_id" '.job_id == $job_id' "$receipt" >/dev/null 2>&1; then
        receipt_file=$receipt
      fi
    done
  fi
  error_file="$(printf '%s' "$snapshot" | jq -r '.error_file // empty')"
  jobs="$(job_runtime_root)/jobs"
  if [[ "$state" != "done" && "$error_file" == "$jobs/"* && -f "$error_file" \
    && ! -L "$error_file" ]]; then
    error_text="$(tail -c 4096 -- "$error_file" 2>/dev/null || true)"
    has_error=true
  fi
  jq -c --arg receipt_file "$receipt_file" --arg error "$error_text" \
    --argjson has_error "$has_error" '
    {job_id,state,exit_code,output_file,error_file,role,capability,provider,model,effort,
      started,started_epoch,elapsed_seconds,timeout,
      receipt_file:(if $receipt_file == "" then null else $receipt_file end),
      error:(if $has_error then $error else null end)}
  ' <<<"$snapshot"
}

job_wait() {
  local job_id=${1:-} state result exit_code
  while :; do
    result="$(job_status "$job_id")" || return $?
    state="$(printf '%s' "$result" | jq -r '.state')"
    case "$state" in
      running|reserved) sleep 0.05 ;;
      done) printf '%s\n' "$result"; return 0 ;;
      *)
        printf '%s\n' "$result"
        exit_code="$(printf '%s' "$result" | jq -r '.exit_code // 1')"
        [[ "$exit_code" =~ ^[1-9][0-9]*$ && "$exit_code" -le 125 ]] || exit_code=1
        return "$exit_code"
        ;;
    esac
  done
}

job_terminate() {
  local job_id=${1:-} result state pgid marker attempts=0
  result="$(job_status "$job_id")" || return $?
  state="$(printf '%s' "$result" | jq -r '.state')"
  [[ "$state" == running ]] || { printf '%s\n' "$result"; return 0; }
  pgid="$(printf '%s' "$result" | jq -r '.pgid')"
  [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 1
  marker="$(job_runtime_root)/jobs/$job_id.terminate"
  job_create_marker "$marker" || return 1
  kill -TERM "-$pgid" 2>/dev/null || true
  while kill -0 "$pgid" 2>/dev/null && [[ "$attempts" -lt 20 ]]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  kill -KILL "-$pgid" 2>/dev/null || true
  attempts=0
  while [[ "$attempts" -lt 40 ]]; do
    result="$(job_status "$job_id")" || return $?
    [[ "$(printf '%s' "$result" | jq -r '.state')" != running ]] && {
      printf '%s\n' "$result"
      return 0
    }
    sleep 0.05
    attempts=$((attempts + 1))
  done
  return 1
}

job_main() {
  local command=${1:-}
  shift || true
  case "$command" in
    launch) job_launch "$@" ;;
    status) job_status "$@" ;;
    wait) job_wait "$@" ;;
    terminate) job_terminate "$@" ;;
    prune) job_prune ;;
    active) job_active_workspace "$@" ;;
    workspace) job_workspace_lookup "$@" ;;
    clear) job_clear_workspace "$@" ;;
    _worker) job_worker "$@" ;;
    *) printf 'usage: job-control.sh launch|status|wait|terminate|prune|active|workspace|clear\n' >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then job_main "$@"; fi
