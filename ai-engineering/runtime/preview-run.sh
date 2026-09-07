#!/usr/bin/env bash
set -uo pipefail

ARKIRA_PREVIEW_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/goal-run.sh
. "$ARKIRA_PREVIEW_DIR/goal-run.sh"

arkira_preview_error() {
  printf 'preview: %s\n' "$*" >&2
  return 1
}

arkira_preview_state_dir() {
  local repo=$1 identity runtime directory
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  runtime="$(arkira_receipt_runtime_root)" || return 1
  directory="$runtime/previews/$identity"
  [[ ! -L "$runtime/previews" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory/history" "$directory/acceptances" || return 1
  chmod 700 "$runtime/previews" "$directory" "$directory/history" "$directory/acceptances" || return 1
  printf '%s' "$directory"
}

arkira_preview_active_path() { printf '%s/active.json' "$(arkira_preview_state_dir "$1")"; }

arkira_preview_write() {
  local target=$1 document=$2 directory stage
  directory="$(dirname -- "$target")"
  [[ -d "$directory" && ! -L "$directory" && ! -L "$target" ]] || return 1
  stage="$(mktemp "$directory/.preview.XXXXXX")" || return 1
  printf '%s\n' "$document" > "$stage" || { rm -f -- "$stage"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
}

arkira_preview_process_matches() {
  local pid=$1 pgid=$2 expected=$3 request=$4 response=$5 nonce answer attempt=0
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" == "$pgid" \
    && "$expected" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ -f "$request" && ! -L "$request" && ! -L "$response" ]] || return 1
  nonce="$(printf '%s\0%s\0%s\0%s' "$expected" "$$" "$RANDOM" "$(date +%s)" \
    | arkira_receipt_sha256)" || return 1
  arkira_preview_write "$request" "$nonce" || return 1
  while (( attempt < 10 )); do
    if [[ -f "$response" && ! -L "$response" ]]; then
      answer="$(cat -- "$response" 2>/dev/null || true)"
      [[ "$answer" == "$expected $nonce" ]] && return 0
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

arkira_preview_capture_process_identity() {
  local pid=$1 pgid=$2 identity=$3 request=$4 response=$5 attempt=0
  while (( attempt < 20 )); do
    arkira_preview_process_matches "$pid" "$pgid" "$identity" "$request" "$response" && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

arkira_preview_identity_responder() {
  local request=$1 response=$2 identity=$3 nonce last_nonce=""
  trap '' TERM
  while :; do
    if [[ -f "$request" && ! -L "$request" ]]; then
      nonce="$(cat -- "$request" 2>/dev/null || true)"
      if [[ "$nonce" =~ ^[a-f0-9]{64}$ && "$nonce" != "$last_nonce" ]]; then
        arkira_preview_write "$response" "$identity $nonce" || return 1
        last_nonce=$nonce
      fi
    fi
    sleep 0.02
  done
}

arkira_preview_supervise_process() {
  local request=$1 response=$2 identity=$3 responder child status=0
  shift 3
  arkira_preview_identity_responder "$request" "$response" "$identity" &
  responder=$!
  "$@" &
  child=$!
  trap 'kill -TERM "$child" 2>/dev/null || true' HUP INT TERM
  while :; do
    if wait "$child"; then status=0; break; else status=$?; fi
    kill -0 "$child" 2>/dev/null || break
  done
  kill -KILL "$responder" 2>/dev/null || true
  wait "$responder" 2>/dev/null || true
  trap - HUP INT TERM
  return "$status"
}

arkira_preview_read_active() {
  local repo=$1 active identity
  active="$(arkira_preview_active_path "$repo")" || return 1
  [[ -f "$active" && ! -L "$active" ]] || { arkira_preview_error 'no active preview'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  jq -e --arg identity "$identity" '
    .schema_version == 1 and .repo_identity == $identity and
    (.state | IN("starting","running")) and
    (.contract_digest | type == "string" and test("^[a-f0-9]{64}$")) and
    .identity_protocol == "challenge-v1" and
    (.pid | type == "number" and . > 0) and (.pgid | type == "number" and . > 0) and
    (.process_identity | type == "string" and test("^[a-f0-9]{64}$")) and
    (.url | type == "string" and startswith("http://"))
  ' "$active" >/dev/null 2>&1 || { arkira_preview_error 'active preview state is malformed'; return 1; }
  cat "$active"
}

arkira_preview_stop_process() {
  local pid=$1 pgid=$2 process_identity=$3 request=$4 response=$5 attempt=0
  arkira_preview_process_matches "$pid" "$pgid" "$process_identity" "$request" "$response" || {
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    arkira_preview_error 'refusing to stop a process that does not own this preview record'
    return 1
  }
  kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || {
    arkira_preview_error 'failed to signal the verified preview process'
    return 1
  }
  while arkira_preview_process_matches "$pid" "$pgid" "$process_identity" "$request" "$response" \
    && (( attempt < 20 )); do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if arkira_preview_process_matches "$pid" "$pgid" "$process_identity" "$request" "$response"; then
    kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || {
      arkira_preview_error 'failed to stop the verified preview process'
      return 1
    }
  fi
  wait "$pid" 2>/dev/null || true
}

arkira_preview_start() {
  local repo=${1:-} contract=${2:-} root active directory identity digest url log now document pid pgid process_identity
  local ready_seconds deadline identity_request identity_response
  local -a command_argv=()
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    arkira_preview_error 'target is not a Git repository'; return 1;
  }
  root="$(cd -- "$root" && pwd -P)" || return 1
  arkira_task_contract_validate "$contract" || return 1
  [[ "$(jq -r '.ui.mode' "$contract")" == local-review ]] || {
    arkira_preview_error 'Task contract UI mode must be local-review'; return 1;
  }
  active="$(arkira_preview_active_path "$root")" || return 1
  [[ ! -e "$active" && ! -L "$active" ]] || { arkira_preview_error 'a preview is already active'; return 1; }
  directory="$(dirname -- "$active")"
  identity="$(arkira_receipt_repo_identity "$root")" || return 1
  digest="$(arkira_task_contract_bind "$root" "$contract")" || return 1
  url="$(jq -r '.ui.review_url' "$contract")"
  while IFS= read -r -d '' argument; do command_argv+=("$argument"); done \
    < <(jq -j '.ui.dev_command[] | ., "\u0000"' "$contract")
  (( ${#command_argv[@]} > 0 )) || return 1
  log="$directory/preview-$digest.log"
  identity_request="$directory/preview-$digest.identity-request"
  identity_response="$directory/preview-$digest.identity-response"
  [[ ! -L "$log" ]] || return 1
  : > "$log" || return 1
  chmod 600 "$log" || return 1
  process_identity="$(printf '%s\0%s\0%s\0%s' "$identity" "$digest" "$$" "$RANDOM" \
    | arkira_receipt_sha256)" || return 1
  arkira_preview_write "$identity_request" "" || return 1
  arkira_preview_write "$identity_response" "" || return 1
  (
    cd -- "$root" || exit 1
    if command -v setsid >/dev/null 2>&1; then
      exec setsid bash "$ARKIRA_PREVIEW_DIR/preview-run.sh" __supervise-process \
        "$identity_request" "$identity_response" "$process_identity" "${command_argv[@]}"
    else
      exec perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!"; exec @ARGV' -- \
        bash "$ARKIRA_PREVIEW_DIR/preview-run.sh" __supervise-process \
        "$identity_request" "$identity_response" "$process_identity" "${command_argv[@]}"
    fi
  ) >> "$log" 2>&1 &
  pid=$!
  pgid=$pid
  arkira_preview_capture_process_identity "$pid" "$pgid" "$process_identity" \
    "$identity_request" "$identity_response" || {
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  }
  now="$(date +%s)"
  document="$(jq -n --arg identity "$identity" --arg digest "$digest" --arg state starting \
    --arg url "$url" --arg log "$log" --arg process_identity "$process_identity" \
    --argjson pid "$pid" --argjson pgid "$pgid" --argjson now "$now" \
    '{schema_version:1,repo_identity:$identity,contract_digest:$digest,state:$state,url:$url,
      log_file:$log,pid:$pid,pgid:$pgid,identity_protocol:"challenge-v1",
      process_identity:$process_identity,
      started_epoch:$now,updated_epoch:$now}')" || return 1
  arkira_preview_write "$active" "$document" || {
    arkira_preview_stop_process "$pid" "$pgid" "$process_identity" "$identity_request" "$identity_response"
    return 1
  }
  ready_seconds=${ARKIRA_PREVIEW_READY_SECONDS:-60}
  [[ "$ready_seconds" =~ ^[1-9][0-9]*$ ]] || ready_seconds=60
  deadline=$(( $(date +%s) + ready_seconds ))
  while (( $(date +%s) <= deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    if curl --fail --silent --show-error --max-time 2 "$url" >/dev/null 2>&1; then
      now="$(date +%s)"
      document="$(jq -c --argjson now "$now" '.state="running" | .updated_epoch=$now' <<< "$document")" || return 1
      arkira_preview_write "$active" "$document" || {
        arkira_preview_stop_process "$pid" "$pgid" "$process_identity" "$identity_request" "$identity_response"
        return 1
      }
      printf '%s\n' "$document"
      return 0
    fi
    sleep 0.2
  done
  if ! arkira_preview_stop_process "$pid" "$pgid" "$process_identity" \
    "$identity_request" "$identity_response"; then
    arkira_preview_error 'server readiness timed out and verified stop failed; active record preserved'
    return 1
  fi
  rm -f -- "$active" "$identity_request" "$identity_response"
  arkira_preview_error "server was not ready within $ready_seconds seconds; log=$log"
}

arkira_preview_status() {
  local repo=$1 state pid pgid process_identity directory digest request response alive=false
  state="$(arkira_preview_read_active "$repo")" || return 1
  pid="$(jq -r '.pid' <<< "$state")"
  pgid="$(jq -r '.pgid' <<< "$state")"
  process_identity="$(jq -r '.process_identity' <<< "$state")"
  directory="$(dirname -- "$(arkira_preview_active_path "$repo")")"
  digest="$(jq -r '.contract_digest' <<< "$state")"
  request="$directory/preview-$digest.identity-request"
  response="$directory/preview-$digest.identity-response"
  arkira_preview_process_matches "$pid" "$pgid" "$process_identity" "$request" "$response" && alive=true
  jq -c --argjson alive "$alive" '. + {alive:$alive}' <<< "$state"
}

arkira_preview_finish() {
  local repo=$1 outcome=$2 state active directory now tree acceptance updated history pid pgid process_identity
  local digest request response
  state="$(arkira_preview_read_active "$repo")" || return 1
  active="$(arkira_preview_active_path "$repo")" || return 1
  directory="$(dirname -- "$active")"
  pid="$(jq -r '.pid' <<< "$state")"
  pgid="$(jq -r '.pgid' <<< "$state")"
  process_identity="$(jq -r '.process_identity' <<< "$state")"
  digest="$(jq -r '.contract_digest' <<< "$state")"
  request="$directory/preview-$digest.identity-request"
  response="$directory/preview-$digest.identity-response"
  now="$(date +%s)"
  tree=''
  if [[ "$outcome" == accepted ]]; then
    tree="$(arkira_goal_worktree_tree "$repo")" || return 1
    acceptance="$directory/acceptances/$tree.json"
    updated="$(jq -c --arg outcome "$outcome" --arg tree "$tree" --argjson now "$now" \
      '.state=$outcome | .candidate_tree=$tree | .updated_epoch=$now' <<< "$state")" || return 1
  else
    updated="$(jq -c --arg outcome "$outcome" --argjson now "$now" \
      '.state=$outcome | .updated_epoch=$now' <<< "$state")" || return 1
  fi
  arkira_preview_stop_process "$pid" "$pgid" "$process_identity" "$request" "$response" || return 1
  history="$directory/history/preview-$now-$outcome.json"
  arkira_preview_write "$history" "$updated" || return 1
  rm -f -- "$active" "$request" "$response" || return 1
  if [[ "$outcome" == accepted ]]; then
    arkira_preview_write "$acceptance" "$updated" || return 1
  fi
  printf '%s\n' "$updated"
}

arkira_preview_accept() { arkira_preview_finish "$1" accepted; }
arkira_preview_reject() { arkira_preview_finish "$1" rejected; }
arkira_preview_stop() { arkira_preview_finish "$1" stopped; }

arkira_preview_recover() {
  local repo=$1 active state identity now directory history updated alive=false modern=false
  local pid pgid process_identity digest request="" response="" recovery warning
  active="$(arkira_preview_active_path "$repo")" || return 1
  [[ -f "$active" && ! -L "$active" ]] || { arkira_preview_error 'no active preview'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  state="$(cat -- "$active")" || return 1
  jq -e --arg identity "$identity" '
    .schema_version == 1 and .repo_identity == $identity and
    (.state | IN("starting","running")) and
    (.contract_digest | type == "string" and test("^[a-f0-9]{64}$")) and
    (.pid | type == "number" and . > 0) and (.pgid | type == "number" and . > 0) and
    (.url | type == "string" and startswith("http://"))
  ' <<< "$state" >/dev/null 2>&1 || { arkira_preview_error 'active preview state is malformed'; return 1; }
  directory="$(dirname -- "$active")"
  pid="$(jq -r '.pid' <<< "$state")"
  pgid="$(jq -r '.pgid' <<< "$state")"
  if [[ "$(jq -r '.identity_protocol // empty' <<< "$state")" == challenge-v1 ]]; then
    modern=true
    process_identity="$(jq -r '.process_identity // empty' <<< "$state")"
    digest="$(jq -r '.contract_digest' <<< "$state")"
    request="$directory/preview-$digest.identity-request"
    response="$directory/preview-$digest.identity-response"
    if arkira_preview_process_matches "$pid" "$pgid" "$process_identity" "$request" "$response"; then
      arkira_preview_status "$repo"
      return
    fi
  fi
  kill -0 "$pid" 2>/dev/null && alive=true
  if [[ "$modern" == true && "$alive" == true ]]; then
    arkira_preview_error 'unverified preview process is still alive; refusing to signal or detach it'
    return 1
  fi
  if [[ "$modern" == true ]]; then
    recovery=challenge-detached
    warning='preview record detached after its owner stopped answering challenges; no PID was signaled'
  else
    recovery=legacy-detached
    warning='legacy preview record detached without signaling an unverified PID'
  fi
  now="$(date +%s)"
  updated="$(jq -c --argjson now "$now" --argjson alive "$alive" \
    --arg recovery "$recovery" --arg warning "$warning" \
    '.state=$recovery | .recovery=$recovery | .updated_epoch=$now | .alive=$alive |
     .warning=$warning' <<< "$state")" || return 1
  history="$directory/history/preview-$now-$recovery.json"
  arkira_preview_write "$history" "$updated" || return 1
  rm -f -- "$active" || return 1
  if [[ "$modern" == true ]]; then rm -f -- "$request" "$response" || return 1; fi
  printf '%s\n' "$updated"
}

arkira_preview_acceptance_valid() {
  local repo=$1 tree=$2 directory target identity
  [[ "$tree" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]] || return 1
  directory="$(arkira_preview_state_dir "$repo")" || return 1
  target="$directory/acceptances/$tree.json"
  [[ -f "$target" && ! -L "$target" ]] || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  jq -e --arg identity "$identity" --arg tree "$tree" '
    .schema_version == 1 and .repo_identity == $identity and .state == "accepted" and
    .candidate_tree == $tree and (.contract_digest | test("^[a-f0-9]{64}$"))
  ' "$target" >/dev/null 2>&1
}

arkira_preview_usage() {
  printf 'usage: preview-run.sh <repo> start --contract FILE | status|accept|reject|stop|recover\n' >&2
  return 2
}

arkira_preview_main() {
  local repo=${1:-} command=${2:-}
  if [[ "$repo" == __supervise-process ]]; then
    shift
    [[ "$#" -ge 4 ]] || return 2
    arkira_preview_supervise_process "$@"
    return
  fi
  [[ -n "$repo" && -n "$command" ]] || { arkira_preview_usage; return; }
  shift 2
  case "$command" in
    start) [[ "$#" -eq 2 && "$1" == --contract ]] || { arkira_preview_usage; return; }; arkira_preview_start "$repo" "$2" ;;
    status) [[ "$#" -eq 0 ]] || { arkira_preview_usage; return; }; arkira_preview_status "$repo" ;;
    recover) [[ "$#" -eq 0 ]] || { arkira_preview_usage; return; }; arkira_preview_recover "$repo" ;;
    accept) [[ "$#" -eq 0 ]] || { arkira_preview_usage; return; }; arkira_preview_accept "$repo" ;;
    reject) [[ "$#" -eq 0 ]] || { arkira_preview_usage; return; }; arkira_preview_reject "$repo" ;;
    stop) [[ "$#" -eq 0 ]] || { arkira_preview_usage; return; }; arkira_preview_stop "$repo" ;;
    *) arkira_preview_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_preview_main "$@"; fi
