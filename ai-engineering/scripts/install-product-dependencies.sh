#!/usr/bin/env bash
# Install product dependencies from one exact lockfile and package-manager pin.
set -euo pipefail

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
  || die "could not resolve script directory"
package_manager_resolver="$script_dir/lib/package-manager-resolver.sh"
[[ -f "$package_manager_resolver" && ! -L "$package_manager_resolver" ]] \
  || die "package-manager resolver must be a regular file"
# shellcheck source=lib/package-manager-resolver.sh
source "$package_manager_resolver" \
  || die "could not source package-manager resolver"

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
    || die "ARKIRA_TRUSTED_BASE_SHA must name an exact trusted base commit"
  [[ "$(git rev-parse --verify "$candidate^{commit}" 2>/dev/null)" == "$candidate" ]] \
    || die "trusted base does not resolve to the exact requested commit"
  git merge-base --is-ancestor "$candidate" HEAD >/dev/null 2>&1 \
    || die "trusted base is not an ancestor of the candidate"
  printf '%s\n' "$candidate"
}

trusted_repository_class() {
  local base=$1 profile="app" config
  if git cat-file -e "$base:.arkira/config.json" 2>/dev/null; then
    [[ "$(git cat-file -t "$base:.arkira/config.json" 2>/dev/null)" == blob ]] \
      || die "trusted .arkira/config.json is not a regular file"
    config="$(git show "$base:.arkira/config.json")" \
      || die "trusted repository profile is unavailable"
    profile="$(node -e '
      let value;
      try { value = JSON.parse(process.argv[1]); } catch { process.exit(1); }
      const profile = value.profile === undefined ? "app" : value.profile;
      if (profile !== "app" && profile !== "static-web") process.exit(1);
      process.stdout.write(profile);
    ' "$config")" || die "trusted repository profile must be app or static-web"
  fi
  if [[ "$profile" == static-web ]]; then
    printf 'static-web\n'
  elif git cat-file -e "$base:package.json" 2>/dev/null; then
    [[ "$(git cat-file -t "$base:package.json" 2>/dev/null)" == blob ]] \
      || die "trusted package.json is not a regular file"
    printf 'package\n'
  else
    printf 'non-package\n'
  fi
}

select_package_manager() {
  local lock_entry lock_path lock_manager unsupported_lock lock_count=0
  local selected_lock="" selected_manager=""
  local selected_locks=()
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
        || die "$lock_path must be a committed regular file"
      selected_lock=$lock_path
      selected_manager=$lock_manager
      selected_locks+=("$lock_path")
      lock_count=$((lock_count + 1))
    fi
  done
  for unsupported_lock in bun.lockb bun.lock; do
    [[ ! -e "$unsupported_lock" && ! -L "$unsupported_lock" ]] \
      || die "$unsupported_lock is unsupported; Arkira product repositories use pnpm"
  done
  [[ "$lock_count" -eq 1 ]] \
    || die "package repos require exactly one committed supported lockfile; found: ${selected_locks[*]:-none}"
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
process.stdout.write(`${match[1]}\t${match[2]}\t${spec}\n`);
NODE
}

resolve_manager_runner() {
  local runner_output
  runner_output="$(arkira_resolve_manager_runner "$pinned_manager" "$pinned_version" 2>&1)" \
    || die "$runner_output"
  IFS=' ' read -r -a manager_runner <<< "$runner_output"
}

operation=install
case "$#" in
  0) ;;
  1)
    [[ "$1" == --activate-package-manager ]] \
      || die "usage: install-product-dependencies.sh [--activate-package-manager]"
    operation=activate
    ;;
  *) die "usage: install-product-dependencies.sh [--activate-package-manager]" ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "dependency install requires a Git worktree"
cd "$repo_root" || die "could not enter the Git worktree"
export CI=true
# The harness installs an exact committed lockfile. Do not add a time-based
# package quarantine that makes the same candidate pass or fail by wall clock.
export PNPM_CONFIG_MINIMUM_RELEASE_AGE=0
# This script is the explicit dependency-install boundary. Downstream package
# scripts must not cause pnpm to run the same check and install again.
export PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false
command -v node >/dev/null 2>&1 || die "node is required to validate package metadata"

trusted_base="$(resolve_trusted_base)"
repository_class="$(trusted_repository_class "$trusted_base")"
project_gate="scripts/project-release-gate.sh"
if [[ "$repository_class" != package ]]; then
  if [[ ! -e "$project_gate" && ! -L "$project_gate" ]]; then
    die "$repository_class repos require a committed $project_gate"
  fi
  is_committed_regular_file "$project_gate" \
    || die "$project_gate must be a committed regular file"
fi

if [[ ! -e package.json && ! -L package.json ]]; then
  [[ "$repository_class" != package ]] \
    || die "trusted package repository removed package.json"
  for unexpected_lock in pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json bun.lockb bun.lock; do
    [[ ! -e "$unexpected_lock" && ! -L "$unexpected_lock" ]] \
      || die "a package lockfile exists without a committed package.json"
  done
  printf 'Trusted %s repository has no package dependencies to install.\n' "$repository_class"
  exit 0
fi

is_committed_regular_file package.json \
  || die "package.json must be a committed regular file"
IFS=$'\t' read -r lock_manager selected_lock < <(select_package_manager)
IFS=$'\t' read -r pinned_manager pinned_version pinned_spec < <(read_package_manager_pin) \
  || die "package.json must pin packageManager to an exact npm, pnpm, or Yarn version"
[[ "$pinned_manager" == "$lock_manager" ]] \
  || die "packageManager $pinned_manager does not match $selected_lock"

if [[ "$operation" == activate ]]; then
  case "$pinned_manager" in
    npm)
      command -v npm >/dev/null 2>&1 || die "npm is required by $selected_lock"
      npm install --global "npm@$pinned_version"
      ;;
    pnpm|yarn)
      resolve_manager_runner
      if [[ "${manager_runner[0]}" == corepack ]]; then
        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack enable
        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare "$pinned_spec" --activate
      fi
      ;;
    *) die "unsupported package manager for $selected_lock" ;;
  esac
  exit 0
fi

case "$pinned_manager" in
  npm)
    command -v npm >/dev/null 2>&1 || die "npm is required by $selected_lock"
    actual_version="$(npm --version)" || die "could not resolve the npm version"
    [[ "$actual_version" == "$pinned_version" ]] \
      || die "npm version $actual_version does not match packageManager pin $pinned_version"
    npm ci
    ;;
  pnpm)
    resolve_manager_runner
    actual_version="$("${manager_runner[@]}" --version)" || die "could not resolve the pinned pnpm version"
    [[ "$actual_version" == "$pinned_version" ]] \
      || die "pnpm version $actual_version does not match packageManager pin $pinned_version"
    "${manager_runner[@]}" install --frozen-lockfile
    ;;
  yarn)
    resolve_manager_runner
    actual_version="$("${manager_runner[@]}" --version)" || die "could not resolve the pinned Yarn version"
    [[ "$actual_version" == "$pinned_version" ]] \
      || die "Yarn version $actual_version does not match packageManager pin $pinned_version"
    case "$actual_version" in
      0.*|1.*) "${manager_runner[@]}" install --frozen-lockfile ;;
      *) "${manager_runner[@]}" install --immutable ;;
    esac
    ;;
  *) die "unsupported package manager for $selected_lock" ;;
esac
