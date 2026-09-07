#!/usr/bin/env bash
# SessionStart hook: notice a changed set of pending CLAUDE.md proposals once.
# The fingerprint stamp lives inside the git dir, never in the working tree.
set -uo pipefail
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
prop_dir="$repo_root/.arkira/proposals/claude-md"
# An absent queue is not a state transition. Stay state-free until this repo has
# an actual proposal surface, rather than seeding an "empty" stamp in every
# unconfigured repository visited by SessionStart.
[ -d "$prop_dir" ] || exit 0
git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || true)"
stamp="${git_dir:+$git_dir/arkira-proposal-notice-stamp}"

write_notice_state() {
  local next=$1 prior="" tmp=""
  [ -n "$stamp" ] || return 0
  [ -f "$stamp" ] && prior="$(cat "$stamp" 2>/dev/null || true)"
  [ "$prior" != "$next" ] || return 0
  tmp="$(mktemp "$stamp.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || return 0
  chmod 600 "$tmp" 2>/dev/null || true
  if printf '%s\n' "$next" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$stamp" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

count=0
if [ -d "$prop_dir" ]; then
  count="$(find "$prop_dir" -maxdepth 1 -name '*.patch' -type f 2>/dev/null | wc -l | tr -d ' ')"
fi
case "$count" in ''|*[!0-9]*) count=0;; esac
if [ "$count" -eq 0 ]; then
  # Record the healthy transition. Recreating the same proposal later is a new
  # actionable state and must be surfaced once again.
  write_notice_state "empty"
  exit 0
fi
if [ "$count" -gt 0 ]; then
  # Fingerprint pending content and review sidecars, not just pathnames. Editing
  # a patch in place or changing its metadata is a new review state.
  fingerprint="$(ARKIRA_PROPOSAL_DIR="$prop_dir" node -e '
const fs = require("fs");
const crypto = require("crypto");
const dir = process.env.ARKIRA_PROPOSAL_DIR;
const digest = crypto.createHash("sha256");
let names = [];
try { names = fs.readdirSync(dir); } catch { process.exit(0); }
for (const name of names.sort()) {
  if (!/\.(?:patch|meta\.json|verdict\.txt)$/.test(name)) continue;
  const path = dir + "/" + name;
  try {
    const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink()) continue;
    digest.update(name); digest.update("\0");
    digest.update(fs.readFileSync(path)); digest.update("\0");
  } catch {}
}
process.stdout.write(digest.digest("hex"));
' 2>/dev/null)"
  if [ -z "$fingerprint" ]; then
    fingerprint="$(find "$prop_dir" -maxdepth 1 -name '*.patch' -type f -exec shasum -a 256 {} + 2>/dev/null \
      | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
  fi
  previous=""
  [[ -n "$stamp" && -f "$stamp" ]] && previous="$(cat "$stamp" 2>/dev/null || true)"
  [[ -n "$fingerprint" && "$fingerprint" == "$previous" ]] && exit 0
  if [ "$count" -eq 1 ]; then
    printf '1 CLAUDE.md proposal pending review in .arkira/proposals/claude-md/.\n'
  else
    printf '%s CLAUDE.md proposals pending review in .arkira/proposals/claude-md/.\n' "$count"
  fi
  write_notice_state "$fingerprint"
fi
exit 0
