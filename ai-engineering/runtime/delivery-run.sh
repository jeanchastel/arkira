#!/usr/bin/env bash
set -euo pipefail
runtime_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$runtime_dir/goal-run.sh"
. "$runtime_dir/job-control.sh"
repo=${1:?target repo required}
command=${2:?delivery command required}
shift 2
identity="$(arkira_receipt_repo_identity "$repo")"
directory="$(arkira_goal_state_dir "$repo")"
file="$directory/delivery.json"
arkira_receipt_reject_symlink_components "$file" || exit 1
if [[ "$command" == delivery-status ]]; then
  exec node "$runtime_dir/delivery.mjs" status "$file" "$repo"
fi
if [[ -f "$file" ]]; then
  bound_cwd="$(jq -r '.cwd' "$file")"
  if [[ "$(realpath "$repo")" != "$(realpath "$bound_cwd")" ]]; then
    prior_state="$(jq -r '.state // "unknown"' "$file")"
    [[ "$command" == bind-delivery \
      && ( "$prior_state" == completed || "$prior_state" == cancelled ) ]] || {
      printf 'delivery: invoke from the bound worktree: %s\n' "$bound_cwd" >&2; exit 1;
    }
  fi
fi
if [[ "$command" == _scheduled ]]; then
  if [[ ! -f "$directory/active.json" || ! -f "$file" ]]; then
    node "$runtime_dir/delivery-schedule.mjs" "$file" "$repo" "$runtime_dir/delivery-run.sh" remove || true
    exit 0
  fi
  state="$(jq -r '.state // "unknown"' "$file" 2>/dev/null || true)"
  case "$state" in
    completed|blocked|cancelled)
      node "$runtime_dir/delivery-schedule.mjs" "$file" "$repo" "$runtime_dir/delivery-run.sh" remove || true
      exit 0 ;;
  esac
  command=watch
fi
[[ -f "$directory/active.json" ]] || { printf 'delivery: no active goal\n' >&2; exit 1; }
case "$command" in
  delivery-status) exec node "$runtime_dir/delivery.mjs" status "$file" "$repo" ;;
  bind-delivery) operation=bind ;;
  cancel-delivery)
    active_job="$(job_active_workspace "$repo" 2>/dev/null || true)"
    if [[ -n "$active_job" ]] && job_workspace_owner_is_live "$active_job"; then
      [[ "$(jq -r '.provider' "$(job_record_path "$active_job")")" == native-delivery ]] || {
        printf 'delivery: another task owns the worktree; cancellation did not stop it\n' >&2; exit 1;
      }
      job_terminate "$active_job" >/dev/null
    fi
    operation=cancel ;;
  recover|_recover) operation=recover ;;
  watch)
    state="$(jq -r '.state // "unknown"' "$file")"
    case "$state" in completed|blocked|cancelled) cat "$file"; exit 0 ;; esac
    # Existing process-group supervisor survives the calling session; one job per worktree.
    job_claim_workspace_lock "$repo" || { printf 'delivery: worktree is owned by another job\n' >&2; exit 1; }
    trap 'job_release_workspace_lock "$repo" >/dev/null 2>&1 || true' EXIT
    active_job="$(job_active_workspace "$repo" 2>/dev/null || true)"
    if [[ -n "$active_job" ]] && job_workspace_owner_is_live "$active_job"; then
      job_status "$active_job"; exit 0
    fi
    job_launch native-delivery 3600 --workspace-repo "$repo" \
      --execution-json '{"role":"executor","capability":"delivery_verification","model":"native-session","effort":"preserved"}' \
      bash "$runtime_dir/delivery-run.sh" "$repo" _watch
    exit ;;
  _watch)
    for ((attempt=0; attempt<120; attempt++)); do
      bash "$runtime_dir/delivery-run.sh" "$repo" _recover
      state="$(jq -r '.state' "$file")"
      case "$state" in completed|blocked|cancelled) exit 0 ;; esac
      sleep 30
    done
    printf 'delivery: watch window ended; scheduled recovery or goal recover can continue\n' >&2
    exit ;;
  schedule)
    # Native macOS scheduler invokes the same bounded watcher. No webhook receiver/service.
    [[ "$(uname -s)" == Darwin ]] || { printf 'delivery: use the OS scheduler to invoke goal watch every 30 seconds\n' >&2; exit 1; }
    node "$runtime_dir/delivery-schedule.mjs" "$file" "$repo" "$runtime_dir/delivery-run.sh"
    exit ;;
  *) printf 'delivery: use bind-delivery|delivery-status|watch|recover|cancel-delivery|schedule\n' >&2; exit 2 ;;
esac
# Separate namespace shares the existing atomic PID lock implementation across all worktrees.
lock_key="$(printf 'delivery:%s' "$identity" | arkira_receipt_sha256)"
if ! job_claim_workspace_key_lock "$lock_key"; then
  printf 'delivery: another recovery owns this goal\n' >&2
  [[ "$operation" == recover ]] && exit 0
  exit 1
fi
trap 'job_release_workspace_key_lock "$lock_key" >/dev/null 2>&1 || true' EXIT
# Interactive recover also respects a detached owner; its own _recover worker may proceed.
if [[ "$command" == recover ]]; then
  active_job="$(job_active_workspace "$repo" 2>/dev/null || true)"
  if [[ -n "$active_job" ]] && job_workspace_owner_is_live "$active_job"; then job_status "$active_job"; exit 0; fi
fi
if [[ "$operation" == bind && -f "$file" ]]; then
  state="$(jq -r '.state' "$file")"
  if [[ "$state" == completed || "$state" == cancelled ]]; then
    node "$runtime_dir/delivery-schedule.mjs" "$file" "$repo" "$runtime_dir/delivery-run.sh" remove
    mkdir -p "$directory/history"
    mv -- "$file" "$directory/history/delivery-$(date +%s)-$$.json"
  fi
fi
node "$runtime_dir/delivery.mjs" "$operation" "$file" "$repo" "$@"
state="$(jq -r '.state' "$file")"
if [[ "$state" == completed ]]; then
  goal_id="$(jq -r '.goal_id' "$file")"
  [[ "$(jq -r '.goal_id' "$directory/active.json")" == "$goal_id" ]] || exit 1
  node "$runtime_dir/delivery-schedule.mjs" "$file" "$repo" "$runtime_dir/delivery-run.sh" remove
  arkira_goal_write_state "$directory/history/$goal_id-completed.json" \
    "$(jq '.state="completed"' "$directory/active.json")"
  rm -- "$directory/active.json"
elif [[ "$operation" == cancel ]]; then
  # Remove the scheduler before its journal; retain evidence for explicit rebinding.
  node "$runtime_dir/delivery-schedule.mjs" "$file" "$repo" "$runtime_dir/delivery-run.sh" remove
  mkdir -p "$directory/history"
  mv -- "$file" "$directory/history/delivery-$(date +%s)-$$.json"
fi
