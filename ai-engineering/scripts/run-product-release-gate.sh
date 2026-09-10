#!/usr/bin/env bash
# Run mandatory package checks plus any committed product-specific release gate.
set -uo pipefail

[ "${ARKIRA_IN_CANDIDATE_GATE_SUITE:-}" != 1 ] || { printf 'FAIL: ARKIRA_IN_CANDIDATE_GATE_SUITE forbids run-product-release-gate.sh recursion\n' >&2; exit 1; }

phase=legacy
case "$#" in
  0) ;;
  2)
    [[ "$1" == --phase && ( "$2" == fast || "$2" == build ) ]] \
      || { printf 'SKIP: usage: run-product-release-gate.sh [--phase fast|build]\n' >&2; exit 77; }
    phase=$2
    ;;
  *) printf 'SKIP: usage: run-product-release-gate.sh [--phase fast|build]\n' >&2; exit 77 ;;
esac

skip_gate() {
  printf 'SKIP: %s\n' "$1" >&2
  exit 77
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
  || skip_gate "could not resolve script directory"
package_manager_resolver="$script_dir/lib/package-manager-resolver.sh"
playwright_installer="$script_dir/install-playwright-browsers.sh"
[[ -f "$package_manager_resolver" && ! -L "$package_manager_resolver" ]] \
  || skip_gate "package-manager resolver must be a regular file"
[[ -f "$playwright_installer" && ! -L "$playwright_installer" ]] \
  || skip_gate "Playwright installer must be a regular file"
# shellcheck source=lib/package-manager-resolver.sh
source "$package_manager_resolver" \
  || skip_gate "could not source package-manager resolver"

is_committed_regular_file() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  git ls-files --error-unmatch -- "$path" >/dev/null 2>&1
}

resolve_trusted_base() {
  local candidate="${ARKIRA_TRUSTED_BASE_SHA:-${VERSION_BASE_REF:-}}"
  if [[ -z "$candidate" ]] \
    && git show-ref --verify --quiet refs/remotes/origin/main; then
    candidate="$(git rev-parse 'refs/remotes/origin/main^{commit}' 2>/dev/null)"
  fi
  [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] \
    || skip_gate "ARKIRA_TRUSTED_BASE_SHA must name an exact trusted base commit"
  [[ "$(git rev-parse --verify "$candidate^{commit}" 2>/dev/null)" == "$candidate" ]] \
    || skip_gate "trusted base does not resolve to the exact requested commit"
  git merge-base --is-ancestor "$candidate" HEAD >/dev/null 2>&1 \
    || skip_gate "trusted base is not an ancestor of the candidate"
  printf '%s\n' "$candidate"
}

trusted_repository_class() {
  local base=$1 profile="app" config
  if git cat-file -e "$base:.arkira/config.json" 2>/dev/null; then
    [[ "$(git cat-file -t "$base:.arkira/config.json" 2>/dev/null)" == blob ]] \
      || skip_gate "trusted .arkira/config.json is not a regular file"
    config="$(git show "$base:.arkira/config.json")" \
      || skip_gate "trusted repository profile is unavailable"
    profile="$(node -e '
      let value;
      try { value = JSON.parse(process.argv[1]); } catch { process.exit(1); }
      const profile = value.profile === undefined ? "app" : value.profile;
      if (profile !== "app" && profile !== "static-web") process.exit(1);
      process.stdout.write(profile);
    ' "$config")" || skip_gate "trusted repository profile must be app or static-web"
  fi
  if [[ "$profile" == static-web ]]; then
    printf 'static-web\n'
  elif git cat-file -e "$base:package.json" 2>/dev/null; then
    [[ "$(git cat-file -t "$base:package.json" 2>/dev/null)" == blob ]] \
      || skip_gate "trusted package.json is not a regular file"
    printf 'package\n'
  else
    printf 'non-package\n'
  fi
}

select_package_manager() {
  local lock_entry lock_path lock_manager lock_count=0 selected_lock="" selected_manager=""
  local lockfiles=(
    "pnpm-lock.yaml:pnpm"
    "yarn.lock:yarn"
    "package-lock.json:npm"
    "npm-shrinkwrap.json:npm"
  )
  for lock_entry in "${lockfiles[@]}"; do
    lock_path=${lock_entry%%:*}
    lock_manager=${lock_entry#*:}
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
      is_committed_regular_file "$lock_path" \
        || skip_gate "$lock_path must be a committed regular file"
      selected_lock=$lock_path
      selected_manager=$lock_manager
      lock_count=$((lock_count + 1))
    fi
  done
  [[ "$lock_count" -eq 1 ]] \
    || skip_gate "package repos require exactly one committed supported lockfile"
  printf '%s\t%s\n' "$selected_manager" "$selected_lock"
}

read_package_manager_pin() {
  node - package.json <<'NODE'
const fs = require("fs");
let value;
try { value = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); }
catch { process.exit(1); }
const spec = value.packageManager;
const match = typeof spec === "string"
  ? /^(npm|pnpm|yarn)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+sha(?:224|256|384|512)\.[0-9A-Za-z+/=]+)?$/.exec(spec)
  : null;
if (!match) process.exit(1);
process.stdout.write(`${match[1]}\t${match[2]}\n`);
NODE
}

validate_vercel_package_manager() {
  local expected_manager=$1 config=vercel.json
  [[ ! -e "$config" && ! -L "$config" ]] && return 0
  is_committed_regular_file "$config" \
    || skip_gate "$config must be a committed regular file"
  node - "$config" "$expected_manager" <<'NODE'
const fs = require("fs");
let config;
try { config = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); }
catch { process.exit(1); }
if (!config || typeof config !== "object" || Array.isArray(config)) process.exit(1);

const expected = process.argv[3];
const managerPatterns = {
  npm: /(^|[\s;&|()])npm(?:@[0-9A-Za-z][0-9A-Za-z._+-]*)?(?=\s|$)/,
  pnpm: /(^|[\s;&|()])pnpm(?:@[0-9A-Za-z][0-9A-Za-z._+-]*)?(?=\s|$)/,
  yarn: /(^|[\s;&|()])yarn(?:@[0-9A-Za-z][0-9A-Za-z._+-]*)?(?=\s|$)/,
};
for (const field of ["installCommand", "buildCommand"]) {
  const command = config[field];
  if (command === undefined || command === null) continue;
  if (typeof command !== "string") process.exit(1);
  for (const [manager, pattern] of Object.entries(managerPatterns)) {
    if (manager !== expected && pattern.test(command)) process.exit(1);
  }
}
NODE
}

run_package_manager() {
  if [[ "$package_manager" == npm ]]; then
    npm "$@"
  else
    "${manager_runner[@]}" "$@"
  fi
}

resolve_manager_runner() {
  local runner_output
  runner_output="$(arkira_resolve_manager_runner "$package_manager" "$pinned_version" 2>&1)" \
    || skip_gate "$runner_output"
  IFS=' ' read -r -a manager_runner <<< "$runner_output"
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || skip_gate "product release gate requires a Git worktree"
cd "$repo_root" || skip_gate "product release gate could not enter the Git worktree"
export CI=true
# The harness validates an exact committed lockfile. Do not add a time-based
# package quarantine that makes the same candidate pass or fail by wall clock.
export PNPM_CONFIG_MINIMUM_RELEASE_AGE=0
# Dependency installation is an explicit gate step. Do not let pnpm repeat it
# before each package script when the committed lockfile has not changed.
export PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false
command -v node >/dev/null 2>&1 \
  || skip_gate "node is required to validate product release metadata"

trusted_base="$(resolve_trusted_base)" || exit $?
repository_class="$(trusted_repository_class "$trusted_base")" || exit $?
project_gate="scripts/project-release-gate.sh"
has_project_gate=0
if [[ -e "$project_gate" || -L "$project_gate" ]]; then
  is_committed_regular_file "$project_gate" \
    || skip_gate "$project_gate must be a committed regular file"
  has_project_gate=1
fi
if [[ "$repository_class" != package && "$has_project_gate" -ne 1 ]]; then
  skip_gate "$repository_class repos require a committed $project_gate"
fi

has_package=0
if [[ -e package.json || -L package.json ]]; then
  is_committed_regular_file package.json \
    || skip_gate "package.json must be a committed regular file"
  has_package=1
elif [[ "$repository_class" == package ]]; then
  skip_gate "trusted package repository removed package.json"
fi

if [[ "$has_package" -eq 1 ]]; then
  IFS=$'\t' read -r lock_manager selected_lock < <(select_package_manager) \
    || skip_gate "could not select one committed package manager lockfile"
  validate_vercel_package_manager "$lock_manager" \
    || skip_gate "vercel.json package-manager commands must match $lock_manager"
  IFS=$'\t' read -r package_manager pinned_version < <(read_package_manager_pin) \
    || skip_gate "package.json must pin packageManager to an exact npm, pnpm, or Yarn version"
  [[ "$package_manager" == "$lock_manager" ]] \
    || skip_gate "packageManager $package_manager does not match $selected_lock"
  case "$package_manager" in
    npm)
      command -v npm >/dev/null 2>&1 \
        || skip_gate "npm is required by $selected_lock but is unavailable"
      actual_version="$(npm --version)" \
        || skip_gate "could not resolve the npm version"
      ;;
    pnpm|yarn)
      resolve_manager_runner
      actual_version="$("${manager_runner[@]}" --version)" \
        || skip_gate "could not resolve the pinned $package_manager version"
      ;;
    *) skip_gate "unsupported package manager for $selected_lock" ;;
  esac
  [[ "$actual_version" == "$pinned_version" ]] \
    || skip_gate "$package_manager version $actual_version does not match packageManager pin $pinned_version"

  if [[ "$phase" == legacy ]]; then
    # Product-owned integration gates can invoke Playwright directly. Establish
    # the shared browser/dependency preflight before any package script so that
    # a stale unrelated Chrome APT source cannot become that first invocation.
    bash "$playwright_installer" chromium
    playwright_status=$?
    [[ "$playwright_status" -eq 0 ]] || exit "$playwright_status"
  fi

  if [[ "$phase" == build ]]; then
    release_tasks=(build)
  else
    release_tasks=(lint typecheck test build)
  fi
  for task in "${release_tasks[@]}"; do
    node - package.json "$task" <<'NODE' >/dev/null 2>&1 \
      || skip_gate "package.json must define a non-empty $task script"
const fs = require("fs");
try {
  const pkg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const script = pkg.scripts && pkg.scripts[process.argv[3]];
  if (typeof script !== "string" || script.trim() === "") process.exit(1);
} catch { process.exit(1); }
NODE
  done

  printf 'Running mandatory product release checks with %s (%s)\n' \
    "$package_manager" "$selected_lock"
  for task in "${release_tasks[@]}"; do
    printf '\n=== product-%s ===\n' "$task"
    run_package_manager run "$task"
    task_status=$?
    [[ "$task_status" -eq 0 ]] || exit "$task_status"
  done
fi

if [[ "$phase" == legacy && "$has_project_gate" -eq 1 ]]; then
  printf '\n=== product-explicit-release-gate ===\n'
  bash "$project_gate"
  exit $?
fi

[[ "$has_package" -eq 1 && "$repository_class" == package ]] \
  || skip_gate "release gate has no trusted package checks or explicit project gate"
