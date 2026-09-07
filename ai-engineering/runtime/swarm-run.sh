#!/usr/bin/env bash
set -uo pipefail

ARKIRA_SWARM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/goal-run.sh
. "$ARKIRA_SWARM_DIR/goal-run.sh"

arkira_swarm_error() {
  printf 'swarm: %s\n' "$*" >&2
  return 1
}

arkira_swarm_root() {
  local repo=$1 identity runtime directory
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  runtime="$(arkira_receipt_runtime_root)" || return 1
  directory="$runtime/swarms/$identity"
  [[ ! -L "$runtime/swarms" && ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory/runs" || return 1
  chmod 700 "$runtime/swarms" "$directory" "$directory/runs" || return 1
  printf '%s' "$directory"
}

arkira_swarm_active_path() { printf '%s/active.json' "$(arkira_swarm_root "$1")"; }

arkira_swarm_write() {
  local target=$1 document=$2 directory stage
  directory="$(dirname -- "$target")"
  [[ -d "$directory" && ! -L "$directory" && ! -L "$target" ]] || return 1
  stage="$(mktemp "$directory/.swarm.XXXXXX")" || return 1
  printf '%s\n' "$document" > "$stage" || { rm -f -- "$stage"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
}

arkira_swarm_process_matches() {
  local run_dir=$1 pid=$2 pgid=$3 expected=$4 request response nonce answer attempt=0
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" == "$pgid" \
    && "$expected" =~ ^[a-f0-9]{64}$ ]] || return 1
  request="$run_dir/identity-request"
  response="$run_dir/identity-response"
  [[ -d "$run_dir" && ! -L "$run_dir" && -f "$request" && ! -L "$request" \
    && ! -L "$response" ]] || return 1
  nonce="$(printf '%s\0%s\0%s\0%s' "$expected" "$$" "$RANDOM" "$(date +%s)" \
    | arkira_receipt_sha256)" || return 1
  arkira_swarm_write "$request" "$nonce" || return 1
  while (( attempt < 25 )); do
    if [[ -f "$response" && ! -L "$response" ]]; then
      answer="$(cat -- "$response" 2>/dev/null || true)"
      [[ "$answer" == "$expected $nonce" ]] && return 0
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

arkira_swarm_capture_process_identity() {
  local run_dir=$1 pid=$2 pgid=$3 identity=$4 attempt=0
  while (( attempt < 20 )); do
    arkira_swarm_process_matches "$run_dir" "$pid" "$pgid" "$identity" && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

arkira_swarm_identity_responder() {
  local run_dir=$1 identity=$2 request response nonce last_nonce=""
  request="$run_dir/identity-request"
  response="$run_dir/identity-response"
  while :; do
    if [[ -f "$request" && ! -L "$request" ]]; then
      nonce="$(cat -- "$request" 2>/dev/null || true)"
      if [[ "$nonce" =~ ^[a-f0-9]{64}$ && "$nonce" != "$last_nonce" ]]; then
        arkira_swarm_write "$response" "$identity $nonce" || return 1
        last_nonce=$nonce
      fi
    fi
    sleep 0.02
  done
}

arkira_swarm_publish() {
  local repo=$1 run_dir=$2 document=$3
  arkira_swarm_write "$run_dir/state.json" "$document" || return 1
  arkira_swarm_write "$(arkira_swarm_active_path "$repo")" "$document"
}

arkira_swarm_contract_scope_allows() {
  local scope=$1 contract=$2 entry
  while IFS= read -r entry; do
    if [[ "$scope" == "$entry" || "$scope" == "$entry"/* || "$entry" == "$scope"/* ]]; then
      return 1
    fi
  done < <(jq -r '.scope.protected[]' <<< "$contract")
  while IFS= read -r entry; do
    [[ "$scope" == "$entry" || "$scope" == "$entry"/* ]] && return 0
  done < <(jq -r '.scope.allowed[]' <<< "$contract")
  return 1
}

arkira_swarm_validate_manifest() {
  local repo=$1 manifest=$2 goal contract contract_digest mode count id prompt check scope
  local left right i j
  [[ -f "$manifest" && ! -L "$manifest" ]] || { arkira_swarm_error 'manifest must be a regular file'; return 1; }
  jq -e '
    .schema_version == 1 and (.mode | IN("read","write")) and
    (.contract_digest | type == "string" and test("^[a-f0-9]{64}$")) and
    (.units | type == "array" and length >= 2 and length <= 3) and
    ([.units[].id] | length == (unique | length)) and
    ([.units[] | select(.final == true)] | length <= 1) and
    (([.units[] | select(.final == true)] | length) == 0 or (.units[-1].final == true)) and
    all(.units[];
      (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,31}$")) and
      (.scope | type == "array") and
      (.prompt_file | type == "string" and length > 0) and
      (.focused_check | type == "string" and length > 0) and
      ((.final // false) | type == "boolean"))
  ' "$manifest" >/dev/null 2>&1 || { arkira_swarm_error 'manifest is invalid'; return 1; }
  goal="$(arkira_goal_read_active "$repo")" || return 1
  [[ "$(jq -r '.state' <<< "$goal")" == running ]] || { arkira_swarm_error 'goal must be running'; return 1; }
  contract_digest="$(jq -r '.contract_digest' "$manifest")"
  [[ "$contract_digest" == "$(jq -r '.contract_digest' <<< "$goal")" ]] || {
    arkira_swarm_error 'manifest contract digest does not match the active goal'; return 1;
  }
  contract="$(arkira_task_contract_load "$repo" "$contract_digest")" || return 1
  mode="$(jq -r '.mode' "$manifest")"
  count="$(jq '.units | length' "$manifest")"
  for ((i=0; i<count; i++)); do
    id="$(jq -r ".units[$i].id" "$manifest")"
    prompt="$(jq -r ".units[$i].prompt_file" "$manifest")"
    [[ -f "$prompt" && ! -L "$prompt" ]] || { arkira_swarm_error "unit prompt is not a regular file: $id"; return 1; }
    check="$(jq -r ".units[$i].focused_check" "$manifest")"
    [[ "$check" != *run-all-tests.sh* ]] || { arkira_swarm_error "unit focused check is a group run: $id"; return 1; }
    [[ "$mode" != write || "$(jq ".units[$i].scope | length" "$manifest")" -gt 0 ]] || {
      arkira_swarm_error "writer scope is empty: $id"; return 1;
    }
    while IFS= read -r scope; do
      arkira_validate_relative_path "$scope" || { arkira_swarm_error "unit scope is unsafe: $id"; return 1; }
      if [[ "$mode" == write ]] && ! arkira_swarm_contract_scope_allows "$scope" "$contract"; then
        arkira_swarm_error "unit scope is outside the parent Task contract: $id"
        return 1
      fi
    done < <(jq -r ".units[$i].scope[]" "$manifest")
  done
  [[ "$mode" != write ]] && return 0
  for ((i=0; i<count; i++)); do
    for ((j=i+1; j<count; j++)); do
      if [[ "$(jq -r ".units[$i].final // false" "$manifest")" == true \
        || "$(jq -r ".units[$j].final // false" "$manifest")" == true ]]; then
        continue
      fi
      while IFS= read -r left; do
        while IFS= read -r right; do
          if [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]; then
            arkira_swarm_error "writer scopes overlap: $left and $right"
            return 1
          fi
        done < <(jq -r ".units[$j].scope[]" "$manifest")
      done < <(jq -r ".units[$i].scope[]" "$manifest")
    done
  done
}

arkira_swarm_snapshot_commit() {
  local repo=$1 tree commit
  tree="$(arkira_goal_worktree_tree "$repo")" || return 1
  commit="$(printf 'Arkira swarm snapshot\n' | \
    GIT_AUTHOR_NAME=Arkira GIT_AUTHOR_EMAIL=local@arkira.invalid \
    GIT_COMMITTER_NAME=Arkira GIT_COMMITTER_EMAIL=local@arkira.invalid \
    git -C "$repo" commit-tree "$tree" -p HEAD)" || return 1
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || return 1
  printf '%s' "$commit"
}

arkira_swarm_add_worktree() {
  local repo=$1 commit=$2 path=$3
  [[ ! -e "$path" && ! -L "$path" ]] || return 1
  mkdir -p -- "$(dirname -- "$path")" || return 1
  git -C "$repo" worktree add -q --detach "$path" "$commit"
}

arkira_swarm_remove_worktree() {
  local repo=$1 path=$2
  [[ "$path" == */worktrees/* ]] || return 1
  git -C "$repo" worktree remove --force "$path" >/dev/null 2>&1 || true
}

arkira_swarm_scope_allows() {
  local path=$1 unit_json=$2 entry
  while IFS= read -r entry; do
    [[ "$path" == "$entry" || "$path" == "$entry"/* ]] && return 0
  done < <(jq -r '.scope[]' <<< "$unit_json")
  return 1
}

arkira_swarm_default_worker() {
  local worktree=$1 prompt=$2 contract_digest=$3 model=$4 effort=$5 mode=$6 output job_id capability
  capability=code_editing
  [[ "$mode" == read ]] && capability=repo_reading
  output="$(cd -- "$worktree" && ARKIRA_REPO_ROOT="$worktree" \
    "$ARKIRA_HARNESS_ROOT/ai-engineering/runtime/role-run.sh" executor "$capability" \
      --async --prompt-file "$prompt" --model "$model" --effort "$effort" \
      --contract-digest "$contract_digest")" || return 1
  job_id="$(jq -er '.job_id' <<< "$output" 2>/dev/null)" || return 1
  (cd -- "$worktree" && ARKIRA_REPO_ROOT="$worktree" \
    "$ARKIRA_HARNESS_ROOT/ai-engineering/runtime/task-run.sh" "$worktree" watch "$job_id")
}

arkira_swarm_unit_attempt() {
  local repo=$1 run_dir=$2 snapshot=$3 unit_json=$4 mode=$5 contract_digest=$6 model=$7 effort=$8 attempt=$9
  local id prompt check worktree output error patch path status=done started duration stdout stderr
  id="$(jq -r '.id' <<< "$unit_json")"
  prompt="$(jq -r '.prompt_file' <<< "$unit_json")"
  check="$(jq -r '.focused_check' <<< "$unit_json")"
  worktree="$run_dir/worktrees/$id-$attempt"
  output="$run_dir/$id-$attempt.out"
  error="$run_dir/$id-$attempt.err"
  patch="$run_dir/$id.patch"
  started="$(date +%s)"
  arkira_swarm_add_worktree "$repo" "$snapshot" "$worktree" || return 1
  if [[ -n ${ARKIRA_SWARM_WORKER:-} ]]; then
    ARKIRA_SWARM_ATTEMPT="$attempt" "$ARKIRA_SWARM_WORKER" "$worktree" "$prompt" > "$output" 2> "$error" || status=failed
  else
    arkira_swarm_default_worker "$worktree" "$prompt" "$contract_digest" "$model" "$effort" "$mode" > "$output" 2> "$error" || status=failed
  fi
  if [[ "$status" == done ]]; then
    git -C "$worktree" add -A -- . || status=failed
  fi
  if [[ "$status" == done && "$mode" == read ]]; then
    if [[ -n "$(git -C "$worktree" diff --cached --name-only "$snapshot")" ]]; then status=failed; fi
  elif [[ "$status" == done ]]; then
    while IFS= read -r -d '' path; do
      arkira_swarm_scope_allows "$path" "$unit_json" || { status=failed; break; }
    done < <(git -C "$worktree" diff --cached --name-only -z "$snapshot")
    if [[ "$status" == done ]]; then
      stdout="$run_dir/$id-$attempt-check.out"
      stderr="$run_dir/$id-$attempt-check.err"
      arkira_run_with_timeout "$stdout" "$stderr" 180 /dev/null bash -c "cd \"\$1\" && $check" bash "$worktree" || status=failed
    fi
    if [[ "$status" == done ]]; then
      git -C "$worktree" diff --cached --binary --full-index "$snapshot" > "$patch" || status=failed
      [[ -s "$patch" ]] || status=failed
    fi
  fi
  duration=$(( $(date +%s) - started ))
  arkira_swarm_remove_worktree "$repo" "$worktree"
  jq -n --arg id "$id" --arg state "$status" --arg patch "$patch" \
    --arg output "$output" --arg error "$error" --arg model "$model" --arg effort "$effort" \
    --argjson attempt "$attempt" --argjson duration "$duration" \
    '{id:$id,state:$state,attempt:$attempt,retry_count:($attempt-1),patch_file:$patch,
      output_file:$output,error_file:$error,model:$model,effort:$effort,duration_seconds:$duration}'
  [[ "$status" == done ]]
}

arkira_swarm_run_unit() {
  local repo=$1 run_dir=$2 snapshot=$3 unit_json=$4 mode=$5 contract_digest=$6 model=$7 effort=$8 id result
  id="$(jq -r '.id' <<< "$unit_json")"
  if result="$(arkira_swarm_unit_attempt "$repo" "$run_dir" "$snapshot" "$unit_json" "$mode" "$contract_digest" "$model" "$effort" 1)"; then
    arkira_swarm_write "$run_dir/$id-result.json" "$result"
    return 0
  fi
  if result="$(arkira_swarm_unit_attempt "$repo" "$run_dir" "$snapshot" "$unit_json" "$mode" "$contract_digest" "$model" "$effort" 2)"; then
    arkira_swarm_write "$run_dir/$id-result.json" "$result"
    return 0
  fi
  arkira_swarm_write "$run_dir/$id-result.json" "$result"
  return 1
}

arkira_swarm_aggregate_commit() {
  local repo=$1 run_dir=$2 snapshot=$3 manifest=$4 worktree tree commit id patch
  worktree="$run_dir/worktrees/aggregate"
  arkira_swarm_add_worktree "$repo" "$snapshot" "$worktree" || return 1
  while IFS= read -r id; do
    patch="$(jq -r '.patch_file' "$run_dir/$id-result.json")" || {
      arkira_swarm_remove_worktree "$repo" "$worktree"; return 1;
    }
    if ! git -C "$worktree" apply --check "$patch" || ! git -C "$worktree" apply "$patch"; then
      arkira_swarm_remove_worktree "$repo" "$worktree"
      return 1
    fi
  done < <(jq -r '.units[] | select((.final // false) == false) | .id' "$manifest")
  git -C "$worktree" add -A -- . || { arkira_swarm_remove_worktree "$repo" "$worktree"; return 1; }
  tree="$(git -C "$worktree" write-tree)" || { arkira_swarm_remove_worktree "$repo" "$worktree"; return 1; }
  commit="$(printf 'Arkira swarm peer aggregate\n' | \
    GIT_AUTHOR_NAME=Arkira GIT_AUTHOR_EMAIL=local@arkira.invalid \
    GIT_COMMITTER_NAME=Arkira GIT_COMMITTER_EMAIL=local@arkira.invalid \
    git -C "$repo" commit-tree "$tree" -p "$snapshot")" || {
      arkira_swarm_remove_worktree "$repo" "$worktree"; return 1;
    }
  arkira_swarm_remove_worktree "$repo" "$worktree"
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || return 1
  printf '%s' "$commit"
}

arkira_swarm_integrate() {
  local repo=$1 run_dir=$2 snapshot=$3 expected_fingerprint=$4 manifest=$5 combined expected_worktree expected_tree actual_tree id patch
  combined="$run_dir/combined.patch"
  expected_worktree="$run_dir/worktrees/integration"
  arkira_swarm_add_worktree "$repo" "$snapshot" "$expected_worktree" || return 1
  while IFS= read -r id; do
    patch="$(jq -r '.patch_file' "$run_dir/$id-result.json")" || {
      arkira_swarm_remove_worktree "$repo" "$expected_worktree"; return 1;
    }
    if ! git -C "$expected_worktree" apply --check "$patch" \
      || ! git -C "$expected_worktree" apply "$patch"; then
      arkira_swarm_remove_worktree "$repo" "$expected_worktree"
      return 1
    fi
  done < <(jq -r '.units[].id' "$manifest")
  git -C "$expected_worktree" add -A -- . || {
    arkira_swarm_remove_worktree "$repo" "$expected_worktree"; return 1;
  }
  expected_tree="$(git -C "$expected_worktree" write-tree)" || {
    arkira_swarm_remove_worktree "$repo" "$expected_worktree"; return 1;
  }
  git -C "$expected_worktree" diff --cached --binary --full-index "$snapshot" > "$combined" || {
    arkira_swarm_remove_worktree "$repo" "$expected_worktree"; return 1;
  }
  arkira_swarm_remove_worktree "$repo" "$expected_worktree"
  [[ -s "$combined" ]] || return 1
  [[ "$(arkira_goal_fingerprint "$repo")" == "$expected_fingerprint" ]] || {
    arkira_swarm_error 'primary worktree moved before integration'; return 1;
  }
  git -C "$repo" apply --check "$combined" || return 1
  git -C "$repo" apply "$combined" || return 1
  if [[ "${ARKIRA_SWARM_TEST_FAIL_AFTER_APPLY:-}" == 1 ]]; then
    actual_tree=forced-test-failure
  else
    actual_tree="$(arkira_goal_worktree_tree "$repo" 2>/dev/null || true)"
  fi
  if [[ "$actual_tree" != "$expected_tree" ]]; then
    if ! git -C "$repo" apply -R --check "$combined" || ! git -C "$repo" apply -R "$combined" \
      || [[ "$(arkira_goal_fingerprint "$repo")" != "$expected_fingerprint" ]]; then
      arkira_swarm_error 'integration rollback failed; primary state requires operator recovery'
      return 1
    fi
    arkira_swarm_error 'integrated tree did not match verified combined tree'
    return 1
  fi
  if ! arkira_goal_seal "$repo" >/dev/null; then
    if ! git -C "$repo" apply -R --check "$combined" || ! git -C "$repo" apply -R "$combined" \
      || [[ "$(arkira_goal_fingerprint "$repo")" != "$expected_fingerprint" ]]; then
      arkira_swarm_error 'goal seal and integration rollback failed; primary state requires operator recovery'
      return 1
    fi
    arkira_swarm_error 'goal seal failed; integrated patch was rolled back'
    return 1
  fi
}

arkira_swarm_supervise() {
  local repo=$1 run_dir=$2 meta manifest snapshot fingerprint mode contract_digest model effort state started now
  local count i unit pid failed=0 units retry_count duration final_unit final_snapshot
  local -a pids=()
  meta="$run_dir/meta.json"
  manifest="$run_dir/manifest.json"
  while [[ ! -f "$run_dir/start" ]]; do sleep 0.02; done
  snapshot="$(jq -r '.snapshot_commit' "$meta")"
  fingerprint="$(jq -r '.primary_fingerprint' "$meta")"
  mode="$(jq -r '.mode' "$manifest")"
  contract_digest="$(jq -r '.contract_digest' "$manifest")"
  model="$(jq -r '.model' "$meta")"
  effort="$(jq -r '.effort' "$meta")"
  started="$(jq -r '.started_epoch' "$meta")"
  count="$(jq '.units | length' "$manifest")"
  for ((i=0; i<count; i++)); do
    unit="$(jq -c ".units[$i]" "$manifest")"
    if [[ "$(jq -r '.final // false' <<< "$unit")" == true ]]; then
      final_unit="$unit"
      continue
    fi
    arkira_swarm_run_unit "$repo" "$run_dir" "$snapshot" "$unit" "$mode" "$contract_digest" "$model" "$effort" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  if [[ "$failed" -eq 0 && -n ${final_unit:-} ]]; then
    final_snapshot="$snapshot"
    if [[ "$mode" == write ]]; then
      final_snapshot="$(arkira_swarm_aggregate_commit "$repo" "$run_dir" "$snapshot" "$manifest")" || failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
      arkira_swarm_run_unit "$repo" "$run_dir" "$final_snapshot" "$final_unit" "$mode" "$contract_digest" "$model" "$effort" || failed=1
    fi
  fi
  units="$(jq -sc '.' "$run_dir"/*-result.json)" || failed=1
  retry_count="$(jq '[.[].retry_count] | add // 0' <<< "$units")" || retry_count=0
  if [[ "$failed" -eq 0 && "$mode" == write ]]; then
    arkira_swarm_integrate "$repo" "$run_dir" "$snapshot" "$fingerprint" "$manifest" || failed=1
  fi
  now="$(date +%s)"
  duration=$((now - started))
  state="$(cat "$run_dir/state.json")" || return 1
  if [[ "$failed" -eq 0 ]]; then
    state="$(jq -c --argjson units "$units" --argjson retry "$retry_count" --argjson duration "$duration" --argjson now "$now" \
      '.state="complete" | .units=$units | .retry_count=$retry | .duration_seconds=$duration | .updated_epoch=$now' <<< "$state")" || return 1
    arkira_swarm_publish "$repo" "$run_dir" "$state" || return 1
    return 0
  fi
  state="$(jq -c --argjson units "$units" --argjson retry "$retry_count" --argjson duration "$duration" --argjson now "$now" \
    '.state="failed" | .units=$units | .retry_count=$retry | .duration_seconds=$duration | .updated_epoch=$now' <<< "$state")" || return 1
  arkira_swarm_publish "$repo" "$run_dir" "$state"
  return 1
}

arkira_swarm_supervise_with_identity() {
  local repo=$1 run_dir=$2 identity responder status=0
  identity="$(jq -er '.supervisor_identity | select(test("^[a-f0-9]{64}$"))' \
    "$run_dir/meta.json")" || return 1
  arkira_swarm_identity_responder "$run_dir" "$identity" &
  responder=$!
  trap 'kill -TERM "$responder" 2>/dev/null || true; wait "$responder" 2>/dev/null || true; exit 143' HUP INT TERM
  arkira_swarm_supervise "$repo" "$run_dir" || status=$?
  kill -TERM "$responder" 2>/dev/null || true
  wait "$responder" 2>/dev/null || true
  trap - HUP INT TERM
  return "$status"
}

arkira_swarm_dispatch() {
  local repo=${1:-} manifest=${2:-} root active goal contract contract_digest model effort fingerprint snapshot
  local identity swarm_root manifest_digest swarm_id run_dir now state pid pgid process_identity meta
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { arkira_swarm_error 'target is not a Git repository'; return 1; }
  root="$(cd -- "$root" && pwd -P)" || return 1
  arkira_swarm_validate_manifest "$root" "$manifest" || return 1
  active="$(arkira_swarm_active_path "$root")" || return 1
  if [[ -e "$active" || -L "$active" ]]; then
    [[ -f "$active" && ! -L "$active" ]] || return 1
    case "$(jq -r '.state // empty' "$active" 2>/dev/null)" in running|reserved) arkira_swarm_error 'a swarm is already active'; return 1 ;; esac
  fi
  goal="$(arkira_goal_read_active "$root")" || return 1
  contract_digest="$(jq -r '.contract_digest' "$manifest")"
  contract="$(arkira_task_contract_load "$root" "$contract_digest")" || return 1
  model="$(jq -r '.dispatch.model' <<< "$contract")"
  effort="$(jq -r '.dispatch.effort' <<< "$contract")"
  fingerprint="$(arkira_goal_fingerprint "$root")" || return 1
  snapshot="$(arkira_swarm_snapshot_commit "$root")" || return 1
  identity="$(arkira_receipt_repo_identity "$root")" || return 1
  swarm_root="$(arkira_swarm_root "$root")" || return 1
  manifest_digest="$(jq -S -c . "$manifest" | arkira_receipt_sha256)" || return 1
  swarm_id="swarm-${manifest_digest:0:16}"
  run_dir="$swarm_root/runs/$swarm_id"
  [[ ! -e "$run_dir" && ! -L "$run_dir" ]] || { arkira_swarm_error 'swarm manifest already dispatched'; return 1; }
  mkdir -p -- "$run_dir/worktrees" || return 1
  chmod 700 "$run_dir" "$run_dir/worktrees" || return 1
  cp -- "$manifest" "$run_dir/manifest.json" || return 1
  chmod 600 "$run_dir/manifest.json" || return 1
  now="$(date +%s)"
  process_identity="$(printf '%s\0%s\0%s\0%s' "$identity" "$swarm_id" "$$" "$RANDOM" \
    | arkira_receipt_sha256)" || return 1
  meta="$(jq -n --arg snapshot "$snapshot" --arg fingerprint "$fingerprint" --arg model "$model" \
    --arg effort "$effort" --arg process_identity "$process_identity" --argjson now "$now" \
    '{schema_version:1,snapshot_commit:$snapshot,primary_fingerprint:$fingerprint,model:$model,
      effort:$effort,supervisor_identity:$process_identity,started_epoch:$now}')" || return 1
  arkira_swarm_write "$run_dir/meta.json" "$meta" || return 1
  arkira_swarm_write "$run_dir/identity-request" "" || return 1
  arkira_swarm_write "$run_dir/identity-response" "" || return 1
  state="$(jq -n --arg id "$swarm_id" --arg identity "$identity" --arg state reserved \
    --arg mode "$(jq -r '.mode' "$manifest")" --arg contract "$contract_digest" \
    --arg model "$model" --arg effort "$effort" --arg snapshot "$snapshot" \
    --arg fingerprint "$fingerprint" --argjson count "$(jq '.units | length' "$manifest")" --argjson now "$now" \
    '{schema_version:1,swarm_id:$id,repo_identity:$identity,state:$state,mode:$mode,
      contract_digest:$contract,model:$model,effort:$effort,snapshot_commit:$snapshot,
      primary_fingerprint:$fingerprint,unit_count:$count,units:[],retry_count:0,
      identity_protocol:"challenge-v1",started_epoch:$now,updated_epoch:$now}')" || return 1
  arkira_swarm_publish "$root" "$run_dir" "$state" || return 1
  (
    if command -v setsid >/dev/null 2>&1; then
      exec setsid bash "$ARKIRA_SWARM_DIR/swarm-run.sh" supervise "$root" "$run_dir"
    else
      exec perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!"; exec @ARGV' -- \
        bash "$ARKIRA_SWARM_DIR/swarm-run.sh" supervise "$root" "$run_dir"
    fi
  ) > "$run_dir/supervisor.out" 2> "$run_dir/supervisor.err" &
  pid=$!
  pgid=$pid
  arkira_swarm_capture_process_identity "$run_dir" "$pid" "$pgid" "$process_identity" || {
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  }
  state="$(jq -c --argjson pid "$pid" --argjson pgid "$pgid" --arg process_identity "$process_identity" \
    '.state="running" | .supervisor_pid=$pid | .supervisor_pgid=$pgid | .supervisor_identity=$process_identity' \
    <<< "$state")" || return 1
  arkira_swarm_publish "$root" "$run_dir" "$state" || return 1
  : > "$run_dir/start"
  chmod 600 "$run_dir/start"
  printf '%s\n' "$state"
}

arkira_swarm_status() {
  local repo=$1 active identity
  active="$(arkira_swarm_active_path "$repo")" || return 1
  [[ -f "$active" && ! -L "$active" ]] || { arkira_swarm_error 'no swarm record'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  jq -e --arg identity "$identity" '
    .schema_version == 1 and .repo_identity == $identity and
    (.swarm_id | type == "string" and test("^swarm-[a-f0-9]{16}$")) and
    (.state | IN("reserved","running","complete","failed","terminated"))
  ' "$active" >/dev/null 2>&1 || return 1
  cat "$active"
}

arkira_swarm_watch() {
  local repo=$1 state status pid pgid process_identity interval run_dir
  interval=${ARKIRA_SWARM_WATCH_POLL_SECONDS:-1}
  [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ && "$interval" =~ [1-9] ]] || interval=1
  while :; do
    state="$(arkira_swarm_status "$repo")" || return 1
    status="$(jq -r '.state' <<< "$state")"
    case "$status" in
      complete) printf '%s\n' "$state"; return 0 ;;
      failed|terminated) printf '%s\n' "$state"; return 1 ;;
      reserved|running)
        pid="$(jq -r '.supervisor_pid // 0' <<< "$state")"
        pgid="$(jq -r '.supervisor_pgid // 0' <<< "$state")"
        process_identity="$(jq -r '.supervisor_identity // empty' <<< "$state")"
        run_dir="$(arkira_swarm_root "$repo")/runs/$(jq -r '.swarm_id' <<< "$state")"
        if ! arkira_swarm_process_matches "$run_dir" "$pid" "$pgid" "$process_identity"; then
          sleep "$interval"
          state="$(arkira_swarm_status "$repo")" || return 1
          status="$(jq -r '.state' <<< "$state")"
          [[ "$status" != running && "$status" != reserved ]] || { arkira_swarm_error 'swarm supervisor exited without a terminal record'; return 1; }
          continue
        fi
        sleep "$interval"
        ;;
    esac
  done
}

arkira_swarm_terminate() {
  local repo=$1 state pid pgid process_identity now updated run_dir
  state="$(arkira_swarm_status "$repo")" || return 1
  [[ "$(jq -r '.state' <<< "$state")" == running ]] || { arkira_swarm_error 'swarm is not running'; return 1; }
  pid="$(jq -r '.supervisor_pid' <<< "$state")"
  pgid="$(jq -r '.supervisor_pgid' <<< "$state")"
  process_identity="$(jq -r '.supervisor_identity // empty' <<< "$state")"
  if kill -0 "$pid" 2>/dev/null; then
    run_dir="$(arkira_swarm_root "$repo")/runs/$(jq -r '.swarm_id' <<< "$state")"
    arkira_swarm_process_matches "$run_dir" "$pid" "$pgid" "$process_identity" || {
      arkira_swarm_error 'refusing to terminate a process that does not own this swarm record'
      return 1
    }
    kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  fi
  now="$(date +%s)"
  updated="$(jq -c --argjson now "$now" '.state="terminated" | .updated_epoch=$now' <<< "$state")" || return 1
  run_dir="${run_dir:-$(arkira_swarm_root "$repo")/runs/$(jq -r '.swarm_id' <<< "$state")}"
  arkira_swarm_publish "$repo" "$run_dir" "$updated" || return 1
  printf '%s\n' "$updated"
}

arkira_swarm_recover() {
  local repo=$1 state status pid pgid process_identity now updated run_dir modern=false recovery warning
  state="$(arkira_swarm_status "$repo")" || return 1
  status="$(jq -r '.state' <<< "$state")"
  [[ "$status" == running || "$status" == reserved ]] || { printf '%s\n' "$state"; return; }
  run_dir="$(arkira_swarm_root "$repo")/runs/$(jq -r '.swarm_id' <<< "$state")"
  pid="$(jq -r '.supervisor_pid // 0' <<< "$state")"
  pgid="$(jq -r '.supervisor_pgid // 0' <<< "$state")"
  process_identity="$(jq -r '.supervisor_identity // empty' <<< "$state")"
  if [[ "$(jq -r '.identity_protocol // empty' <<< "$state")" == challenge-v1 ]]; then
    modern=true
    if arkira_swarm_process_matches "$run_dir" "$pid" "$pgid" "$process_identity"; then
      printf '%s\n' "$state"
      return
    fi
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    arkira_swarm_error 'unverified swarm supervisor is still alive; refusing to signal or detach it'
    return 1
  fi
  if [[ "$modern" == true ]]; then
    recovery=challenge-detached
    warning='stale swarm record recovered after its supervisor stopped answering challenges; no PID was signaled'
  else
    recovery=legacy-detached
    warning='legacy swarm record recovered without signaling an unverified PID'
  fi
  now="$(date +%s)"
  updated="$(jq -c --argjson now "$now" --arg recovery "$recovery" --arg warning "$warning" \
    '.state="terminated" | .updated_epoch=$now | .recovery=$recovery |
     .warning=$warning' <<< "$state")" || return 1
  arkira_swarm_publish "$repo" "$run_dir" "$updated" || return 1
  printf '%s\n' "$updated"
}

arkira_swarm_usage() {
  printf 'usage: swarm-run.sh <repo> dispatch --manifest FILE | status|watch|recover|terminate\n' >&2
  return 2
}

arkira_swarm_main() {
  local first=${1:-} second=${2:-}
  if [[ "$first" == supervise ]]; then
    [[ "$#" -eq 3 ]] || return 2
    arkira_swarm_supervise_with_identity "$second" "$3"
    return
  fi
  [[ -n "$first" && -n "$second" ]] || { arkira_swarm_usage; return; }
  shift 2
  case "$second" in
    dispatch) [[ "$#" -eq 2 && "$1" == --manifest ]] || { arkira_swarm_usage; return; }; arkira_swarm_dispatch "$first" "$2" ;;
    status) [[ "$#" -eq 0 ]] || { arkira_swarm_usage; return; }; arkira_swarm_status "$first" ;;
    recover) [[ "$#" -eq 0 ]] || { arkira_swarm_usage; return; }; arkira_swarm_recover "$first" ;;
    watch) [[ "$#" -eq 0 ]] || { arkira_swarm_usage; return; }; arkira_swarm_watch "$first" ;;
    terminate) [[ "$#" -eq 0 ]] || { arkira_swarm_usage; return; }; arkira_swarm_terminate "$first" ;;
    *) arkira_swarm_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_swarm_main "$@"; fi
