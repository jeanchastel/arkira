#!/usr/bin/env bash
set -uo pipefail

runtime_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091  # Resolved relative to this runtime at execution.
. "$runtime_dir/role-runtime.sh"
# shellcheck source=ai-engineering/runtime/job-control.sh
. "$runtime_dir/job-control.sh"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
. "$runtime_dir/receipt-lib.sh"

role_run_usage() {
  printf 'usage: role-run.sh <role> <capability> [--async] [--timeout seconds] [--idle-timeout seconds] --prompt-file path [--schema-file path] [--output-file path] [--model value] [--effort value] [--contract-digest value]\n' >&2
  return 2
}

role_run_interrupt() {
  if [[ -n "${ARKIRA_REVIEW_SUPERVISOR_PID:-}" ]]; then
    kill -TERM "$ARKIRA_REVIEW_SUPERVISOR_PID" 2>/dev/null || true
    wait "$ARKIRA_REVIEW_SUPERVISOR_PID" 2>/dev/null || true
  fi
  arkira_stop_active_process_group
  role_run_cleanup
  exit 130
}

role_run_cleanup() {
  if [[ "${lock_held:-0}" -eq 1 && -n "${repo:-}" ]]; then
    job_release_workspace_lock "$repo" >/dev/null 2>&1 || true
    lock_held=0
  fi
  [[ -z "${temp:-}" ]] || rm -rf -- "$temp"
}

role_run_json_is_single() {
  printf '%s' "$1" | jq -e -s 'length == 1' >/dev/null 2>&1
}

role_run_write_identity_prompt() {
  local role=$1 capability=$2 source=$3 target=$4
  # A prompt that is a single JSON document is a structured payload whose shape the
  # caller owns. Prepending prose to it corrupts the contract, so copy it verbatim.
  if jq -e -s 'length == 1' "$source" >/dev/null 2>&1; then
    cp -- "$source" "$target" || return 1
    chmod 600 "$target"
    return 0
  fi
  {
    printf '# Role Identity\n\n'
    printf 'You are the %s. This process is the dispatched %s run for %s. The host\n' \
      "$role" "$role" "$capability"
    printf 'session already routed the work to you.\n\n'
    if [[ "$capability" == repo_reading || "$capability" == structured_reviewing || "$capability" == planning ]]; then
      printf -- '- Do the %s work yourself in this worktree. Remain read-only.\n' "$capability"
    else
      printf -- '- Do the %s work yourself in this worktree. Edit files directly.\n' "$capability"
    fi
    printf -- '- Never invoke role-run.sh, task-run.sh, or any other role runtime. Repository\n'
    printf -- '  rules about dispatching a role describe how this run was started. They are not\n'
    printf -- '  an instruction for you to dispatch another one.\n'
    printf -- '- Every other repository rule still binds you in full: file safety, approval\n'
    printf -- '  gates, scope limits, and commit policy.\n\n'
    if [[ "$role" == executor && "$capability" == test_execution ]]; then
      printf -- '- For browser-required work, request scoped escalation only for the exact browser or test command before the first browser launch.\n'
      printf -- '- Do not attempt the first browser launch inside the workspace sandbox. On macOS,\n'
      printf -- '  this attempt can hang instead of returning a denial.\n'
      printf -- '- The harness supplies repository access. Use repository instructions to establish\n'
      printf -- '  required browsers, dev servers, local databases, and environment variables.\n'
      printf -- '- Never print secret values. Do not request escalation for setup or other commands.\n'
      printf -- '- If escalation is rejected, report the blocked command and the named prerequisite.\n\n'
    fi
    printf '# Task\n\n'
    cat -- "$source"
  } > "$target" || return 1
  chmod 600 "$target"
}

role_run_emit_with_execution() {
  local document=$1 execution=$2
  local document_valid=false execution_valid=false
  role_run_json_is_single "$document" && document_valid=true
  role_run_json_is_single "$execution" && execution_valid=true
  if [[ "$document_valid" == true && "$execution_valid" == true ]]; then
    jq -cn --argjson document "$document" --argjson execution "$execution" \
      '$document + {execution:$execution}'
  elif [[ "$document_valid" == true ]]; then
    jq -cn --argjson document "$document" --arg execution_raw "$execution" \
      '$document + {execution:null,serialization:{invalid:["execution"],raw:{execution:$execution_raw}}}'
  elif [[ "$execution_valid" == true ]]; then
    jq -cn --arg document_raw "$document" --argjson execution "$execution" \
      '{mode:"unknown",ok:false,execution:$execution,
        serialization:{invalid:["document"],raw:{document:$document_raw}}}'
  else
    jq -cn --arg document_raw "$document" --arg execution_raw "$execution" \
      '{mode:"unknown",ok:false,execution:null,
        serialization:{invalid:["document","execution"],
          raw:{document:$document_raw,execution:$execution_raw}}}'
  fi
}

role_run_emit_sync_result() {
  local ok=$1 rc=$2 stdout_path=$3 stderr_path=$4 usage=$5 execution=$6
  local usage_valid=false execution_valid=false
  local usage_raw=$usage
  if [[ "$#" -ge 7 ]]; then
    usage_raw=$7
  else
    role_run_json_is_single "$usage" && usage_valid=true
  fi
  role_run_json_is_single "$execution" && execution_valid=true
  if [[ "$usage_valid" == true && "$execution_valid" == true ]]; then
    jq -cn --argjson ok "$ok" \
      --rawfile output "$stdout_path" --rawfile error "$stderr_path" --argjson exit_code "$rc" \
      --argjson usage "$usage" --argjson execution "$execution" \
      '{mode:"sync",ok:$ok,output:$output,error:$error,exit_code:$exit_code,usage:$usage,
        execution:$execution}'
  else
    jq -cn --argjson ok "$ok" \
      --rawfile output "$stdout_path" --rawfile error "$stderr_path" --argjson exit_code "$rc" \
      --arg usage_raw "$usage_raw" --arg execution_raw "$execution" \
      --argjson usage_valid "$usage_valid" --argjson execution_valid "$execution_valid" '
      {mode:"sync",ok:$ok,output:$output,error:$error,exit_code:$exit_code,
        usage:(if $usage_valid then ($usage_raw | fromjson) else null end),
        execution:(if $execution_valid then ($execution_raw | fromjson) else null end),
        serialization:{
          invalid:[
            if $usage_valid then empty else "usage" end,
            if $execution_valid then empty else "execution" end
          ],
          raw:({}
            + (if $usage_valid then {} else {usage:$usage_raw} end)
            + (if $execution_valid then {} else {execution:$execution_raw} end))
        }}'
  fi
}

trap role_run_interrupt HUP INT TERM

role_run_main() {
  local role=${1:-} capability=${2:-} async=0 timeout=300 timeout_explicit=0 prompt_file="" schema_file="" output_file=""
  local idle_timeout=${ARKIRA_VERIFIER_IDLE_TIMEOUT_SECONDS:-120} idle_explicit=0 stream_review=0
  local model_request="" effort_request="" contract_digest="" provider model effort execution adapter repo temp
  local stdout_path stderr_path rc=0 schema_enforced result extracted usage previous original arg identity_prompt
  local effort_replacements=0
  local active_job active_blocked=0 lock_held=0
  local receipt_pre receipt_post receipt_metadata sync_job_id typescript_emit_paths='[]'
  local capability_help_stdin capability_help_stdout capability_help_stderr
  local -a command_args=() rewritten_args=() async_receipt_args=() async_workspace_args=()
  unset ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT ARKIRA_RECEIPT_IDENTITY_REPO \
    ARKIRA_RECEIPT_IDENTITY_VALUE ARKIRA_RECEIPT_STORE_IDENTITY ARKIRA_RECEIPT_STORE_DIR
  shift 2 || { role_run_usage; return; }
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --async) async=1; shift ;;
      --timeout) timeout=${2:-}; timeout_explicit=1; shift 2 || { role_run_usage; return; } ;;
      --idle-timeout) idle_timeout=${2:-}; idle_explicit=1; shift 2 || { role_run_usage; return; } ;;
      --prompt-file) prompt_file=${2:-}; shift 2 || { role_run_usage; return; } ;;
      --schema-file) schema_file=${2:-}; shift 2 || { role_run_usage; return; } ;;
      --output-file) output_file=${2:-}; shift 2 || { role_run_usage; return; } ;;
      --model) model_request=${2:-}; shift 2 || { role_run_usage; return; } ;;
      --effort) effort_request=${2:-}; shift 2 || { role_run_usage; return; } ;;
      --contract-digest) contract_digest=${2:-}; shift 2 || { role_run_usage; return; } ;;
      --allow-local-adapter-override) ARKIRA_ALLOW_LOCAL_ADAPTER_OVERRIDE=1; export ARKIRA_ALLOW_LOCAL_ADAPTER_OVERRIDE; shift ;;
      *) role_run_usage; return ;;
    esac
  done
  [[ "$timeout" =~ ^[1-9][0-9]*$ && -f "$prompt_file" && ! -L "$prompt_file" ]] || {
    role_run_usage
    return
  }
  [[ -z "$model_request" || "$model_request" =~ ^[A-Za-z0-9._-]+$ ]] || {
    arkira_error 16 "unsafe per-run model; use letters, digits, dot, underscore, or hyphen"
    return
  }
  [[ -z "$effort_request" || "$effort_request" =~ ^[A-Za-z0-9._-]+$ ]] || {
    arkira_error 16 "unsafe per-run effort; use letters, digits, dot, underscore, or hyphen"
    return
  }
  [[ -z "$contract_digest" || "$contract_digest" =~ ^[a-f0-9]{64}$ ]] || {
    arkira_error 16 "contract digest must be 64 lowercase hexadecimal characters"
    return
  }
  provider="$(arkira_resolve_role "$role" provider)" || return $?
  model="$(arkira_resolve_role "$role" model)" || return $?
  ARKIRA_ACTIVE_ROLE=$role
  export ARKIRA_ACTIVE_ROLE
  if [[ "$provider" == host-session ]]; then
    jq -cn --arg error "role $role is inline in the host session" \
      '{mode:"sync",ok:false,output:"",error:$error,exit_code:12}'
    return 12
  fi
  adapter="$(arkira_adapter_file "$provider")" || return 11
  arkira_validate_adapter_file "$adapter" || return 11
  arkira_adapter_sha_is_trusted "$adapter" "$provider" || {
    arkira_error 11 "adapter $provider failed SHA trust; re-sync it or use the explicit development override"
    return
  }
  jq -e --arg capability "$capability" '.capabilities | index($capability) != null' "$adapter" >/dev/null || {
    arkira_error 12 "$provider lacks $capability; choose a capable provider"
    return
  }
  jq -e --arg capability "$capability" '.invocation[$capability] | type == "object"' "$adapter" >/dev/null || {
    arkira_error 12 "$provider cannot dispatch $capability; choose another capability or provider"
    return
  }
  effort="$(arkira_resolve_effort "$adapter" "$capability")" || return 16
  if [[ -n "$model_request" ]]; then model=$model_request; fi
  if [[ -n "$effort_request" ]]; then
    arkira_effort_supported "$adapter" "$effort_request" || {
      arkira_error 16 "$provider does not support effort $effort_request"
      return
    }
    effort=$effort_request
  fi
  [[ -n "$model" && -n "$effort" ]] || {
    arkira_error 16 "dispatched roles require explicit model and effort"
    return
  }
  schema_enforced="$(jq -r --arg capability "$capability" \
    '.invocation[$capability].schema_enforced == true' "$adapter")"
  if [[ "$provider" == claude-code && "$capability" == structured_reviewing ]] &&
    jq -e '.invocation.structured_reviewing.output == "stream-json"' "$adapter" >/dev/null; then
    stream_review=1
    [[ "$timeout_explicit" -eq 1 ]] || timeout=900
    [[ "$timeout" =~ ^[1-9][0-9]{0,4}$ && "$idle_timeout" =~ ^[1-9][0-9]{0,4}$ ]] || {
      arkira_error 16 "review timeout and inactivity bounds must be positive integers of at most five digits"
      return
    }
  elif [[ "$idle_explicit" -eq 1 ]]; then
    arkira_error 16 "--idle-timeout requires a streaming Claude structured review"
    return
  fi
  if [[ "$schema_enforced" == true ]]; then
    [[ -f "$schema_file" && ! -L "$schema_file" ]] || {
      arkira_error 15 "structured output requires a safe schema file"
      return
    }
    if [[ "$async" -eq 1 ]]; then
      arkira_error 15 "schema-enforced calls must run synchronously so output can be validated"
      return
    fi
  fi
  if [[ "$role" == executor && "$schema_enforced" != true ]]; then
    # A synchronous Executor dies with its launching session and leaves no durable record.
    async=1
  fi
  repo="$(arkira_repo_root)" || return 16
  execution="$(jq -cn --arg role "$role" --arg capability "$capability" \
    --arg provider "$provider" --arg model "$model" --arg effort "$effort" \
    '{role:$role,capability:$capability,provider:$provider,model:$model,effort:$effort,model_source:"requested",effort_source:"requested"}')"
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-role-run.XXXXXX")" || return 1
  chmod 700 "$temp"
  stdout_path="$temp/stdout"
  stderr_path="$temp/stderr"
  : > "$stdout_path" && : > "$stderr_path"
  chmod 600 "$stdout_path" "$stderr_path"
  # Nothing in the piped prompt tells the receiving agent which role it is, so it
  # reads the repository dispatch rule as binding on itself and shells back out.
  identity_prompt="$temp/prompt"
  role_run_write_identity_prompt "$role" "$capability" "$prompt_file" "$identity_prompt" || {
    rm -rf -- "$temp"
    return 1
  }
  prompt_file=$identity_prompt
  [[ -n "$output_file" ]] || output_file="$temp/provider-output"
  while IFS= read -r -d '' result; do command_args+=("$result"); done < <(
    arkira_build_command "$adapter" "$capability" "$model" "$repo" "$schema_file" "$output_file" "$timeout"
  )
  if [[ -n "$effort_request" ]]; then
    previous=""
    for arg in "${command_args[@]}"; do
      original=$arg
      if [[ "$previous" == --effort ]]; then
        arg=$effort_request
        effort_replacements=$((effort_replacements + 1))
      elif [[ "$previous" == -c && "$arg" == model_reasoning_effort=* ]]; then
        arg="model_reasoning_effort=\"$effort_request\""
        effort_replacements=$((effort_replacements + 1))
      fi
      rewritten_args+=("$arg")
      previous=$original
    done
    [[ "$effort_replacements" -gt 0 ]] || {
      rm -rf -- "$temp"
      arkira_error 16 "adapter effort argument could not be rewritten"
      return
    }
    command_args=("${rewritten_args[@]}")
  fi
  [[ "${#command_args[@]}" -gt 0 ]] || { rm -rf -- "$temp"; return 12; }
  command -v "${command_args[0]}" >/dev/null 2>&1 || {
    rm -rf -- "$temp"
    arkira_error 13 "provider binary ${command_args[0]} is missing; install it and retry"
    return
  }
  if [[ "$provider" == codex-cli && "$capability" == test_execution ]]; then
    capability_help_stdin="$temp/capability-help.stdin"
    capability_help_stdout="$temp/capability-help.stdout"
    capability_help_stderr="$temp/capability-help.stderr"
    : > "$capability_help_stdin"
    if ! arkira_run_with_timeout "$capability_help_stdout" "$capability_help_stderr" 10 \
      "$capability_help_stdin" "${command_args[0]}" exec --help; then
      rm -rf -- "$temp"
      arkira_error 13 'codex exec capability check failed; install a Codex CLI with --approve-for-me'
      return
    fi
    if ! grep -Fq -- '--approve-for-me' "$capability_help_stdout" "$capability_help_stderr"; then
      rm -rf -- "$temp"
      arkira_error 13 'codex exec lacks --approve-for-me; update Codex before browser dispatch'
      return
    fi
  fi
  arkira_auth_preflight "$adapter" || { rc=$?; rm -rf -- "$temp"; return "$rc"; }
  if [[ "$role" == executor ]]; then
    if ! job_claim_workspace_lock "$repo"; then
      active_job="$(job_active_workspace "$repo" 2>/dev/null || true)"
      rm -rf -- "$temp"
      result="$(jq -cn --arg active_job_id "${active_job:-dispatch-reservation}" \
        '{mode:"blocked",ok:false,active_job_id:$active_job_id,error:"an Executor is already active in this worktree; if it is not, clear the stale marker with ai-engineering/runtime/job-control.sh clear <repo>",exit_code:19}')"
      role_run_emit_with_execution "$result" "$execution"
      return 19
    fi
    lock_held=1
    active_job="$(job_active_workspace "$repo" 2>/dev/null || true)"
    if [[ -n "$active_job" ]]; then
      # Reconcile first so a running record whose supervisor died is republished
      # terminal, then judge the marker on liveness alone. An empty state used to
      # count as running, which made a deleted job record permanently fatal.
      job_status "$active_job" >/dev/null 2>&1 || true
      if job_workspace_owner_is_live "$active_job"; then
        active_blocked=1
      else
        active_blocked=0
      fi
      if [[ "$active_blocked" -eq 1 ]]; then
        role_run_cleanup
        result="$(jq -cn --arg active_job_id "$active_job" \
          '{mode:"blocked",ok:false,active_job_id:$active_job_id,error:"an Executor is already active in this worktree; if it is not, clear the stale marker with ai-engineering/runtime/job-control.sh clear <repo>",exit_code:19}')"
        role_run_emit_with_execution "$result" "$execution"
        return 19
      fi
      job_clear_workspace "$repo" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$async" -eq 1 ]]; then
    if [[ "$role" == executor ]]; then
      job_prepare_dirs || {
        role_run_cleanup
        return 1
      }
      receipt_pre="$(mktemp "$(job_runtime_root)/jobs/.receipt-pre.XXXXXX")" || {
        role_run_cleanup
        return 1
      }
      chmod 600 "$receipt_pre" || {
        rm -f -- "$receipt_pre"
        role_run_cleanup
        return 1
      }
      arkira_receipt_snapshot "$repo" "$receipt_pre" || {
        rm -f -- "$receipt_pre"
        role_run_cleanup
        return 1
      }
      async_receipt_args=(--receipt-repo "$repo" --receipt-pre "$receipt_pre" --receipt-role executor
        --receipt-provider "$provider" --receipt-model "$model" --receipt-effort "$effort")
      if [[ -n "$contract_digest" ]]; then
        async_receipt_args+=(--receipt-contract-digest "$contract_digest")
      fi
      async_workspace_args=(--workspace-repo "$repo")
    fi
    result="$(job_launch "$provider" "$timeout" --stdin "$prompt_file" \
      --execution-json "$execution" \
      "${async_workspace_args[@]}" \
      "${async_receipt_args[@]}" \
      "${command_args[@]}")" || {
        rc=$?
        [[ -n "${receipt_pre:-}" ]] && rm -f -- "$receipt_pre"
        role_run_cleanup
        return "$rc"
    }
    role_run_cleanup
    result="$(printf '%s\n' "$result" | jq -c \
      '{mode:"async",ok:true,job_id,pgid,state:"running",provider,started,timeout,error:""}')"
    role_run_emit_with_execution "$result" "$execution"
    return 0
  fi
  if [[ "$role" == executor ]]; then
    receipt_pre="$temp/receipt-pre"
    arkira_receipt_snapshot "$repo" "$receipt_pre" || {
      role_run_cleanup
      return 1
    }
  fi
  if [[ "$stream_review" -eq 1 ]]; then
    ARKIRA_REVIEW_OWNER_PID=$$ node "$runtime_dir/review-progress.mjs" "$timeout" "$idle_timeout" "$prompt_file" \
      "$stdout_path" "$stderr_path" "$temp/progress.json" "${command_args[@]}" &
    ARKIRA_REVIEW_SUPERVISOR_PID=$!
    wait "$ARKIRA_REVIEW_SUPERVISOR_PID" || rc=$?
    ARKIRA_REVIEW_SUPERVISOR_PID=""
    if [[ -s "$temp/progress.json" ]]; then
      execution="$(jq -c --slurpfile progress "$temp/progress.json" '. + {progress:$progress[0]}' <<<"$execution")"
    fi
  else
    arkira_run_with_timeout "$stdout_path" "$stderr_path" "$timeout" "$prompt_file" "${command_args[@]}" || rc=$?
    if [[ "$rc" -eq 14 ]]; then
      printf 'Arkira error 14: provider timed out; increase the bounded timeout or reduce the task\n' > "$stderr_path"
    fi
  fi
  # Read usage from the raw provider envelope before schema extraction below overwrites it.
  usage="$(arkira_extract_usage "$stdout_path")"
  # Keep provider-resolved aliases before structured-output extraction discards the envelope.
  local observed_models
  observed_models="$(jq -cs '[.[] | select(type=="object") | (.modelUsage // {}) | keys[]] | unique' "$stdout_path" 2>/dev/null || printf '[]')"
  execution="$(jq -c --argjson observed "$observed_models" '. + {observed_models:$observed,observed_effort:null}' <<<"$execution")"

  if [[ "$rc" -eq 0 && "$schema_enforced" == true ]]; then
    if [[ "$provider" == claude-code ]]; then
      extracted="$temp/structured-output"
      if ! jq -e 'if (.structured_output? != null) then .structured_output
        elif (.result? | type) == "string" then (.result | fromjson)
        else empty end' "$stdout_path" > "$extracted" 2>/dev/null; then
        rc=15
        printf 'Arkira error 15: Claude output did not contain structured JSON; retry with a conforming response\n' > "$stderr_path"
      else
        mv -- "$extracted" "$stdout_path"
      fi
    fi
    if [[ -s "$output_file" ]]; then result=$output_file; else result=$stdout_path; fi
    if ! arkira_validate_json_schema "$schema_file" "$result"; then
      rc=15
      printf 'Arkira error 15: provider output failed schema validation; retry with a conforming response\n' > "$stderr_path"
    elif [[ "$result" == "$output_file" ]]; then
      cp -- "$output_file" "$stdout_path"
    fi
  fi
  if [[ "$rc" -ne 0 && -n "$model" && "$rc" -ne 14 && "$rc" -ne 15 ]]; then
    rc=17
  fi
  if [[ "$role" == executor && "$rc" -eq 0 ]]; then
    receipt_post="$temp/receipt-post"
    sync_job_id="sync-$(date '+%s')-$$-${RANDOM}${RANDOM}"
    receipt_metadata="$(jq -cn --arg role executor --arg provider "$provider" --arg model "$model" \
      --arg effort "$effort" --arg job_id "$sync_job_id" --arg contract_digest "$contract_digest" \
      '{author_role:$role,author_provider:$provider,author_model:$model,
        author_effort:$effort,job_id:$job_id}
        + (if $contract_digest == "" then {} else {contract_digest:$contract_digest} end)')"
    if ! arkira_receipt_snapshot "$repo" "$receipt_post" || \
      ! arkira_receipt_write "$repo" "$receipt_pre" "$receipt_post" "$receipt_metadata" >/dev/null; then
      if [[ -n "$contract_digest" ]]; then
        rc=1
        printf 'Arkira error: governed executor receipt write failed\n' >&2
      else
        printf 'Arkira warning: executor receipt write failed\n' >&2
      fi
    elif ! typescript_emit_paths="$(
      arkira_receipt_new_typescript_emit_paths "$receipt_pre" "$receipt_post"
    )"; then
      if [[ -n "$contract_digest" ]]; then
        rc=1
        printf 'Arkira error: governed executor residue check failed\n' >&2
      else
        printf 'Arkira warning: executor residue check failed\n' >&2
      fi
    elif jq -e 'length > 0' <<< "$typescript_emit_paths" >/dev/null; then
      printf 'Arkira error: Executor created TypeScript compiler residue next to source files: %s\n' \
        "$typescript_emit_paths" >> "$stderr_path"
      printf 'Remove unintended files before retrying. Review intentional outputs before a new dispatch.\n' \
        >> "$stderr_path"
      rc=1
    fi
  fi
  # Test-only: force degraded serialization; this seam cannot report usage.
  if [[ -n "${ARKIRA_ROLE_RUN_TEST_USAGE_OVERRIDE:-}" ]]; then
    role_run_emit_sync_result "$([[ "$rc" -eq 0 ]] && printf true || printf false)" \
      "$rc" "$stdout_path" "$stderr_path" "$usage" "$execution" \
      "$ARKIRA_ROLE_RUN_TEST_USAGE_OVERRIDE"
  else
    role_run_emit_sync_result "$([[ "$rc" -eq 0 ]] && printf true || printf false)" \
      "$rc" "$stdout_path" "$stderr_path" "$usage" "$execution"
  fi
  role_run_cleanup
  return "$rc"
}

role_run_main "$@"
