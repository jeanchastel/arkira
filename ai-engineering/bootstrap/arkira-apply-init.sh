#!/usr/bin/env bash
# Non-interactive Arkira init composition for approved, complete decisions.
# Reads the same decisions JSON as arkira-write-config.sh from stdin.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$(cd -- "$script_dir/../.." && pwd -P)"
# shellcheck source=ai-engineering/bootstrap/lib/file-safety.sh
. "$script_dir/lib/file-safety.sh"
repo_root=""
mode=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      [ "$#" -ge 2 ] || { printf 'missing value for --repo-root\n' >&2; exit 2; }
      repo_root="$2"
      shift 2
      ;;
    --dry-run) mode="dry-run"; shift ;;
    --apply) mode="apply"; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$repo_root" ] || { printf 'must pass --repo-root\n' >&2; exit 2; }
[ -n "$mode" ] || { printf 'must pass --dry-run or --apply\n' >&2; exit 2; }
repo_root="$(cd -P -- "$repo_root" 2>/dev/null && pwd -P)" \
  || { printf 'repo root is not a readable directory\n' >&2; exit 2; }
git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" \
  || { printf 'repo root is not a git repository\n' >&2; exit 2; }
git_root="$(cd -P -- "$git_root" 2>/dev/null && pwd -P)" \
  || { printf 'git root is unreadable\n' >&2; exit 2; }
[ "$git_root" = "$repo_root" ] \
  || { printf 'repo root must be the Git toplevel\n' >&2; exit 2; }

decisions="$(cat)"
printf '%s' "$decisions" | jq -e '.switches | type == "object"' >/dev/null 2>&1 \
  || { printf 'decisions JSON is invalid or missing switches\n' >&2; exit 1; }

run_writer() {
  local writer_mode="$1"
  printf '%s' "$decisions" | \
    ARKIRA_INIT_HOME="${init_home:-${ARKIRA_INIT_HOME:-$HOME}}" \
    ARKIRA_INIT_PLUGIN_ROOT="$plugin_root" \
    bash "$script_dir/arkira-write-config.sh" --repo-root "$repo_root" "--$writer_mode"
}

if [ "$mode" = "dry-run" ]; then
  run_writer dry-run
  exit 0
fi

# Preflight the configuration plan before any target mutation.
init_home="$(arkira_safe_root "${ARKIRA_INIT_HOME:-$HOME}")" \
  || { printf 'ARKIRA_INIT_HOME must be a regular, non-symlink directory\n' >&2; exit 2; }
run_writer dry-run >/dev/null

settings_override="${ARKIRA_INIT_SETTINGS:-}"
if [[ -n "$settings_override" ]]; then
  case "$settings_override" in
    /*) settings_abs="$settings_override" ;;
    *) settings_abs="$init_home/$settings_override" ;;
  esac
else
  settings_abs="$init_home/.claude/settings.json"
fi
case "$settings_abs" in
  "$init_home"/*) settings_rel=${settings_abs#"$init_home"/} ;;
  *) printf 'settings path must stay within ARKIRA_INIT_HOME\n' >&2; exit 2 ;;
esac

git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null)" \
  || { printf 'cannot resolve repository Git directory\n' >&2; exit 2; }
git_dir="$(arkira_safe_root "$git_dir")" \
  || { printf 'repository Git directory is unsafe\n' >&2; exit 2; }

transaction_dir="$(mktemp -d "${TMPDIR:-/tmp}/arkira-init-transaction.XXXXXX")"
chmod 700 "$transaction_dir"
transaction_dir="$(cd -P -- "$transaction_dir" && pwd -P)"
transaction_active=0
transaction_rollback_done=0
declare -a TX_ROOTS=("")
declare -a TX_RELS=("")
declare -a TX_EXISTED=(0)
declare -a TX_BACKUPS=("")
declare -a TX_CLAIM_RELS=("")
declare -a TX_CLAIM_IDENTITIES=("")
declare -a TX_PUBLISHED_IDENTITIES=("")
declare -a TX_PUBLISHED_SOURCES=("")
declare -a TX_ATTEMPTED=(0)
declare -a TX_CREATED_ROOTS=("")
declare -a TX_CREATED_RELS=("")
TX_CREATED_KEYS=""
declare -a INIT_LOCK_ROOTS=("")
declare -a INIT_LOCK_RELS=("")
declare -a INIT_LOCK_IDENTITIES=("")
INIT_LOCK_KEYS=""

cleanup_init_transaction() {
  local i lock_target
  for ((i=${#INIT_LOCK_RELS[@]}-1; i>=1; i--)); do
    lock_target="$(arkira_safe_target "${INIT_LOCK_ROOTS[$i]}" \
      "${INIT_LOCK_RELS[$i]}" 2>/dev/null || true)"
    if [[ -n "$lock_target" && -d "$lock_target" && ! -L "$lock_target" \
      && "$(arkira_stat_identity "$lock_target" 2>/dev/null || true)" \
        == "${INIT_LOCK_IDENTITIES[$i]}" ]]; then
      arkira_safe_rmdir "${INIT_LOCK_ROOTS[$i]}" "${INIT_LOCK_RELS[$i]}" \
        || printf 'WARNING: could not remove owned init lock: %s\n' \
          "$lock_target" >&2
    else
      printf 'WARNING: owned init lock name changed; refusing to remove it\n' >&2
    fi
  done
  INIT_LOCK_RELS=("")
  [[ -z "${transaction_dir:-}" ]] || rm -rf -- "$transaction_dir"
  transaction_dir=""
}

acquire_init_lock() {
  local root=$1 rel=$2 key identity
  key="$root"$'\037'"$rel"
  printf '%s' "$INIT_LOCK_KEYS" | grep -Fxq -- "$key" && return 0
  arkira_safe_mkdir_new "$root" "$rel" || {
    printf 'another Arkira init transaction owns lock: %s/%s\n' \
      "$root" "$rel" >&2
    return 1
  }
  identity="$(arkira_stat_identity "$root/$rel")" || return 1
  INIT_LOCK_ROOTS+=("$root")
  INIT_LOCK_RELS+=("$rel")
  INIT_LOCK_IDENTITIES+=("$identity")
  INIT_LOCK_KEYS+="$key"$'\n'
}

record_missing_parents() {
  local root=$1 rel=$2 parent current="" part key
  parent="$(dirname -- "$rel")"
  [[ "$parent" != "." ]] || return 0
  IFS='/' read -r -a init_parent_parts <<<"$parent"
  for part in "${init_parent_parts[@]}"; do
    current="${current:+$current/}$part"
    if [[ -e "$root/$current" || -L "$root/$current" ]]; then
      arkira_safe_target "$root" "$current" >/dev/null
      [[ -d "$root/$current" && ! -L "$root/$current" ]]
    else
      key="$root"$'\037'"$current"
      if ! printf '%s' "$TX_CREATED_KEYS" | grep -Fxq -- "$key"; then
        TX_CREATED_ROOTS+=("$root")
        TX_CREATED_RELS+=("$current")
        TX_CREATED_KEYS+="$key"$'\n'
      fi
    fi
  done
}

snapshot_file_target() {
  local root=$1 rel=$2 label=$3 target backup mode index
  target="$(arkira_safe_target "$root" "$rel")" \
    || { printf 'unsafe %s path: %s\n' "$label" "$rel" >&2; return 1; }
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] \
      || { printf '%s target must be a regular non-symlink file: %s\n' "$label" "$target" >&2; return 1; }
  fi
  record_missing_parents "$root" "$rel"
  index=${#TX_RELS[@]}
  backup="$transaction_dir/file.$index.before"
  if [[ -f "$target" ]]; then
    arkira_safe_read "$root" "$rel" > "$backup"
    mode="$(arkira_safe_file_mode "$root" "$rel")"
    chmod "$mode" "$backup"
    TX_EXISTED+=(1)
  else
    : > "$backup"
    TX_EXISTED+=(0)
  fi
  TX_ROOTS+=("$root")
  TX_RELS+=("$rel")
  TX_BACKUPS+=("$backup")
  TX_CLAIM_RELS+=("")
  TX_CLAIM_IDENTITIES+=("")
  TX_PUBLISHED_IDENTITIES+=("")
  TX_PUBLISHED_SOURCES+=("")
  TX_ATTEMPTED+=(0)
}

ensure_tx_parent() {
  local root=$1 rel=$2 parent
  parent="$(dirname -- "$rel")"
  [[ "$parent" == "." ]] || arkira_safe_mkdir "$root" "$parent"
}

tx_file_matches_snapshot() {
  local root=$1 rel=$2 snapshot=$3 target compare mode expected_mode matches=1
  target="$(arkira_safe_target "$root" "$rel")" || return 1
  [[ -f "$target" && ! -L "$target" && -f "$snapshot" && ! -L "$snapshot" ]] \
    || return 1
  compare="$(mktemp "$transaction_dir/compare.XXXXXX")" || return 1
  if ! arkira_safe_read "$root" "$rel" > "$compare"; then
    rm -f -- "$compare"
    return 1
  fi
  mode="$(arkira_safe_file_mode "$root" "$rel")" || matches=0
  expected_mode="$(if stat -f '%Lp' -- "$snapshot" >/dev/null 2>&1; then
    stat -f '%Lp' -- "$snapshot"
  else
    stat -c '%a' -- "$snapshot"
  fi)" || matches=0
  cmp -s "$compare" "$snapshot" || matches=0
  rm -f -- "$compare"
  [[ "$matches" -eq 1 && "$mode" == "$expected_mode" ]]
}

find_tx_index() {
  local root=$1 rel=$2 i
  for ((i=1; i<${#TX_RELS[@]}; i++)); do
    if [[ "${TX_ROOTS[$i]}" == "$root" && "${TX_RELS[$i]}" == "$rel" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

publish_tx_file() {
  local root=$1 rel=$2 source=$3 index target claim identity
  index="$(find_tx_index "$root" "$rel")" || {
    printf 'transaction target was not snapshotted: %s\n' "$rel" >&2
    return 1
  }
  TX_ATTEMPTED[$index]=1
  ensure_tx_parent "$root" "$rel"
  if [[ "${ARKIRA_APPLY_INIT_TEST_MUTATE_AFTER_SNAPSHOT_REL:-}" == "$rel" ]]; then
    printf '\nconcurrent init edit\n' >> "$root/$rel"
    unset ARKIRA_APPLY_INIT_TEST_MUTATE_AFTER_SNAPSHOT_REL
  fi
  if [[ "${TX_EXISTED[$index]}" -eq 1 ]]; then
    claim="$(arkira_claim_regular_file "$root" "$rel" \
      ".arkira-init-original")" || return 1
    TX_CLAIM_RELS[$index]="$claim"
    identity="$(arkira_stat_identity "$root/$claim")" || return 1
    TX_CLAIM_IDENTITIES[$index]="$identity"
    tx_file_matches_snapshot "$root" "$claim" "${TX_BACKUPS[$index]}" \
      || return 1
  else
    target="$(arkira_safe_target "$root" "$rel")" || return 1
    [[ ! -e "$target" && ! -L "$target" ]] || return 1
  fi
  TX_PUBLISHED_SOURCES[$index]="$source"
  TX_PUBLISHED_IDENTITIES[$index]="$(
    arkira_atomic_copy_new_with_identity "$root" "$rel" "$source"
  )" || return 1
}

rollback_init_transaction() {
  local i rollback_failed=0 target created_target current_claim current_identity
  [[ "$transaction_rollback_done" -eq 0 ]] || return 0
  transaction_rollback_done=1

  for ((i=${#TX_RELS[@]}-1; i>=1; i--)); do
    [[ "${TX_ATTEMPTED[$i]}" -eq 1 ]] || continue
    current_claim=""
    if [[ -n "${TX_PUBLISHED_IDENTITIES[$i]}" ]]; then
      current_claim="$(arkira_claim_regular_file "${TX_ROOTS[$i]}" \
        "${TX_RELS[$i]}" ".arkira-init-rollback" 2>/dev/null || true)"
    fi
    if [[ -n "$current_claim" ]]; then
      current_identity="$(arkira_stat_identity \
        "${TX_ROOTS[$i]}/$current_claim" 2>/dev/null || true)"
      if [[ "$current_identity" != "${TX_PUBLISHED_IDENTITIES[$i]}" ]] \
        || ! tx_file_matches_snapshot "${TX_ROOTS[$i]}" "$current_claim" \
          "${TX_PUBLISHED_SOURCES[$i]}"; then
        arkira_restore_claim_new "${TX_ROOTS[$i]}" "$current_claim" \
          "${TX_RELS[$i]}" || rollback_failed=1
        printf 'ERROR: init rollback preserved a concurrently changed target: %s\n' \
          "${TX_RELS[$i]}" >&2
        rollback_failed=1
        continue
      fi
      if [[ "${TX_EXISTED[$i]}" -eq 1 ]]; then
        if ! arkira_restore_claim_new "${TX_ROOTS[$i]}" \
          "${TX_CLAIM_RELS[$i]}" "${TX_RELS[$i]}"; then
          arkira_restore_claim_new "${TX_ROOTS[$i]}" "$current_claim" \
            "${TX_RELS[$i]}" || rollback_failed=1
          rollback_failed=1
          continue
        fi
      fi
      arkira_safe_remove_file "${TX_ROOTS[$i]}" "$current_claim" \
        || rollback_failed=1
      continue
    fi

    target="$(arkira_safe_target "${TX_ROOTS[$i]}" "${TX_RELS[$i]}" \
      2>/dev/null || true)"
    if [[ -n "${TX_CLAIM_RELS[$i]}" && -n "$target" \
      && ! -e "$target" && ! -L "$target" ]]; then
      arkira_restore_claim_new "${TX_ROOTS[$i]}" "${TX_CLAIM_RELS[$i]}" \
        "${TX_RELS[$i]}" || rollback_failed=1
    elif [[ -n "${TX_PUBLISHED_IDENTITIES[$i]}" \
      || -n "${TX_CLAIM_RELS[$i]}" ]]; then
      printf 'ERROR: init rollback retained a recovery claim for: %s\n' \
        "${TX_RELS[$i]}" >&2
      rollback_failed=1
    fi
  done
  for ((i=${#TX_CREATED_RELS[@]}-1; i>=1; i--)); do
    created_target="$(arkira_safe_target "${TX_CREATED_ROOTS[$i]}" \
      "${TX_CREATED_RELS[$i]}")" || { rollback_failed=1; continue; }
    if [[ -e "$created_target" || -L "$created_target" ]]; then
      arkira_safe_rmdir "${TX_CREATED_ROOTS[$i]}" "${TX_CREATED_RELS[$i]}" \
        || rollback_failed=1
    fi
  done
  return "$rollback_failed"
}

init_transaction_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ "$transaction_active" -eq 1 ]]; then
    rollback_init_transaction || printf 'ERROR: Arkira init rollback was incomplete\n' >&2
  fi
  cleanup_init_transaction
  exit "$rc"
}

init_transaction_signal() {
  local signal=$1
  trap - EXIT HUP INT TERM
  if [[ "$transaction_active" -eq 1 ]]; then
    rollback_init_transaction || printf 'ERROR: Arkira init rollback was incomplete\n' >&2
  fi
  cleanup_init_transaction
  kill -s "$signal" "$$"
  exit 1
}

trap init_transaction_exit EXIT
trap 'init_transaction_signal HUP' HUP
trap 'init_transaction_signal INT' INT
trap 'init_transaction_signal TERM' TERM

acquire_init_lock "$init_home" ".arkira-init.lock"
acquire_init_lock "$git_dir" "arkira-init.lock"

# Snapshot every real file that the writer may touch.
snapshot_file_target "$init_home" "$settings_rel" "user settings"
snapshot_file_target "$init_home" ".arkira/config.json" "user config"
snapshot_file_target "$repo_root" ".arkira/config.json" "repo config"

transaction_active=1

seed_tx_snapshot() {
  local source_root=$1 rel=$2 destination_root=$3 index destination
  index="$(find_tx_index "$source_root" "$rel")" || return 1
  [[ "${TX_EXISTED[$index]}" -eq 1 ]] || return 0
  destination="$destination_root/$rel"
  mkdir -p -- "$(dirname -- "$destination")"
  cp -p -- "${TX_BACKUPS[$index]}" "$destination"
}

config_home="$transaction_dir/config-home"
config_repo="$transaction_dir/config-repo"
mkdir -m 700 "$config_home" "$config_repo"
seed_tx_snapshot "$init_home" "$settings_rel" "$config_home"
seed_tx_snapshot "$init_home" ".arkira/config.json" "$config_home"
seed_tx_snapshot "$repo_root" ".arkira/config.json" "$config_repo"
printf '%s' "$decisions" | \
  ARKIRA_INIT_HOME="$config_home" \
  ARKIRA_INIT_SETTINGS="$settings_rel" \
  ARKIRA_INIT_PLUGIN_ROOT="$plugin_root" \
  ARKIRA_INIT_DISABLE_RETAINED_BACKUP=1 \
  bash "$script_dir/arkira-write-config.sh" --repo-root "$config_repo" --apply \
  >/dev/null

# Configuration outputs publish only after their complete private staging runs succeed.
publish_tx_file "$init_home" "$settings_rel" "$config_home/$settings_rel"
publish_tx_file "$init_home" ".arkira/config.json" \
  "$config_home/.arkira/config.json"
publish_tx_file "$repo_root" ".arkira/config.json" \
  "$config_repo/.arkira/config.json"

if [[ -n "${ARKIRA_APPLY_INIT_FAIL_AFTER_SIDE_EFFECTS:-}" ]]; then
  printf 'ERROR: injected failure after init side-effect publication\n' >&2
  false
fi

transaction_active=0
trap - EXIT HUP INT TERM
for ((claim_index=1; claim_index<${#TX_CLAIM_RELS[@]}; claim_index++)); do
  claim_rel=${TX_CLAIM_RELS[$claim_index]}
  [[ -n "$claim_rel" ]] || continue
  if [[ "$(arkira_stat_identity \
      "${TX_ROOTS[$claim_index]}/$claim_rel" 2>/dev/null || true)" \
      == "${TX_CLAIM_IDENTITIES[$claim_index]}" ]] \
    && tx_file_matches_snapshot "${TX_ROOTS[$claim_index]}" "$claim_rel" \
      "${TX_BACKUPS[$claim_index]}"; then
    arkira_safe_remove_file "${TX_ROOTS[$claim_index]}" "$claim_rel" \
      || printf 'WARNING: committed init left recovery claim: %s\n' \
        "$claim_rel" >&2
  else
    printf 'WARNING: committed init retained concurrently changed original at: %s\n' \
      "$claim_rel" >&2
  fi
done
cleanup_init_transaction
printf 'Arkira configuration and init side effects applied to %s.\n' "$repo_root"
