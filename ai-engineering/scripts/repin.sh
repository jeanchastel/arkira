#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
log=/dev/stderr
clone=''

fail() {
  printf 'repin failed at %s; log: %s; clone: %s\n' "$1" "$log" "${clone:-none}" >&2
  exit 1
}

run() {
  local step=$1
  shift
  "$@" >> "$log" 2>&1 || fail "$step"
}

repo=${1:-}
[[ -n "$repo" && -d "$repo" ]] || fail 'repository validation'
git -C "$repo" rev-parse --show-toplevel >/dev/null 2>> "$log" || fail 'repository validation'
origin="$(git -C "$repo" remote get-url origin 2>> "$log")" || fail 'origin validation'
[[ -n "$origin" ]] || fail 'origin validation'

work="$(mktemp -d "${TMPDIR:-/tmp}/arkira-repin.XXXXXX")"
clone="$work/repo"
log="$work/repin.log"
touch "$log"

run clone git clone -- "$origin" "$clone"
run migrate "$root/bin/arkira" migrate "$clone" --apply

status="$(git -C "$clone" status --porcelain=v1 2>> "$log")" || fail 'changed paths'
if [[ -z "$status" ]]; then
  printf 'already current\n'
  rm -rf -- "$work"
  exit 0
fi

pin_file="$clone/.github/workflows/arkira-ci.yml"
[[ -f "$pin_file" ]] || fail 'pin version'
version="$(sed -nE 's/^[[:space:]]*uses: jeanchastel\/arkira\/\.github\/workflows\/validate\.yml@[[:xdigit:]]{40} # v([0-9]+\.[0-9]+\.[0-9]+) approved-channel$/\1/p' "$pin_file" | head -n 1)"
[[ -n "$version" ]] || fail 'pin version'

run branch git -C "$clone" switch -c "chore/pin-harness-$version"
changed_paths=()
git -C "$clone" ls-files --modified --deleted --others --exclude-standard -z \
  > "$work/changed-paths" 2>> "$log" || fail 'changed paths'
while IFS= read -r -d '' path; do
  changed_paths+=("$path")
done < "$work/changed-paths"
[[ ${#changed_paths[@]} -gt 0 ]] || fail 'changed paths'
run stage git -C "$clone" add -A -- "${changed_paths[@]}"
run certify "$root/bin/arkira" gate "$clone" certify
run commit git -C "$clone" commit -m "chore(ci): advance the Arkira harness pin to v$version"

# create-pr.sh requires the verified harness environment that arkira run supplies.
run 'open PR' "$root/bin/arkira" run ai-engineering/scripts/create-pr.sh "$clone"
pr_url="$(sed -nE 's/^(Created|Refreshed) PR: (https:\/\/[^ ]+)$/\2/p' "$log" | tail -n 1)"
[[ -n "$pr_url" ]] || fail 'PR URL'
printf '%s\n' "$pr_url"
rm -rf -- "$work"
