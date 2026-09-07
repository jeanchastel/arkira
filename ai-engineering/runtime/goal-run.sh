#!/usr/bin/env bash
set -uo pipefail

ARKIRA_GOAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/task-contract.sh
. "$ARKIRA_GOAL_DIR/task-contract.sh"
# shellcheck source=ai-engineering/runtime/harness-store.sh
. "$ARKIRA_GOAL_DIR/harness-store.sh"

arkira_goal_error() {
  printf 'goal: %s\n' "$*" >&2
  return 1
}

arkira_goal_state_dir() {
  local repo=$1 identity runtime directory
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  runtime="$(arkira_receipt_runtime_root)" || return 1
  directory="$runtime/goals/$identity"
  [[ ! -L "$runtime/goals" && ! -L "$directory" ]] || return 1
  printf '%s' "$directory"
}

arkira_goal_active_path() {
  printf '%s/active.json' "$(arkira_goal_state_dir "$1")"
}

arkira_goal_worktree_tree() {
  local repo=$1 index tree
  index="$(mktemp "${TMPDIR:-/tmp}/arkira-goal-index.XXXXXX")" || return 1
  rm -f -- "$index"
  if ! GIT_INDEX_FILE="$index" git -C "$repo" read-tree HEAD \
    || ! GIT_INDEX_FILE="$index" git -C "$repo" add -A -- . \
    || ! tree="$(GIT_INDEX_FILE="$index" git -C "$repo" write-tree)"; then
    rm -f -- "$index"
    return 1
  fi
  rm -f -- "$index"
  [[ "$tree" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]] || return 1
  printf '%s' "$tree"
}

arkira_goal_fingerprint() {
  local repo=$1 branch head tree
  branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || return 1
  tree="$(arkira_goal_worktree_tree "$repo")" || return 1
  printf '%s\0%s\0%s' "$branch" "$head" "$tree" | arkira_receipt_sha256
}

arkira_goal_dirty_paths() {
  local repo=$1 output=$2 path
  : > "$output" || return 1
  while IFS= read -r -d '' path; do
    arkira_validate_relative_path "$path" || return 1
    printf '%s\n' "$path" >> "$output" || return 1
  done < <(git -C "$repo" diff --name-only --no-renames -z HEAD)
  while IFS= read -r -d '' path; do
    arkira_validate_relative_path "$path" || return 1
    printf '%s\n' "$path" >> "$output" || return 1
  done < <(git -C "$repo" ls-files --others --exclude-standard -z)
  LC_ALL=C sort -u "$output" -o "$output" || return 1
}

arkira_goal_path_in_scope() {
  local path=$1 scope=$2 entry
  while IFS= read -r entry; do
    [[ "$path" == "$entry" || "$path" == "$entry"/* ]] && return 0
  done <<< "$scope"
  return 1
}

arkira_goal_validate_dirty() {
  local repo=$1 contract=$2 actual expected allowed path
  actual="$(mktemp "${TMPDIR:-/tmp}/arkira-goal-dirty.XXXXXX")" || return 1
  expected="$(mktemp "${TMPDIR:-/tmp}/arkira-goal-adopted.XXXXXX")" || { rm -f -- "$actual"; return 1; }
  arkira_goal_dirty_paths "$repo" "$actual" || { rm -f -- "$actual" "$expected"; return 1; }
  jq -r '.scope.adopted[]' "$contract" | LC_ALL=C sort -u > "$expected" || {
    rm -f -- "$actual" "$expected"; return 1;
  }
  if ! cmp -s "$actual" "$expected"; then
    rm -f -- "$actual" "$expected"
    arkira_goal_error 'dirty paths must match scope.adopted exactly'
    return 1
  fi
  allowed="$(jq -r '.scope.allowed[]' "$contract")"
  while IFS= read -r path; do
    [[ -z "$path" ]] || arkira_goal_path_in_scope "$path" "$allowed" || {
      rm -f -- "$actual" "$expected"
      arkira_goal_error "adopted path is outside allowed scope: $path"
      return 1
    }
  done < "$expected"
  rm -f -- "$actual" "$expected"
}

arkira_goal_validate_branch_delta() {
  local repo=$1 base=$2 contract=$3 current allowed adopted path
  current="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
    arkira_goal_error 'detached HEAD is not allowed'; return 1;
  }
  [[ "$current" != "$base" ]] || return 0
  case "$current" in main|master|release|production) arkira_goal_error "protected branch is not a goal branch: $current"; return 1 ;; esac
  git -C "$repo" rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || {
    arkira_goal_error "base branch does not resolve: $base"; return 1;
  }
  git -C "$repo" merge-base --is-ancestor "$base" HEAD >/dev/null 2>&1 || {
    arkira_goal_error 'goal branch is unrelated to its base'; return 1;
  }
  allowed="$(jq -r '.scope.allowed[]' "$contract")"
  adopted="$(jq -r '.scope.adopted[]' "$contract")"
  while IFS= read -r path; do
    case "$path" in docs/specs/*|docs/plans/*|reports/*) continue ;; esac
    arkira_goal_path_in_scope "$path" "$allowed" || arkira_goal_path_in_scope "$path" "$adopted" || {
      arkira_goal_error "base delta is outside goal scope: $path"
      return 1
    }
  done < <(git -C "$repo" diff --name-only --no-renames "$base"...HEAD)
}

arkira_goal_slug() {
  local value=$1 slug
  slug="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
  [[ -n "$slug" ]] || slug=goal
  printf '%s' "$slug"
}

arkira_goal_write_state() {
  local target=$1 document=$2 directory stage
  directory="$(dirname -- "$target")"
  [[ -d "$directory" && ! -L "$directory" && ! -L "$target" ]] || return 1
  stage="$(mktemp "$directory/.goal.XXXXXX")" || return 1
  printf '%s\n' "$document" > "$stage" || { rm -f -- "$stage"; return 1; }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
}

arkira_goal_prepare() {
  local repo=${1:-} contract=${2:-} plan=${3:-} base=${4:-main} requested_slug=${5:-}
  local root active branch digest prefix slug goal_id harness_root harness_digest contract_digest snapshot_meta
  local plan_path plan_digest identity head tree fingerprint now state
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    arkira_goal_error 'target is not a Git repository'; return 1;
  }
  root="$(cd -- "$root" && pwd -P)" || return 1
  [[ -f "$plan" && ! -L "$plan" ]] || { arkira_goal_error 'plan must be a regular file'; return 1; }
  arkira_task_contract_validate "$contract" || return 1
  active="$(arkira_goal_active_path "$root")" || return 1
  arkira_receipt_reject_symlink_components "$(dirname -- "$active")" || return 1
  mkdir -p -- "$(dirname -- "$active")/history" || return 1
  chmod 700 "$(dirname -- "$active")" "$(dirname -- "$active")/history" || return 1
  [[ ! -e "$active" && ! -L "$active" ]] || { arkira_goal_error 'an unfinished goal already exists'; return 1; }
  arkira_goal_validate_dirty "$root" "$contract" || return 1
  arkira_goal_validate_branch_delta "$root" "$base" "$contract" || return 1
  harness_root=${ARKIRA_HARNESS_ROOT:-"$(cd -- "$ARKIRA_GOAL_DIR/../.." && pwd -P)"}
  harness_digest="$(arkira_harness_capture "$harness_root" \
    "${ARKIRA_HARNESS_CHANNEL:-dev/unreleased}" "${ARKIRA_HARNESS_VERIFIED:-false}")" || return 1
  contract_digest="$(jq -r '.harness.content_digest' "$contract")"
  [[ "$harness_digest" == "$contract_digest" ]] || {
    arkira_goal_error 'contract harness content digest does not match the active snapshot'; return 1;
  }
  snapshot_meta="$(arkira_harness_store_root)/$harness_digest/.arkira-harness-meta.json"
  jq -e --arg digest "$harness_digest" --arg sha "$(jq -r '.harness.sha' "$contract")" \
    --arg version "$(jq -r '.harness.version' "$contract")" \
    --arg channel "$(jq -r '.harness.channel' "$contract")" '
      .content_digest == $digest and .source_sha == $sha and
      .version == $version and .channel == $channel
    ' "$snapshot_meta" >/dev/null 2>&1 || {
      arkira_goal_error 'contract harness identity does not match the active snapshot'; return 1;
    }
  digest="$(arkira_task_contract_digest "$contract")" || return 1
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  if [[ "$branch" == "$base" ]]; then
    slug="$(arkira_goal_slug "${requested_slug:-$(jq -r '.objective' "$contract")}")"
    prefix=${digest:0:8}
    branch="arkira/$slug-$prefix"
    git -C "$root" show-ref --verify --quiet "refs/heads/$branch" && {
      arkira_goal_error "goal branch already exists: $branch"; return 1;
    }
    git -C "$root" switch -q -c "$branch" || return 1
  fi
  contract_digest="$(arkira_task_contract_bind "$root" "$contract")" || return 1
  arkira_harness_bind "$root" "$harness_digest" || return 1
  identity="$(arkira_receipt_repo_identity "$root")" || return 1
  head="$(git -C "$root" rev-parse HEAD)" || return 1
  tree="$(arkira_goal_worktree_tree "$root")" || return 1
  fingerprint="$(arkira_goal_fingerprint "$root")" || return 1
  plan_path="$(realpath "$plan")" || return 1
  plan_digest="$(arkira_harness_sha256_file "$plan_path")" || return 1
  goal_id="goal-${digest:0:16}"
  now="$(date +%s)"
  state="$(jq -n --arg goal_id "$goal_id" --arg identity "$identity" --arg state prepared \
    --arg base "$base" --arg branch "$branch" --arg head "$head" --arg tree "$tree" \
    --arg fingerprint "$fingerprint" --arg contract_digest "$contract_digest" \
    --arg plan_path "$plan_path" --arg plan_digest "$plan_digest" \
    --arg harness_digest "$harness_digest" --arg harness_sha "$(jq -r '.harness.sha' "$contract")" \
    --arg harness_version "$(jq -r '.harness.version' "$contract")" \
    --arg harness_channel "$(jq -r '.harness.channel' "$contract")" --argjson now "$now" '
    {schema_version:1,goal_id:$goal_id,repo_identity:$identity,state:$state,base:$base,
      branch:$branch,head:$head,worktree_tree:$tree,fingerprint:$fingerprint,
      contract_digest:$contract_digest,plan:{path:$plan_path,digest:$plan_digest},
      harness:{content_digest:$harness_digest,sha:$harness_sha,version:$harness_version,
        channel:$harness_channel},created_epoch:$now,updated_epoch:$now}
  ')" || return 1
  arkira_goal_write_state "$active" "$state" || return 1
  printf '%s\n' "$state"
}

arkira_goal_read_active() {
  local repo=$1 active identity
  active="$(arkira_goal_active_path "$repo")" || return 1
  [[ -f "$active" && ! -L "$active" ]] || { arkira_goal_error 'no active goal'; return 1; }
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  jq -e --arg identity "$identity" '
    .schema_version == 1 and .repo_identity == $identity and
    (.state | IN("prepared","running","sealed")) and
    (.goal_id | type == "string" and length > 0) and
    (.fingerprint | type == "string" and test("^[a-f0-9]{64}$"))
  ' "$active" >/dev/null 2>&1 || { arkira_goal_error 'active goal state is malformed'; return 1; }
  cat "$active"
}

arkira_goal_status() {
  local repo=$1 state branch head tree fingerprint reason=none fresh=true
  state="$(arkira_goal_read_active "$repo")" || return 1
  branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  # Synthetic comparison objects live only in a disposable object directory.
  local objects canonical_objects
  objects="$(mktemp -d "${TMPDIR:-/tmp}/arkira-goal-status.XXXXXX")" || return 1
  canonical_objects="$(git -C "$repo" rev-parse --path-format=absolute --git-path objects)" || { rm -rf -- "$objects"; return 1; }
  tree="$(GIT_OBJECT_DIRECTORY="$objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$canonical_objects" \
    arkira_goal_worktree_tree "$repo" 2>/dev/null || true)"
  rm -rf -- "$objects"
  fingerprint="$(printf '%s\0%s\0%s' "$branch" "$head" "$tree" | arkira_receipt_sha256)"
  if [[ "$branch" != "$(jq -r '.branch' <<< "$state")" ]]; then fresh=false; reason=branch
  elif [[ "$head" != "$(jq -r '.head' <<< "$state")" ]]; then fresh=false; reason=head
  elif [[ "$fingerprint" != "$(jq -r '.fingerprint' <<< "$state")" ]]; then fresh=false; reason=worktree
  fi
  jq -c --argjson fresh "$fresh" --arg reason "$reason" --arg observed_branch "$branch" \
    --arg observed_head "$head" --arg observed_tree "$tree" \
    '. + {fresh:$fresh,freshness_reason:$reason,observed:{branch:$observed_branch,head:$observed_head,worktree_tree:$observed_tree}}' \
    <<< "$state"
}

arkira_goal_transition() {
  local repo=$1 from=$2 to=$3 active state now updated
  active="$(arkira_goal_active_path "$repo")" || return 1
  state="$(arkira_goal_read_active "$repo")" || return 1
  [[ "$(jq -r '.state' <<< "$state")" == "$from" ]] || {
    arkira_goal_error "goal state must be $from"; return 1;
  }
  jq -e '.fresh == true' <<< "$(arkira_goal_status "$repo")" >/dev/null || {
    arkira_goal_error 'goal facts are stale'; return 1;
  }
  now="$(date +%s)"
  updated="$(jq -c --arg state "$to" --argjson now "$now" '.state=$state | .updated_epoch=$now' <<< "$state")" || return 1
  arkira_goal_write_state "$active" "$updated" || return 1
  printf '%s\n' "$updated"
}

arkira_goal_start() { arkira_goal_transition "$1" prepared running; }

arkira_goal_seal() {
  local repo=$1 active state now updated branch head tree fingerprint plan_digest snapshot
  active="$(arkira_goal_active_path "$repo")" || return 1
  state="$(arkira_goal_read_active "$repo")" || return 1
  [[ "$(jq -r '.state' <<< "$state")" == running ]] || { arkira_goal_error 'goal state must be running'; return 1; }
  branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  [[ "$branch" == "$(jq -r '.branch' <<< "$state")" ]] || {
    arkira_goal_error 'goal branch moved before seal'; return 1;
  }
  plan_digest="$(arkira_harness_sha256_file "$(jq -r '.plan.path' <<< "$state")")" || return 1
  [[ "$plan_digest" == "$(jq -r '.plan.digest' <<< "$state")" ]] || {
    arkira_goal_error 'goal plan moved before seal'; return 1;
  }
  arkira_task_contract_load "$repo" "$(jq -r '.contract_digest' <<< "$state")" >/dev/null || return 1
  snapshot="$(arkira_harness_store_root)/$(jq -r '.harness.content_digest' <<< "$state")"
  arkira_harness_verify "$snapshot" || { arkira_goal_error 'goal harness snapshot failed verification'; return 1; }
  head="$(git -C "$repo" rev-parse HEAD)" || return 1
  tree="$(arkira_goal_worktree_tree "$repo")" || return 1
  fingerprint="$(arkira_goal_fingerprint "$repo")" || return 1
  now="$(date +%s)"
  updated="$(jq -c --arg head "$head" --arg tree "$tree" --arg fingerprint "$fingerprint" \
    --argjson now "$now" '
      .state="sealed" | .head=$head | .worktree_tree=$tree | .fingerprint=$fingerprint |
      .sealed_epoch=$now | .updated_epoch=$now
    ' <<< "$state")" || return 1
  arkira_goal_write_state "$active" "$updated" || return 1
  printf '%s\n' "$updated"
}

arkira_goal_terminate() {
  local repo=$1 active directory state now updated target
  active="$(arkira_goal_active_path "$repo")" || return 1
  directory="$(dirname -- "$active")"
  if [[ -f "$directory/delivery.json" ]]; then
    bash "$ARKIRA_GOAL_DIR/delivery-run.sh" "$repo" cancel-delivery >/dev/null || return 1
  fi
  state="$(arkira_goal_read_active "$repo")" || return 1
  now="$(date +%s)"
  updated="$(jq -c --argjson now "$now" '.state="terminated" | .updated_epoch=$now' <<< "$state")" || return 1
  target="$directory/history/$(jq -r '.goal_id' <<< "$state")-$now.json"
  arkira_goal_write_state "$target" "$updated" || return 1
  rm -f -- "$active" || return 1
  printf '%s\n' "$updated"
}

arkira_goal_usage() {
  printf 'usage: goal-run.sh <repo> prepare --contract FILE --plan FILE [--base BRANCH] [--slug SLUG] | start|status|seal|bind-delivery|delivery-status|watch|recover|cancel-delivery|schedule|terminate\n' >&2
  return 2
}

arkira_goal_main() {
  local repo=${1:-} command=${2:-} contract='' plan='' base=main slug=''
  [[ -n "$repo" && -n "$command" ]] || { arkira_goal_usage; return; }
  shift 2
  case "$command" in
    prepare)
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --contract) [[ "$#" -ge 2 ]] || { arkira_goal_usage; return; }; contract=$2; shift 2 ;;
          --plan) [[ "$#" -ge 2 ]] || { arkira_goal_usage; return; }; plan=$2; shift 2 ;;
          --base) [[ "$#" -ge 2 ]] || { arkira_goal_usage; return; }; base=$2; shift 2 ;;
          --slug) [[ "$#" -ge 2 ]] || { arkira_goal_usage; return; }; slug=$2; shift 2 ;;
          *) arkira_goal_usage; return ;;
        esac
      done
      [[ -n "$contract" && -n "$plan" ]] || { arkira_goal_usage; return; }
      arkira_goal_prepare "$repo" "$contract" "$plan" "$base" "$slug"
      ;;
    start) [[ "$#" -eq 0 ]] || { arkira_goal_usage; return; }; arkira_goal_start "$repo" ;;
    status) [[ "$#" -eq 0 ]] || { arkira_goal_usage; return; }; arkira_goal_status "$repo" ;;
    bind-delivery|delivery-status|watch|recover|cancel-delivery|schedule)
      [[ -f "$ARKIRA_GOAL_DIR/delivery-run.sh" ]] || {
        arkira_goal_error 'delivery commands require the installed plugin entry point: bin/arkira goal <repo>'; return 1;
      }
      bash "$ARKIRA_GOAL_DIR/delivery-run.sh" "$repo" "$command" "$@" ;;
    terminate) [[ "$#" -eq 0 ]] || { arkira_goal_usage; return; }; arkira_goal_terminate "$repo" ;;
    seal) [[ "$#" -eq 0 ]] || { arkira_goal_usage; return; }; arkira_goal_seal "$repo" ;;
    *) arkira_goal_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_goal_main "$@"; fi
