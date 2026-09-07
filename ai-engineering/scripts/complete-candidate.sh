#!/usr/bin/env bash
# Commit and publish an already certified candidate without operator handoffs.
set -euo pipefail

die() { printf 'complete-candidate: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'usage: complete-candidate.sh --branch <branch> --message <message> [--base <branch>] [--supersedes <PR-number>]...\n' >&2
  exit 2
}

branch="" message="" base="main"
supersedes=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) branch=${2:-}; shift 2 ;;
    --message) message=${2:-}; shift 2 ;;
    --base) base=${2:-}; shift 2 ;;
    --supersedes) supersedes+=("${2:-}"); shift 2 ;;
    *) usage ;;
  esac
done
[[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$branch" != *..* ]] || die 'branch is invalid'
[ -n "$message" ] || die 'message is required'
[[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$base" != *..* ]] || die 'base is invalid'
for source_pr in "${supersedes[@]}"; do
  [[ "$source_pr" =~ ^[1-9][0-9]*$ ]] || die 'supersedes value must be a positive pull request number'
done

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'not inside a Git repository'
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
publisher="$script_dir/create-pr.sh"
[ -x "$publisher" ] && [ ! -L "$publisher" ] || die 'create-pr helper is missing or unsafe'
git -C "$repo" diff-files --quiet || die 'unstaged changes block automatic publication'
[ -z "$(git -C "$repo" ls-files --others --exclude-standard)" ] || die 'untracked files block automatic publication'
[ -n "$(git -C "$repo" diff --cached --name-only)" ] || die 'no staged candidate to publish'

publisher_args=(--base "$base")
for source_pr in "${supersedes[@]}"; do
  publisher_args+=(--supersedes "$source_pr")
done

bash "$publisher" --verify-staged "${publisher_args[@]}"
current_branch="$(git -C "$repo" branch --show-current)"
if [ "$current_branch" = "$base" ]; then
  git -C "$repo" switch -c "$branch"
elif [ "$current_branch" != "$branch" ]; then
  die "current branch '$current_branch' is not '$base' or '$branch'"
fi

git -C "$repo" commit -m "$message"
exec bash "$publisher" "${publisher_args[@]}"
