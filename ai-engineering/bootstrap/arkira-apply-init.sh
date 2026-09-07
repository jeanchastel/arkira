#!/usr/bin/env bash
# Non-interactive Arkira init composition for approved, complete decisions.
# Reads the same decisions JSON as arkira-write-config.sh from stdin, then runs
# the graph side effect owned by /arkira-init.
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

switch_on() {
  printf '%s' "$decisions" | jq -e --arg id "$1" '.switches[$id] == true' >/dev/null 2>&1
}

run_writer() {
  local writer_mode="$1"
  printf '%s' "$decisions" | \
    ARKIRA_INIT_HOME="${init_home:-${ARKIRA_INIT_HOME:-$HOME}}" \
    ARKIRA_INIT_PLUGIN_ROOT="$plugin_root" \
    bash "$script_dir/arkira-write-config.sh" --repo-root "$repo_root" "--$writer_mode"
}

if [ "$mode" = "dry-run" ]; then
  run_writer dry-run
  switch_on knowledge_graph && printf 'WOULD PROVISION knowledge graph for %s\n' "$repo_root"
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

graph_target=""
graph_registry_root=""
graph_cli_available=0
graph_had_existing=0
if switch_on knowledge_graph && command -v code-review-graph >/dev/null 2>&1; then
  graph_cli_available=1
  graph_target="$(arkira_safe_target "$repo_root" ".code-review-graph")" \
    || { printf 'knowledge graph target is unsafe\n' >&2; exit 1; }
  if [[ -e "$graph_target" || -L "$graph_target" ]]; then
    [[ -d "$graph_target" && ! -L "$graph_target" ]] \
      || { printf 'knowledge graph target must be a regular non-symlink directory\n' >&2; exit 1; }
    graph_had_existing=1
  fi
  graph_registry_root="$(node -e 'process.stdout.write(require("os").homedir())')" \
    || { printf 'cannot resolve code-review-graph registry root\n' >&2; exit 1; }
  graph_registry_root="$(arkira_safe_root "$graph_registry_root")" \
    || { printf 'code-review-graph registry root is unsafe\n' >&2; exit 1; }
fi

transaction_dir="$(mktemp -d "${TMPDIR:-/tmp}/arkira-init-transaction.XXXXXX")"
chmod 700 "$transaction_dir"
transaction_dir="$(cd -P -- "$transaction_dir" && pwd -P)"
transaction_active=0
transaction_rollback_done=0
graph_backup_rel=""
graph_backup_owned=0
graph_published=0
graph_published_identity=""
graph_published_fingerprint=""
graph_backup_fingerprint=""
graph_backup_identity=""
graph_original_fingerprint=""
graph_original_identity=""
graph_stage_rel=""
graph_stage_owned=0
graph_stage_identity=""
graph_stage_fingerprint=""
graph_registry_cli_active=0
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

_arkira_init_reserve_name_bound() {
  local _anchor=$1 prefix=$2 name
  name="$(mktemp -d "${prefix}.XXXXXX")" || return 1
  rmdir -- "$name" || return 1
  printf '%s' "$name"
}

_arkira_init_remove_tree_bound() {
  local base=$1
  if [[ ! -e "$base" && ! -L "$base" ]]; then
    return 0
  fi
  node -e '
const fs = require("fs");
const path = process.argv[1];
const stat = fs.lstatSync(path);
if (stat.isSymbolicLink()) fs.unlinkSync(path);
else if (stat.isDirectory()) fs.rmSync(path, {recursive:true, force:false});
else process.exit(1);
' "$base"
}

remove_owned_tree() {
  local root=$1 rel=$2
  arkira_with_bound_parent_allow_final_link "$root" "$rel" \
    _arkira_init_remove_tree_bound
}

_arkira_init_rename_bound() {
  local destination=$1 source=$2
  [[ -e "$source" || -L "$source" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  node -e 'require("fs").renameSync(process.argv[1], process.argv[2])' \
    "$source" "$destination"
}

rename_owned_entry() {
  local root=$1 source_rel=$2 destination_rel=$3
  [[ "$(dirname -- "$source_rel")" == "$(dirname -- "$destination_rel")" ]] || return 1
  arkira_with_bound_parent_allow_final_link "$root" "$destination_rel" \
    _arkira_init_rename_bound "$(basename -- "$source_rel")"
}

graph_tree_fingerprint() {
  local path=$1
  node - "$path" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const hash = crypto.createHash("sha256");
function walk(current, rel) {
  const stat = fs.lstatSync(current);
  if (stat.isSymbolicLink()) throw new Error("symlink in graph tree");
  hash.update(`${rel}\0${stat.mode & 0o777}\0`);
  if (stat.isDirectory()) {
    for (const name of fs.readdirSync(current).sort()) {
      walk(path.join(current, name), rel ? `${rel}/${name}` : name);
    }
  } else if (stat.isFile()) {
    hash.update(fs.readFileSync(current));
  } else {
    throw new Error("unsupported graph entry");
  }
}
walk(root, "");
process.stdout.write(hash.digest("hex"));
NODE
}

_arkira_init_copy_tree_bound() {
  local _anchor=$1 source=$2
  cp -R -- "$source/." .
}

_arkira_init_private_dir_bound() {
  local _anchor=$1
  chmod 700 .
}

restore_graph_registry_after_cli() {
  local capture=${1:-} index claim target mode restored
  [[ -n "$graph_registry_root" ]] || return 0
  [[ -n "$capture" ]] || capture="$transaction_dir/graph-registry.cli-result"
  index="$(find_tx_index "$graph_registry_root" \
    ".code-review-graph/registry.json")" || return 1
  claim="$(arkira_claim_regular_file "$graph_registry_root" \
    ".code-review-graph/registry.json" ".arkira-graph-registry-result" \
    2>/dev/null || true)"
  if [[ -n "$claim" ]]; then
    if [[ -n "$capture" ]]; then
      arkira_safe_read "$graph_registry_root" "$claim" > "$capture" || return 1
      mode="$(arkira_safe_file_mode "$graph_registry_root" "$claim")" || return 1
      chmod "$mode" "$capture"
    fi
  elif [[ -n "$capture" ]]; then
    return 1
  fi

  target="$(arkira_safe_target "$graph_registry_root" \
    ".code-review-graph/registry.json")" || return 1
  [[ ! -e "$target" && ! -L "$target" ]] || return 1
  if [[ -z "$claim" ]]; then
    [[ "${TX_EXISTED[$index]}" -eq 0 ]] && return 0
    return 1
  fi

  # Revert only this invocation's uniquely identified temporary data-dir entry.
  # Unrelated entries written while the graph CLI ran remain in the restored
  # registry. A concurrent writer that replaces this repo's exact temporary
  # claim causes a hard failure rather than being mistaken for our result.
  restored="$transaction_dir/graph-registry.restored"
  if ! node - "$capture" "${TX_BACKUPS[$index]}" \
    "${TX_EXISTED[$index]}" "$repo_root" "$graph_build_stage" \
    > "$restored" <<'NODE'
const fs = require("fs");
const [currentFile, initialFile, existed, repo, temporaryData] = process.argv.slice(2);
const current = JSON.parse(fs.readFileSync(currentFile, "utf8"));
const initial = existed === "1"
  ? JSON.parse(fs.readFileSync(initialFile, "utf8"))
  : {repos: []};
if (!Array.isArray(current.repos) || !Array.isArray(initial.repos)) process.exit(1);
const matches = current.repos.filter((entry) => entry && entry.path === repo);
if (matches.length > 1) process.exit(1);
if (matches.length === 1 && matches[0].data_dir !== temporaryData) process.exit(1);
const prior = initial.repos.find((entry) => entry && entry.path === repo);
current.repos = current.repos.filter((entry) => !entry || entry.path !== repo);
if (prior) current.repos.push(prior);
process.stdout.write(`${JSON.stringify(current, null, 2)}\n`);
NODE
  then
    arkira_restore_claim_new "$graph_registry_root" "$claim" \
      ".code-review-graph/registry.json" || true
    return 1
  fi
  chmod "$mode" "$restored"
  ensure_tx_parent "$graph_registry_root" ".code-review-graph/registry.json"
  if ! arkira_atomic_copy_new "$graph_registry_root" \
    ".code-review-graph/registry.json" "$restored"; then
    arkira_restore_claim_new "$graph_registry_root" "$claim" \
      ".code-review-graph/registry.json" || true
    return 1
  fi
  arkira_safe_remove_file "$graph_registry_root" "$claim"
}

publish_graph_registry_entry() {
  local source=$1 index target claim identity mode rendered
  index="$(find_tx_index "$graph_registry_root" \
    ".code-review-graph/registry.json")" || return 1
  TX_ATTEMPTED[$index]=1
  ensure_tx_parent "$graph_registry_root" ".code-review-graph/registry.json"
  target="$(arkira_safe_target "$graph_registry_root" \
    ".code-review-graph/registry.json")" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    claim="$(arkira_claim_regular_file "$graph_registry_root" \
      ".code-review-graph/registry.json" ".arkira-init-original")" \
      || return 1
    TX_CLAIM_RELS[$index]="$claim"
    identity="$(arkira_stat_identity "$graph_registry_root/$claim")" \
      || return 1
    TX_CLAIM_IDENTITIES[$index]="$identity"
    arkira_safe_read "$graph_registry_root" "$claim" \
      > "${TX_BACKUPS[$index]}" || return 1
    mode="$(arkira_safe_file_mode "$graph_registry_root" "$claim")" \
      || return 1
    chmod "$mode" "${TX_BACKUPS[$index]}"
    TX_EXISTED[$index]=1
  else
    printf '%s\n' '{"repos":[]}' > "${TX_BACKUPS[$index]}"
    chmod 600 "${TX_BACKUPS[$index]}"
    TX_EXISTED[$index]=0
    mode=600
  fi
  rendered="$transaction_dir/graph-registry.publish"
  node - "${TX_BACKUPS[$index]}" "$source" "$repo_root" > "$rendered" <<'NODE'
const fs = require("fs");
const [latestFile, desiredFile, repo] = process.argv.slice(2);
const latest = JSON.parse(fs.readFileSync(latestFile, "utf8"));
const desired = JSON.parse(fs.readFileSync(desiredFile, "utf8"));
if (!Array.isArray(latest.repos) || !Array.isArray(desired.repos)) process.exit(1);
const matches = desired.repos.filter((entry) => entry && entry.path === repo);
if (matches.length !== 1) process.exit(1);
latest.repos = latest.repos.filter((entry) => !entry || entry.path !== repo);
latest.repos.push(matches[0]);
process.stdout.write(`${JSON.stringify(latest, null, 2)}\n`);
NODE
  chmod "$mode" "$rendered"
  TX_PUBLISHED_SOURCES[$index]="$rendered"
  TX_PUBLISHED_IDENTITIES[$index]="$(arkira_atomic_copy_new_with_identity \
    "$graph_registry_root" ".code-review-graph/registry.json" "$rendered")" \
    || return 1
}

rollback_init_transaction() {
  local i rollback_failed=0 target created_target current_claim current_identity
  local graph_rollback_rel graph_current_identity graph_current_fingerprint
  [[ "$transaction_rollback_done" -eq 0 ]] || return 0
  transaction_rollback_done=1

  if [[ "$graph_registry_cli_active" -eq 1 ]]; then
    restore_graph_registry_after_cli "" || rollback_failed=1
    graph_registry_cli_active=0
  fi

  if [[ "$graph_published" -eq 1 ]]; then
    graph_rollback_rel="$(arkira_with_bound_parent "$repo_root" \
      ".arkira-graph-rollback-anchor" _arkira_init_reserve_name_bound \
      ".arkira-graph-rollback" 2>/dev/null || true)"
    if [[ -n "$graph_rollback_rel" ]] \
      && rename_owned_entry "$repo_root" ".code-review-graph" \
        "$graph_rollback_rel"; then
      graph_current_identity="$(arkira_stat_identity \
        "$repo_root/$graph_rollback_rel" 2>/dev/null || true)"
      graph_current_fingerprint="$(graph_tree_fingerprint \
        "$repo_root/$graph_rollback_rel" 2>/dev/null || true)"
      if [[ "$graph_current_identity" == "$graph_published_identity" \
        && "$graph_current_fingerprint" == "$graph_published_fingerprint" ]]; then
        if [[ "$graph_backup_owned" -eq 1 && -n "$graph_backup_rel" ]]; then
          rename_owned_entry "$repo_root" "$graph_backup_rel" \
            ".code-review-graph" || rollback_failed=1
        fi
        remove_owned_tree "$repo_root" "$graph_rollback_rel" \
          || rollback_failed=1
      else
        rename_owned_entry "$repo_root" "$graph_rollback_rel" \
          ".code-review-graph" || rollback_failed=1
        printf 'ERROR: init rollback preserved a concurrently changed graph\n' >&2
        rollback_failed=1
      fi
    else
      rollback_failed=1
    fi
  elif [[ "$graph_backup_owned" -eq 1 && -n "$graph_backup_rel" ]]; then
    rename_owned_entry "$repo_root" "$graph_backup_rel" ".code-review-graph" \
      || rollback_failed=1
  fi
  if [[ "$graph_stage_owned" -eq 1 && -n "$graph_stage_rel" ]]; then
    if [[ -n "$graph_stage_identity" && -n "$graph_stage_fingerprint" \
      && "$(arkira_stat_identity "$repo_root/$graph_stage_rel" \
        2>/dev/null || true)" == "$graph_stage_identity" \
      && "$(graph_tree_fingerprint "$repo_root/$graph_stage_rel" \
        2>/dev/null || true)" == "$graph_stage_fingerprint" ]]; then
      remove_owned_tree "$repo_root" "$graph_stage_rel" || rollback_failed=1
    else
      printf 'ERROR: init rollback retained a changed graph stage: %s\n' \
        "$graph_stage_rel" >&2
      rollback_failed=1
    fi
  fi

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
if [[ -n "$graph_registry_root" ]]; then
  acquire_init_lock "$graph_registry_root" ".arkira-init.lock"
fi
acquire_init_lock "$git_dir" "arkira-init.lock"
if [[ "$graph_had_existing" -eq 1 ]]; then
  graph_original_identity="$(arkira_stat_identity "$graph_target")" \
    || { printf 'cannot bind existing knowledge graph\n' >&2; exit 1; }
  graph_original_fingerprint="$(graph_tree_fingerprint "$graph_target")" \
    || { printf 'existing graph contains unsafe entries\n' >&2; exit 1; }
fi

# Snapshot every real file that the writer may touch.
snapshot_file_target "$init_home" "$settings_rel" "user settings"
snapshot_file_target "$init_home" ".arkira/config.json" "user config"
snapshot_file_target "$repo_root" ".arkira/config.json" "repo config"
for legacy_rel in .code-review-graph.db .code-review-graph.db-wal \
  .code-review-graph.db-shm .code-review-graph.db-journal; do
  snapshot_file_target "$repo_root" "$legacy_rel" "legacy graph state"
done

if [[ "$graph_cli_available" -eq 1 ]]; then
  snapshot_file_target "$graph_registry_root" \
    ".code-review-graph/registry.json" "code-review-graph registry"
fi

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

graph_registry_after=""
if [[ "$graph_cli_available" -eq 1 ]]; then
    graph_build_stage="$transaction_dir/graph-build"
    mkdir -m 700 "$graph_build_stage"
    graph_registry_after="$transaction_dir/graph-registry.after"
    graph_registry_cli_active=1
    set +e
    code-review-graph build --skip-flows --repo "$repo_root" \
      --data-dir "$graph_build_stage"
    graph_rc=$?
    set -e
    restore_graph_registry_after_cli "$graph_registry_after"
    graph_registry_cli_active=0
    [[ "$graph_rc" -eq 0 ]] || exit "$graph_rc"
    graph_build_fingerprint="$(graph_tree_fingerprint "$graph_build_stage")" \
      || { printf 'staged graph contains unsafe entries\n' >&2; exit 1; }
    node - "$graph_registry_after" "$repo_root" "$graph_target" <<'NODE'
const fs = require("fs");
const [file, repo, dataDir] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
if (!Array.isArray(value.repos)) process.exit(1);
const entry = value.repos.find((candidate) => candidate.path === repo);
if (!entry) process.exit(1);
entry.data_dir = dataDir;
fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
NODE

    graph_stage_rel="$(arkira_with_bound_parent "$repo_root" \
      ".arkira-graph-stage-anchor" _arkira_init_reserve_name_bound \
      ".arkira-graph-stage")"
    arkira_safe_mkdir "$repo_root" "$graph_stage_rel"
    graph_stage_identity="$(arkira_stat_identity \
      "$repo_root/$graph_stage_rel")" || exit 1
    graph_stage_owned=1
    arkira_with_bound_parent "$repo_root" \
      "$graph_stage_rel/.arkira-private-anchor" \
      _arkira_init_private_dir_bound
    arkira_with_bound_parent "$repo_root" \
      "$graph_stage_rel/.arkira-copy-anchor" \
      _arkira_init_copy_tree_bound "$graph_build_stage"
    [[ "$(arkira_stat_identity "$repo_root/$graph_stage_rel")" \
      == "$graph_stage_identity" ]] \
      || { printf 'graph publication stage was exchanged\n' >&2; exit 1; }
    graph_stage_fingerprint="$(graph_tree_fingerprint \
      "$repo_root/$graph_stage_rel")" || exit 1
    [[ "$graph_stage_fingerprint" == "$graph_build_fingerprint" ]] \
      || { printf 'graph publication stage changed during copy\n' >&2; exit 1; }

    if [[ "$graph_had_existing" -eq 1 ]]; then
      graph_backup_rel="$(arkira_with_bound_parent "$repo_root" \
        ".arkira-graph-backup-anchor" _arkira_init_reserve_name_bound \
        ".arkira-graph-backup")"
      rename_owned_entry "$repo_root" ".code-review-graph" "$graph_backup_rel"
      graph_backup_owned=1
      graph_backup_identity="$(arkira_stat_identity \
        "$repo_root/$graph_backup_rel")" || exit 1
      graph_backup_fingerprint="$(graph_tree_fingerprint \
        "$repo_root/$graph_backup_rel")" || exit 1
      [[ "$graph_backup_identity" == "$graph_original_identity" \
        && "$graph_backup_fingerprint" == "$graph_original_fingerprint" ]] \
        || { printf 'knowledge graph changed before atomic claim\n' >&2; exit 1; }
      if [[ -n "${ARKIRA_APPLY_INIT_FAIL_AFTER_GRAPH_BACKUP:-}" ]]; then
        printf 'ERROR: injected failure after graph backup publication\n' >&2
        false
      fi
    fi
    graph_published_identity="$graph_stage_identity"
    graph_published_fingerprint="$graph_stage_fingerprint"
    rename_owned_entry "$repo_root" "$graph_stage_rel" ".code-review-graph"
    graph_stage_owned=0
    graph_published=1
fi

# Configuration and registry outputs publish only after their complete private staging runs succeed.
publish_tx_file "$init_home" "$settings_rel" "$config_home/$settings_rel"
publish_tx_file "$init_home" ".arkira/config.json" \
  "$config_home/.arkira/config.json"
publish_tx_file "$repo_root" ".arkira/config.json" \
  "$config_repo/.arkira/config.json"
if [[ -n "$graph_registry_after" ]]; then
  if [[ -n "${ARKIRA_APPLY_INIT_TEST_ADD_UNRELATED_REGISTRY_ENTRY:-}" ]]; then
    node - "$graph_registry_root/.code-review-graph/registry.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, "utf8"));
if (!Array.isArray(data.repos)) process.exit(1);
data.repos = data.repos.filter((entry) => entry.path !== "/concurrent-after-restore");
data.repos.push({path:"/concurrent-after-restore", data_dir:"/concurrent-data"});
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
NODE
  fi
  publish_graph_registry_entry "$graph_registry_after"
fi

if [[ -n "${ARKIRA_APPLY_INIT_FAIL_AFTER_SIDE_EFFECTS:-}" ]]; then
  printf 'ERROR: injected failure after init side-effect publication\n' >&2
  false
fi

transaction_active=0
if [[ "$graph_backup_owned" -eq 1 && -n "$graph_backup_rel" ]]; then
  if [[ "$(arkira_stat_identity "$repo_root/$graph_backup_rel" \
      2>/dev/null || true)" != "$graph_backup_identity" \
    || "$(graph_tree_fingerprint "$repo_root/$graph_backup_rel" \
      2>/dev/null || true)" != "$graph_backup_fingerprint" ]]; then
    printf 'WARNING: committed init retained concurrently changed graph at: %s\n' \
      "$graph_backup_rel" >&2
  elif remove_owned_tree "$repo_root" "$graph_backup_rel"; then
    graph_backup_owned=0
  else
    printf 'WARNING: committed init, but could not remove old graph backup: %s\n' \
      "$graph_backup_rel" >&2
  fi
fi
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
