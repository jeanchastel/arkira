#!/usr/bin/env bash
# Run one isolated database check or one Playwright shard for a split CI candidate.
set -uo pipefail

skip_gate() {
  printf 'SKIP: %s\n' "$1" >&2
  exit 77
}

usage() {
  printf 'SKIP: usage: run-product-integration.sh database | browser --shard <1-4> --total 4\n' >&2
  exit 77
}

kind=${1:-}
shift || true
shard=
total=
case "$kind:$#" in
  database:0) ;;
  browser:4)
    [[ "${1:-}" == --shard && "${3:-}" == --total ]] || usage
    shard=${2:-}
    total=${4:-}
    [[ "$shard" =~ ^[1-4]$ && "$total" == 4 ]] || usage
    ;;
  *) usage ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
  || skip_gate "could not resolve script directory"
contract_resolver="$script_dir/../distribution/product-ci-contract.mjs"
package_manager_resolver="$script_dir/lib/package-manager-resolver.sh"
[[ -f "$contract_resolver" && ! -L "$contract_resolver" ]] \
  || skip_gate "CI contract resolver must be a regular file"
[[ -f "$package_manager_resolver" && ! -L "$package_manager_resolver" ]] \
  || skip_gate "package-manager resolver must be a regular file"
# shellcheck source=lib/package-manager-resolver.sh
source "$package_manager_resolver" \
  || skip_gate "could not source package-manager resolver"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || skip_gate "product integration requires a Git worktree"
cd "$repo_root" || skip_gate "product integration could not enter the Git worktree"
command -v node >/dev/null 2>&1 || skip_gate "node is required"
command -v supabase >/dev/null 2>&1 || skip_gate "Supabase CLI 2.109.1 is required"
[[ "$(supabase --version 2>/dev/null)" == 2.109.1 ]] \
  || skip_gate "Supabase CLI must be exactly version 2.109.1"

trusted_base=${ARKIRA_TRUSTED_BASE_SHA:-}
[[ "$trusted_base" =~ ^[0-9a-f]{40}$ ]] \
  || skip_gate "ARKIRA_TRUSTED_BASE_SHA must name an exact trusted base commit"
candidate_tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" \
  || skip_gate "could not resolve the candidate tree"
contract_json="$(node "$contract_resolver" resolve \
  --repo "$repo_root" --base "$trusted_base" --tree "$candidate_tree")" \
  || exit $?

read_contract_field() {
  node -e '
    const value = JSON.parse(process.argv[1]);
    const path = process.argv[2].split(".");
    let current = value;
    for (const part of path) current = current && current[part];
    if (typeof current !== "string" && typeof current !== "boolean") process.exit(1);
    process.stdout.write(String(current));
  ' "$contract_json" "$1"
}

[[ "$(read_contract_field mode)" == split ]] \
  || skip_gate "split product integration requires an unchanged trusted .arkira/ci.json"
if [[ "$kind" == database ]]; then
  package_script="$(read_contract_field contract.database.package_script)" \
    || skip_gate "database package script is unavailable"
  needs_database=true
else
  package_script="$(read_contract_field contract.browser.package_script)" \
    || skip_gate "browser package script is unavailable"
  needs_database="$(read_contract_field contract.browser.requires_database)" \
    || skip_gate "browser database requirement is unavailable"
fi

[[ -f package.json && ! -L package.json ]] \
  || skip_gate "package.json must be a regular file"
git ls-files --error-unmatch -- package.json >/dev/null 2>&1 \
  || skip_gate "package.json must be committed"
package_pin="$(node - package.json "$package_script" <<'NODE'
const fs = require('fs');
let value;
try { value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); }
catch { process.exit(1); }
const match = typeof value.packageManager === 'string'
  ? /^(npm|pnpm|yarn)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+sha(?:224|256|384|512)\.[0-9A-Za-z+/=]+)?$/.exec(value.packageManager)
  : null;
const script = value.scripts && value.scripts[process.argv[3]];
if (!match || typeof script !== 'string' || script.trim() === '') process.exit(1);
process.stdout.write(`${match[1]}\t${match[2]}`);
NODE
)" || skip_gate "package metadata must pin its manager and define $package_script"
IFS=$'\t' read -r package_manager pinned_version <<< "$package_pin"

lock_count=0
lock_manager=
for entry in 'pnpm-lock.yaml:pnpm' 'yarn.lock:yarn' 'package-lock.json:npm' 'npm-shrinkwrap.json:npm'; do
  lock=${entry%%:*}
  manager=${entry#*:}
  if [[ -e "$lock" || -L "$lock" ]]; then
    [[ -f "$lock" && ! -L "$lock" ]] || skip_gate "$lock must be a regular file"
    git ls-files --error-unmatch -- "$lock" >/dev/null 2>&1 \
      || skip_gate "$lock must be committed"
    lock_count=$((lock_count + 1))
    lock_manager=$manager
  fi
done
[[ "$lock_count" -eq 1 && "$lock_manager" == "$package_manager" ]] \
  || skip_gate "package manager and exactly one committed lockfile must agree"

if [[ "$package_manager" == npm ]]; then
  command -v npm >/dev/null 2>&1 || skip_gate "npm is required"
  [[ "$(npm --version 2>/dev/null)" == "$pinned_version" ]] \
    || skip_gate "npm version does not match packageManager"
  manager_runner=(npm)
else
  runner_output="$(arkira_resolve_manager_runner "$package_manager" "$pinned_version" 2>&1)" \
    || skip_gate "$runner_output"
  IFS=' ' read -r -a manager_runner <<< "$runner_output"
  [[ "$("${manager_runner[@]}" --version 2>/dev/null)" == "$pinned_version" ]] \
    || skip_gate "$package_manager version does not match packageManager"
fi

export CI=true
export PNPM_CONFIG_MINIMUM_RELEASE_AGE=0
export PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false
export SUPABASE_TELEMETRY_DISABLED=1
export SUPABASE_HOME="${RUNNER_TEMP:-/tmp}/arkira-supabase-home"
mkdir -p -- "$SUPABASE_HOME" || exit $?

supabase_root="$repo_root/supabase"
supabase_temp="$supabase_root/.temp"
validate_supabase_paths() {
  local resolved_supabase_root resolved_supabase_temp
  [[ -d "$supabase_root" && ! -L "$supabase_root" ]] || {
    printf 'FAIL: supabase must be a regular directory inside the product worktree\n' >&2
    return 1
  }
  resolved_supabase_root="$(cd -- "$supabase_root" && pwd -P)" || {
    printf 'FAIL: could not resolve the Supabase directory\n' >&2
    return 1
  }
  [[ "$resolved_supabase_root" == "$supabase_root" ]] || {
    printf 'FAIL: supabase must not resolve outside the product worktree\n' >&2
    return 1
  }
  if [[ -e "$supabase_temp" || -L "$supabase_temp" ]]; then
    [[ -d "$supabase_temp" && ! -L "$supabase_temp" ]] || {
      printf 'FAIL: supabase/.temp must be a regular directory\n' >&2
      return 1
    }
    resolved_supabase_temp="$(cd -- "$supabase_temp" && pwd -P)" || {
      printf 'FAIL: could not resolve Supabase temporary state\n' >&2
      return 1
    }
    [[ "$resolved_supabase_temp" == "$supabase_temp" ]] || {
      printf 'FAIL: supabase/.temp must not resolve outside the product worktree\n' >&2
      return 1
    }
  fi
}
if [[ "$needs_database" == true ]]; then
  validate_supabase_paths \
    || skip_gate "unsafe Supabase paths prevent product integration"
fi
had_supabase_temp=0
[[ ! -e "$supabase_temp" ]] || had_supabase_temp=1
supabase_started=0

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local status=$1 cleanup_status=0 stop_status=0
  trap - EXIT
  if [[ "$supabase_started" -eq 1 ]]; then
    if validate_supabase_paths; then
      supabase stop --no-backup || stop_status=$?
    else
      cleanup_status=1
    fi
  fi
  if [[ "$needs_database" == true && "$had_supabase_temp" -eq 0 ]]; then
    if validate_supabase_paths; then
      if [[ -e "$supabase_temp" || -L "$supabase_temp" ]]; then
        rm -rf -- "$supabase_temp" || cleanup_status=$?
      fi
    else
      cleanup_status=1
    fi
  fi
  if [[ "$status" -eq 0 && "$stop_status" -ne 0 ]]; then
    status=$stop_status
  elif [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status=$cleanup_status
  fi
  exit "$status"
}
trap 'cleanup "$?"' EXIT

if [[ "$needs_database" == true ]]; then
  supabase start
  start_status=$?
  [[ "$start_status" -eq 0 ]] || exit "$start_status"
  supabase_started=1
fi

if [[ "$kind" == browser ]]; then
  export ARKIRA_PREBUILT_APP=1
  "${manager_runner[@]}" run "$package_script" -- "--shard=$shard/$total" --workers=1
else
  "${manager_runner[@]}" run "$package_script"
fi
exit $?
