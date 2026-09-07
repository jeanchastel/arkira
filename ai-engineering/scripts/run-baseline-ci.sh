#!/usr/bin/env bash
# Fast deterministic checks for ordinary delivery. The candidate gate supplies the 180 second cap.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'baseline CI requires a Git worktree\n' >&2
  exit 1
}
cd "$repo_root"
export CI=true
# Dependency installation has already completed before baseline scripts run.
# Do not let pnpm repeat its lockfile verification before each package script.
export PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false

base="${ARKIRA_TRUSTED_BASE_SHA:-${VERSION_BASE_REF:-}}"
if [[ "$base" =~ ^[0-9a-f]{40}$ ]]; then
  tree="$(git write-tree)"
  git diff --check "$base" "$tree"
else
  git diff --cached --check
fi

# The standards repository has no package scripts. Keep its ordinary baseline focused on syntax,
# clean-code plumbing, and the orchestration contract instead of the canonical release matrix.
if [[ -f ai-engineering/gates/test-code-quality-fixtures.sh \
  && -f scripts/test-orchestration-contract.sh ]]; then
  command -v shellcheck >/dev/null 2>&1 || {
    printf 'baseline CI requires shellcheck in the standards repository\n' >&2
    exit 1
  }
  shellcheck -S error ai-engineering/scripts/run-baseline-ci.sh \
    ai-engineering/runtime/candidate-gate.sh
  bash -n ai-engineering/runtime/candidate-gate.sh
  bash ai-engineering/gates/test-code-quality-fixtures.sh
  bash scripts/test-orchestration-contract.sh
  exit 0
fi

run_project_baseline() {
  local gate=scripts/project-baseline-gate.sh mode
  [[ -e "$gate" || -L "$gate" ]] || return 0
  [[ -f "$gate" && ! -L "$gate" ]] || {
    printf '%s must be a regular non-symlink file\n' "$gate" >&2
    return 1
  }
  git ls-files --error-unmatch -- "$gate" >/dev/null 2>&1 || {
    printf '%s must be tracked\n' "$gate" >&2
    return 1
  }
  if mode="$(stat -f '%Lp' "$gate" 2>/dev/null)"; then :
  elif mode="$(stat -c '%a' "$gate" 2>/dev/null)"; then :
  else return 1
  fi
  (( (0$mode & 022) == 0 )) || {
    printf '%s must not be group or world writable\n' "$gate" >&2
    return 1
  }
  bash "$gate"
}

if [[ ! -f package.json ]]; then
  run_project_baseline
  exit 0
fi

command -v node >/dev/null 2>&1 || {
  printf 'baseline CI requires Node for a package repository\n' >&2
  exit 1
}

IFS=$'\t' read -r manager version tasks < <(node - <<'NODE'
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const match = /^(npm|pnpm|yarn)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/.exec(pkg.packageManager || '');
if (!match) process.exit(1);
const tasks = ['lint', 'typecheck'].filter((name) =>
  typeof pkg.scripts?.[name] === 'string' && pkg.scripts[name].trim() !== '');
process.stdout.write(`${match[1]}\t${match[2]}\t${tasks.join(',')}\n`);
NODE
) || {
  printf 'package.json must pin packageManager to run baseline CI\n' >&2
  exit 1
}

# shellcheck source=lib/package-manager-resolver.sh
source "$script_dir/lib/package-manager-resolver.sh"
runner_text="$(arkira_resolve_manager_runner "$manager" "$version")"
read -r -a runner <<< "$runner_text"

IFS=',' read -r -a task_list <<< "$tasks"
for task in "${task_list[@]}"; do
  [[ -n "$task" ]] || continue
  "${runner[@]}" run "$task"
done

run_project_baseline
