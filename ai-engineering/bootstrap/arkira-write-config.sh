#!/usr/bin/env bash
# Apply or dry-run an arkira-init decisions payload.
# Reads decisions JSON from stdin. Writes:
#   - $ARKIRA_INIT_HOME/.arkira/config.json (user-level)
#   - <repo-root>/.arkira/config.json (per-repo, unless --no-repo)
#   - $ARKIRA_INIT_HOME/.claude/settings.json (patched via JSON Pointer per switch)
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/bootstrap/lib/file-safety.sh
. "$script_dir/lib/file-safety.sh"

init_home_root="${ARKIRA_INIT_HOME:-$HOME}"
plugin_root="${ARKIRA_INIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
settings_override="${ARKIRA_INIT_SETTINGS:-}"

repo_root=""
no_repo=0
mode=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) repo_root="$2"; shift 2 ;;
    --no-repo) no_repo=1; shift ;;
    --dry-run) mode="dry-run"; shift ;;
    --apply) mode="apply"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$mode" ]]; then
  echo "must pass --dry-run or --apply" >&2; exit 2
fi
if [[ $no_repo -eq 0 && -z "$repo_root" ]]; then
  echo "must pass --repo-root or --no-repo" >&2; exit 2
fi
if [[ -z "$plugin_root" ]]; then
  echo "plugin root unset (ARKIRA_INIT_PLUGIN_ROOT or CLAUDE_PLUGIN_ROOT)" >&2; exit 2
fi
init_home_root="$(arkira_safe_root "$init_home_root")" \
  || { echo "ARKIRA_INIT_HOME must be a regular, non-symlink directory" >&2; exit 2; }
if [[ $no_repo -eq 0 ]]; then
  repo_root="$(arkira_safe_root "$repo_root")" \
    || { echo "repo root must be a regular, non-symlink directory" >&2; exit 2; }
  arkira_safe_target "$repo_root" ".arkira/config.json" >/dev/null \
    || { echo "unsafe repo config path: .arkira/config.json" >&2; exit 2; }
fi

decisions="$(cat)"
if ! printf '%s' "$decisions" | jq -e . >/dev/null 2>&1; then
  echo "decisions JSON on stdin is invalid" >&2; exit 1
fi

switches_file="$plugin_root/ai-engineering/bootstrap/switches.json"
if [[ ! -f "$switches_file" ]]; then
  echo "missing $switches_file" >&2; exit 1
fi
settings_baseline="$plugin_root/templates/claude-settings.baseline.json"
if [[ ! -f "$settings_baseline" ]] || ! jq -e '
  (.permissions.deny | type == "array") and
  all(.permissions.deny[]; type == "string") and
  (.env.CLAUDE_CODE_GLOB_NO_IGNORE == "false")
' "$settings_baseline" >/dev/null 2>&1; then
  echo "missing or invalid Claude Code settings baseline: $settings_baseline" >&2
  exit 1
fi

# Stale-config detection (ALS-020 / TASK-18). Compare the switches present in
# the decisions payload against the inventory in switches.json. Any switch
# whose added_in is <= the decisions' standards_version, but which is missing
# from decisions.switches, is a stale-config signal: the wizard input was
# generated against an older plugin version and never re-prompted for that
# switch. Emit a WARN block to stderr listing each missing switch and the
# version that introduced it. Informational only; non-zero exit on missing
# switches is TASK-19's responsibility.
stale_missing="$(
  printf '%s' "$decisions" | jq -r --slurpfile sw "$switches_file" '
    . as $d |
    ($d.standards_version // "0.0.0") as $sv |
    ($sv | split(".") | map(tonumber)) as $sva |
    ($d.switches // {} | keys) as $present |
    $sw[0].switches[] |
    . as $s |
    (($s.added_in // $s.introduced_in // "0.0.0") | split(".") | map(tonumber)) as $aa |
    if ($aa <= $sva) and (($present | index($s.id)) | not) then
      "\($s.id) (added_in=\($s.added_in // $s.introduced_in // "?"))"
    else
      empty
    end
  ' 2>/dev/null
)"
if [[ -n "$stale_missing" ]]; then
  {
    echo "WARN stale config: decisions input is missing switches introduced in or before standards_version. Re-run /arkira-update."
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "WARN   missing: $line"
    done <<< "$stale_missing"
  } >&2
fi

# Hard switch-completeness check (ALS-023 / TASK-19). Independent of and
# stricter than the WARN above: the decisions input must contain an entry for
# every switch defined in switches.json, regardless of added_in. If any switch
# is missing, refuse to write any file and exit non-zero. This prevents the
# silent stale-config failure mode that produced the ALS-003 state and ensures
# adding a switch to switches.json without re-running /arkira-init or
# /arkira-update is caught at apply time, not at the next audit.
required_missing="$(
  printf '%s' "$decisions" | jq -r --slurpfile sw "$switches_file" '
    ($sw[0].switches | map(.id)) as $required |
    (.switches // {} | keys) as $present |
    $required - $present
    | .[]
  ' 2>/dev/null
)"
if [[ -n "$required_missing" ]]; then
  {
    echo "ERROR: decisions JSON is missing the following switches required by switches.json:"
    while IFS= read -r missing_id; do
      [[ -z "$missing_id" ]] && continue
      echo "  - $missing_id"
    done <<< "$required_missing"
    echo "Re-run /arkira-init or /arkira-update to refresh the decisions before applying."
  } >&2
  exit 1
fi

if [[ -n "$settings_override" ]]; then
  case "$settings_override" in
    /*) settings="$settings_override" ;;
    *) settings="$init_home_root/$settings_override" ;;
  esac
else
  settings="$init_home_root/.claude/settings.json"
fi
case "$settings" in
  "$init_home_root"/*) settings_rel=${settings#"$init_home_root"/} ;;
  *) echo "settings path must stay within ARKIRA_INIT_HOME" >&2; exit 2 ;;
esac

preflight_config_target() {
  local root=$1 rel=$2 label=$3 target
  target="$(arkira_safe_target "$root" "$rel")" \
    || { echo "unsafe $label path: $rel" >&2; return 1; }
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] \
      || { echo "$label target must be a regular, non-symlink file: $target" >&2; return 1; }
  fi
}

# Resolve and type-check every final target before reading or mutating any of
# them. In particular, a directory named config.json must fail closed instead
# of turning a later move into an accidental nested write.
preflight_config_target "$init_home_root" ".arkira/config.json" "user config"
preflight_config_target "$init_home_root" "$settings_rel" "settings"
if [[ $no_repo -eq 0 ]]; then
  preflight_config_target "$repo_root" ".arkira/config.json" "repo config"
fi

if [[ -f "$settings" ]]; then
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "$settings is not valid JSON, refusing to patch. Fix the file then re-run /arkira-init." >&2
    exit 1
  fi
  current_settings="$(cat "$settings")"
else
  current_settings="{}"
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the planned settings.json by applying every selected switch's patch.
patched="$current_settings"
conflicts=()
plans=()

while IFS=$'\t' read -r id ptr value; do
  [[ -z "$id" ]] && continue
  if [[ "$ptr" == "null" || -z "$ptr" ]]; then
    plans+=("CONFIG-ONLY $id = $value")
    continue
  fi
  # Convert /a/b/c to ["a","b","c"] path for jq, decoding ~1 and ~0 escapes.
  path_json="$(printf '%s' "$ptr" | jq -R '
    ltrimstr("/") | split("/") | map(gsub("~1"; "/") | gsub("~0"; "~"))
  ')"
  current_val="$(printf '%s' "$patched" | jq --argjson p "$path_json" 'getpath($p)')"
  if [[ "$current_val" != "null" && "$current_val" != "$value" ]]; then
    conflicts+=("CONFLICT $ptr current=$current_val new=$value (switch=$id)")
  fi
  patched="$(printf '%s' "$patched" | jq --argjson p "$path_json" --argjson v "$value" 'setpath($p; $v)')"
  plans+=("PATCH   $ptr = $value (switch=$id)")
done < <(
  printf '%s' "$decisions" | jq -r --slurpfile sw "$switches_file" '
    . as $d |
    $sw[0].switches[] |
    . as $s |
    ($d.switches[$s.id]) as $val |
    if $val == null then empty else
      [
        $s.id,
        ($s.settings_json_patch.pointer // "null"),
        ($val | tojson)
      ] | @tsv
    end
  '
)

# Merge the supported Claude Code noise controls. .claudeignore is not a
# Claude Code settings surface. Deny rules are appended without removing or
# reordering the user's existing rules, and Glob is configured to respect
# .gitignore. Existing non-array permission/env shapes fail closed.
if ! printf '%s' "$patched" | jq -e '
  ((.permissions.deny? // []) | type == "array") and
  all((.permissions.deny? // [])[]; type == "string") and
  ((.env? // {}) | type == "object")
' >/dev/null 2>&1; then
  echo "$settings has incompatible permissions.deny or env values; refusing to replace them." >&2
  exit 1
fi
current_glob_ignore="$(printf '%s' "$patched" | jq -r '.env.CLAUDE_CODE_GLOB_NO_IGNORE // "unset"')"
if [[ "$current_glob_ignore" != "unset" && "$current_glob_ignore" != "false" ]]; then
  conflicts+=("CONFLICT /env/CLAUDE_CODE_GLOB_NO_IGNORE current=$current_glob_ignore new=false (Arkira noise baseline)")
fi
patched="$(printf '%s' "$patched" | jq --slurpfile baseline "$settings_baseline" '
  . as $settings |
  ($baseline[0].permissions.deny // []) as $required |
  .permissions.deny = reduce $required[] as $rule
    ((.permissions.deny // []); if index($rule) == null then . + [$rule] else . end) |
  .env.CLAUDE_CODE_GLOB_NO_IGNORE = "false" |
  if has("$schema") then . else . + {"$schema": $baseline[0]["$schema"]} end
')"
baseline_deny_count="$(jq -r '.permissions.deny | length' "$settings_baseline")"
plans+=("PATCH   /permissions/deny += $baseline_deny_count Arkira noise-control rules")
plans+=("PATCH   /env/CLAUDE_CODE_GLOB_NO_IGNORE = false")

# Build the user-level and repo-level config files.
user_cfg="$(printf '%s' "$decisions" | jq --arg ts "$ts" '
  {
    schema_version,
    standards_version,
    apply_to_new_repos,
    update_mode,
    switches,
    self_heal: {
      probation_runs: 5,
      cost_regression_pct: 20
    },
    wizard_run_at: $ts
  }
')"
repo_cfg="$(printf '%s' "$decisions" | jq --arg ts "$ts" '
  {
    schema_version,
    standards_version,
    switches,
    self_heal: {
      probation_runs: 5,
      cost_regression_pct: 20
    },
    wizard_run_at: $ts,
    inherited_from_user_defaults: true
  }
')"

echo "Plan:"
for p in "${plans[@]+"${plans[@]}"}"; do echo "  $p"; done
for c in "${conflicts[@]+"${conflicts[@]}"}"; do echo "  $c"; done

if [[ "$mode" == "dry-run" ]]; then
  echo "WOULD WRITE $init_home_root/.arkira/config.json"
  if [[ $no_repo -eq 0 ]]; then
    echo "WOULD WRITE $repo_root/.arkira/config.json"
  fi
  echo "WOULD WRITE $settings"
  exit 0
fi

# Apply is a cooperative, identity-aware transaction shared with complete init.
# Every target is claimed before replacement. Rollback restores a prior version
# only when the live target is still the inode and content published by this
# invocation; a concurrent user edit is never overwritten or deleted.
transaction_dir="$(mktemp -d "${TMPDIR:-/tmp}/arkira-config-transaction.XXXXXX")"
chmod 700 "$transaction_dir"
transaction_dir="$(cd -P -- "$transaction_dir" && pwd -P)"
transaction_active=0
rollback_done=0
declare -a TX_ROOTS=("") TX_RELS=("") TX_LABELS=("")
declare -a TX_EXISTED=(0) TX_BACKUPS=("") TX_STAGED=("")
declare -a TX_CLAIMS=("") TX_CLAIM_IDENTITIES=("")
declare -a TX_PUBLISHED_IDENTITIES=("") TX_ATTEMPTED=(0)
declare -a CREATED_ROOTS=("") CREATED_RELS=("") CREATED_IDENTITIES=("")
declare -a LOCK_ROOTS=("") LOCK_RELS=("") LOCK_IDENTITIES=("")
LOCK_KEYS=""

cleanup_transaction() {
  local i lock_target
  for ((i=${#LOCK_RELS[@]}-1; i>=1; i--)); do
    lock_target="$(arkira_safe_target "${LOCK_ROOTS[$i]}" \
      "${LOCK_RELS[$i]}" 2>/dev/null || true)"
    if [[ -n "$lock_target" && -d "$lock_target" && ! -L "$lock_target" \
      && "$(arkira_stat_identity "$lock_target" 2>/dev/null || true)" \
        == "${LOCK_IDENTITIES[$i]}" ]]; then
      arkira_safe_rmdir "${LOCK_ROOTS[$i]}" "${LOCK_RELS[$i]}" \
        || printf 'WARNING: could not remove owned config lock: %s\n' \
          "$lock_target" >&2
    else
      printf 'WARNING: owned config lock changed; refusing to remove it\n' >&2
    fi
  done
  LOCK_RELS=("")
  [[ -z "${transaction_dir:-}" ]] || rm -rf -- "$transaction_dir"
  transaction_dir=""
}

acquire_lock() {
  local root=$1 rel=$2 key identity
  key="$root"$'\037'"$rel"
  printf '%s' "$LOCK_KEYS" | grep -Fxq -- "$key" && return 0
  arkira_safe_mkdir_new "$root" "$rel" || {
    printf 'another Arkira init/config transaction owns lock: %s/%s\n' \
      "$root" "$rel" >&2
    return 1
  }
  identity="$(arkira_stat_identity "$root/$rel")" || return 1
  LOCK_ROOTS+=("$root")
  LOCK_RELS+=("$rel")
  LOCK_IDENTITIES+=("$identity")
  LOCK_KEYS+="$key"$'\n'
}

private_mode() {
  if stat -f '%Lp' -- "$1" >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1"
  else
    stat -c '%a' -- "$1"
  fi
}

file_matches_snapshot() {
  local root=$1 rel=$2 snapshot=$3 compare mode expected_mode matches=1
  [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
  compare="$(mktemp "$transaction_dir/compare.XXXXXX")" || return 1
  if ! arkira_safe_read "$root" "$rel" > "$compare"; then
    rm -f -- "$compare"
    return 1
  fi
  mode="$(arkira_safe_file_mode "$root" "$rel")" || matches=0
  expected_mode="$(private_mode "$snapshot")" || matches=0
  cmp -s "$compare" "$snapshot" || matches=0
  rm -f -- "$compare"
  [[ "$matches" -eq 1 && "$mode" == "$expected_mode" ]]
}

record_target() {
  local root=$1 rel=$2 label=$3 staged=$4 target backup mode index
  target="$(arkira_safe_target "$root" "$rel")" || return 1
  index=${#TX_RELS[@]}
  backup="$transaction_dir/before.$index"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || return 1
    arkira_safe_read "$root" "$rel" > "$backup"
    mode="$(arkira_safe_file_mode "$root" "$rel")" || return 1
    chmod "$mode" "$backup"
    TX_EXISTED+=(1)
  else
    : > "$backup"
    TX_EXISTED+=(0)
  fi
  TX_ROOTS+=("$root") TX_RELS+=("$rel") TX_LABELS+=("$label")
  TX_BACKUPS+=("$backup") TX_STAGED+=("$staged") TX_CLAIMS+=("")
  TX_CLAIM_IDENTITIES+=("") TX_PUBLISHED_IDENTITIES+=("") TX_ATTEMPTED+=(0)
}

ensure_parent() {
  local root=$1 rel=$2 parent current="" part target identity
  parent="$(dirname -- "$rel")"
  [[ "$parent" != "." ]] || return 0
  IFS='/' read -r -a config_parent_parts <<<"$parent"
  for part in "${config_parent_parts[@]}"; do
    current="${current:+$current/}$part"
    target="$(arkira_safe_target "$root" "$current")" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
      [[ -d "$target" && ! -L "$target" ]] || return 1
    else
      arkira_safe_mkdir_new "$root" "$current" || return 1
      identity="$(arkira_stat_identity "$root/$current")" || return 1
      CREATED_ROOTS+=("$root") CREATED_RELS+=("$current")
      CREATED_IDENTITIES+=("$identity")
    fi
  done
}

publish_target() {
  local i=$1 root=${TX_ROOTS[$1]} rel=${TX_RELS[$1]} claim target
  TX_ATTEMPTED[$i]=1
  ensure_parent "$root" "$rel"
  if [[ "${ARKIRA_INIT_TEST_MUTATE_AFTER_SNAPSHOT_REL:-}" == "$rel" ]]; then
    printf '\nconcurrent config edit\n' >> "$root/$rel"
    unset ARKIRA_INIT_TEST_MUTATE_AFTER_SNAPSHOT_REL
  fi
  if [[ "${TX_EXISTED[$i]}" -eq 1 ]]; then
    claim="$(arkira_claim_regular_file "$root" "$rel" \
      ".arkira-config-original")" || return 1
    TX_CLAIMS[$i]="$claim"
    TX_CLAIM_IDENTITIES[$i]="$(arkira_stat_identity "$root/$claim")" \
      || return 1
    file_matches_snapshot "$root" "$claim" "${TX_BACKUPS[$i]}" || return 1
  else
    target="$(arkira_safe_target "$root" "$rel")" || return 1
    [[ ! -e "$target" && ! -L "$target" ]] || return 1
  fi
  TX_PUBLISHED_IDENTITIES[$i]="$(arkira_atomic_copy_new_with_identity \
    "$root" "$rel" "${TX_STAGED[$i]}")" || return 1
}

rollback_transaction() {
  local i current_claim current_identity target created identity failed=0
  [[ "$rollback_done" -eq 0 ]] || return 0
  rollback_done=1
  for ((i=${#TX_RELS[@]}-1; i>=1; i--)); do
    [[ "${TX_ATTEMPTED[$i]}" -eq 1 ]] || continue
    current_claim=""
    if [[ -n "${TX_PUBLISHED_IDENTITIES[$i]}" ]]; then
      current_claim="$(arkira_claim_regular_file "${TX_ROOTS[$i]}" \
        "${TX_RELS[$i]}" ".arkira-config-rollback" 2>/dev/null || true)"
    fi
    if [[ -n "$current_claim" ]]; then
      current_identity="$(arkira_stat_identity \
        "${TX_ROOTS[$i]}/$current_claim" 2>/dev/null || true)"
      if [[ "$current_identity" != "${TX_PUBLISHED_IDENTITIES[$i]}" ]] \
        || ! file_matches_snapshot "${TX_ROOTS[$i]}" "$current_claim" \
          "${TX_STAGED[$i]}"; then
        arkira_restore_claim_new "${TX_ROOTS[$i]}" "$current_claim" \
          "${TX_RELS[$i]}" || failed=1
        printf 'ERROR: config rollback preserved concurrent edit: %s\n' \
          "${TX_LABELS[$i]}" >&2
        failed=1
        continue
      fi
      if [[ "${TX_EXISTED[$i]}" -eq 1 ]]; then
        arkira_restore_claim_new "${TX_ROOTS[$i]}" "${TX_CLAIMS[$i]}" \
          "${TX_RELS[$i]}" || { failed=1; continue; }
      fi
      arkira_safe_remove_file "${TX_ROOTS[$i]}" "$current_claim" || failed=1
      continue
    fi
    target="$(arkira_safe_target "${TX_ROOTS[$i]}" "${TX_RELS[$i]}" \
      2>/dev/null || true)"
    if [[ -n "${TX_CLAIMS[$i]}" && -n "$target" \
      && ! -e "$target" && ! -L "$target" ]]; then
      arkira_restore_claim_new "${TX_ROOTS[$i]}" "${TX_CLAIMS[$i]}" \
        "${TX_RELS[$i]}" || failed=1
    elif [[ -n "${TX_PUBLISHED_IDENTITIES[$i]}" \
      || -n "${TX_CLAIMS[$i]}" ]]; then
      failed=1
    fi
  done
  for ((i=${#CREATED_RELS[@]}-1; i>=1; i--)); do
    created="$(arkira_safe_target "${CREATED_ROOTS[$i]}" \
      "${CREATED_RELS[$i]}" 2>/dev/null || true)"
    identity="$(arkira_stat_identity "$created" 2>/dev/null || true)"
    if [[ -n "$created" && "$identity" == "${CREATED_IDENTITIES[$i]}" ]]; then
      arkira_safe_rmdir "${CREATED_ROOTS[$i]}" "${CREATED_RELS[$i]}" \
        || failed=1
    fi
  done
  return "$failed"
}

transaction_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ "$transaction_active" -eq 1 ]]; then
    rollback_transaction || printf 'ERROR: configuration rollback was incomplete\n' >&2
  fi
  cleanup_transaction
  exit "$rc"
}
transaction_signal() {
  local signal=$1
  trap - EXIT HUP INT TERM
  [[ "$transaction_active" -eq 0 ]] \
    || rollback_transaction \
    || printf 'ERROR: configuration rollback was incomplete\n' >&2
  cleanup_transaction
  kill -s "$signal" "$$"
  exit 1
}
trap transaction_exit EXIT
trap 'transaction_signal HUP' HUP
trap 'transaction_signal INT' INT
trap 'transaction_signal TERM' TERM

acquire_lock "$init_home_root" ".arkira-init.lock"
if [[ $no_repo -eq 0 ]]; then
  if git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null)" \
    && git_dir="$(arkira_safe_root "$git_dir")"; then
    acquire_lock "$git_dir" "arkira-init.lock"
  else
    acquire_lock "$repo_root" ".arkira-init.lock"
  fi
fi

printf '%s\n' "$patched" > "$transaction_dir/settings.after"
printf '%s\n' "$user_cfg" > "$transaction_dir/user-config.after"
printf '%s\n' "$repo_cfg" > "$transaction_dir/repo-config.after"
chmod 600 "$transaction_dir/settings.after" "$transaction_dir/user-config.after" \
  "$transaction_dir/repo-config.after"

record_target "$init_home_root" "$settings_rel" "settings" \
  "$transaction_dir/settings.after"
record_target "$init_home_root" ".arkira/config.json" "user config" \
  "$transaction_dir/user-config.after"
if [[ $no_repo -eq 0 ]]; then
  record_target "$repo_root" ".arkira/config.json" "repo config" \
    "$transaction_dir/repo-config.after"
fi

# The plan was rendered before the cooperative lock. Refuse to apply it if the
# user settings changed meanwhile, even before the atomic claim boundary.
if [[ "${TX_EXISTED[1]}" -eq 1 ]]; then
  locked_settings="$(cat "${TX_BACKUPS[1]}")"
else
  locked_settings="{}"
fi
[[ "$locked_settings" == "$current_settings" ]] || {
  printf 'settings changed while configuration was planned; retry\n' >&2
  exit 1
}

# Keep at most one stable user recovery backup. Repeated successful runs do not
# create randomly named chat-visible clutter.
if [[ "${TX_EXISTED[1]}" -eq 1 \
  && "${ARKIRA_INIT_DISABLE_RETAINED_BACKUP:-0}" != "1" \
  && ! -e "$init_home_root/${settings_rel}.bak" \
  && ! -L "$init_home_root/${settings_rel}.bak" ]]; then
  record_target "$init_home_root" "${settings_rel}.bak" "settings backup" \
    "${TX_BACKUPS[1]}"
fi

transaction_active=1
for ((tx_index=1; tx_index<${#TX_RELS[@]}; tx_index++)); do
  publish_target "$tx_index"
  if [[ "$tx_index" -eq 1 && -n "${ARKIRA_INIT_FAIL_AFTER_SETTINGS:-}" ]]; then
    false
  fi
  if [[ "${TX_LABELS[$tx_index]}" == "user config" \
    && -n "${ARKIRA_INIT_FAIL_AFTER_USER_CONFIG:-}" ]]; then
    false
  fi
done

if [[ -n "${ARKIRA_INIT_TEST_MUTATE_BEFORE_FINAL_VALIDATE_REL:-}" ]]; then
  printf '\nconcurrent config edit before final validation\n' \
    >> "$init_home_root/$ARKIRA_INIT_TEST_MUTATE_BEFORE_FINAL_VALIDATE_REL"
fi
for ((tx_index=1; tx_index<${#TX_RELS[@]}; tx_index++)); do
  [[ "$(arkira_stat_identity "${TX_ROOTS[$tx_index]}/${TX_RELS[$tx_index]}" \
      2>/dev/null || true)" == "${TX_PUBLISHED_IDENTITIES[$tx_index]}" ]] \
    && file_matches_snapshot "${TX_ROOTS[$tx_index]}" "${TX_RELS[$tx_index]}" \
      "${TX_STAGED[$tx_index]}" || {
        printf 'final configuration candidate changed: %s\n' \
          "${TX_LABELS[$tx_index]}" >&2
        false
      }
done

transaction_active=0
trap - EXIT HUP INT TERM
cleanup_failed=0
for ((tx_index=1; tx_index<${#TX_CLAIMS[@]}; tx_index++)); do
  claim=${TX_CLAIMS[$tx_index]}
  [[ -n "$claim" ]] || continue
  if [[ "$(arkira_stat_identity "${TX_ROOTS[$tx_index]}/$claim" \
      2>/dev/null || true)" == "${TX_CLAIM_IDENTITIES[$tx_index]}" ]] \
    && file_matches_snapshot "${TX_ROOTS[$tx_index]}" "$claim" \
      "${TX_BACKUPS[$tx_index]}"; then
    arkira_safe_remove_file "${TX_ROOTS[$tx_index]}" "$claim" \
      || cleanup_failed=1
  else
    cleanup_failed=1
  fi
done
cleanup_transaction
[[ "$cleanup_failed" -eq 0 ]] || {
  printf 'configuration applied, but owned recovery state remains\n' >&2
  exit 1
}
printf 'WROTE %s\n' "$init_home_root/.arkira/config.json"
if [[ $no_repo -eq 0 ]]; then
  printf 'WROTE %s\n' "$repo_root/.arkira/config.json"
fi
printf 'WROTE %s\n' "$settings"
exit 0
