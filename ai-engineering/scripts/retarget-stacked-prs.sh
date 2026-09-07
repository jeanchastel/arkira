#!/usr/bin/env bash
# retarget-stacked-prs.sh <deleting-branch> <new-base>
#
# Before a merged PR's head branch is deleted, retarget any OPEN PRs stacked on it
# (base == <deleting-branch>) onto <new-base>. GitHub auto-closes a PR whose base
# branch is deleted, so a stacked child would otherwise be silently closed when the
# parent merges with branch deletion. Retargeting keeps the child open.
#
# Best-effort: a failed retarget warns and sets a non-zero exit, but never aborts
# the loop. Requires gh; if gh is absent the step is skipped (exit 0). The caller
# should treat a non-zero exit as "a child may need manual attention", not fatal.
#
# Note: when the parent was squash- or rebase-merged, a retargeted child still
# carries the parent's now-rewritten commits and will need a rebase onto the new
# base before it merges cleanly. This script only prevents the silent close.
set -uo pipefail

branch="${1:?usage: retarget-stacked-prs.sh <deleting-branch> <new-base>}"
new_base="${2:?usage: retarget-stacked-prs.sh <deleting-branch> <new-base>}"

if ! command -v gh >/dev/null 2>&1; then
  printf 'gh not available; skipping stacked-PR retarget for %s.\n' "$branch" >&2
  exit 0
fi

deps="$(gh pr list --state open --base "$branch" --json number --jq '.[].number' 2>/dev/null || true)"
[ -n "$deps" ] || { printf 'No open PRs stacked on %s.\n' "$branch"; exit 0; }

rc=0
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  if gh pr edit "$dep" --base "$new_base" >/dev/null 2>&1; then
    printf 'Retargeted stacked PR #%s: base %s -> %s (likely needs a rebase before it merges cleanly).\n' \
      "$dep" "$branch" "$new_base"
  else
    printf 'WARNING: could not retarget stacked PR #%s; deleting %s may auto-close it.\n' "$dep" "$branch" >&2
    rc=1
  fi
done <<< "$deps"

exit "$rc"
