#!/usr/bin/env bash
set -uo pipefail

# Trusted source. This file is invoked from the installed harness, never from
# the candidate tree. Keep the result contract stable for release helpers.
CLASSIFIER_VERSION=3
CLASSIFIER_RULES=committed-d-ts-content-v1

usage() {
  printf 'usage: %s --repo PATH --base SHA --tree SHA\n' "$0" >&2
  exit 2
}

repo=
base=
tree=
while (($#)); do
  case "$1" in
    --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
    --base) (($# >= 2)) || usage; base=$2; shift 2 ;;
    --tree) (($# >= 2)) || usage; tree=$2; shift 2 ;;
    *) usage ;;
  esac
done

fail() {
  printf 'classifier: %s\n' "$1" >&2
  exit 1
}

is_full_sha() {
  [[ ${#1} -eq 40 && "$1" != *[!0123456789abcdef]* ]]
}

is_sensitive_path() {
  local path=${1,,}
  [[ "$path" =~ (^|/)(ui|components|pages|app|runtime|auth|db|database|migration|migrations|generated|config|configs|workflow|workflows|dependency|dependencies|test|tests|__tests__|data-access|data|api)(/|$) ]] && return 0
  [[ "$path" =~ (^|/)(auth|runtime|user|database|migration|config|workflow|repository)\.d\.ts$ ]] && return 0
  return 1
}

[[ -n "$repo" && -n "$base" && -n "$tree" ]] || usage
is_full_sha "$base" || fail 'base must be a full 40-character lowercase SHA'
is_full_sha "$tree" || fail 'tree must be a full 40-character lowercase SHA'
[[ -d "$repo/.git" || -f "$repo/.git" ]] || fail 'repo is not a Git worktree'
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail 'repo is not a Git worktree'

base_commit="$(git -C "$repo" rev-parse --verify "$base^{commit}" 2>/dev/null)" || fail 'base is not an exact commit object'
tree_object="$(git -C "$repo" rev-parse --verify "$tree^{tree}" 2>/dev/null)" || fail 'tree is not a commit or tree object'

shape=type-only
raw_diff="$(mktemp "${TMPDIR:-/tmp}/arkira-validation-shape.XXXXXX")" || fail 'cannot create temporary file'
trap 'rm -f "$raw_diff"' EXIT
git -C "$repo" diff --no-renames --no-abbrev --raw -z "$base_commit" "$tree_object" -- >"$raw_diff" 2>/dev/null || fail 'cannot read candidate diff'
while IFS= read -r -d '' metadata; do
  IFS= read -r -d '' path || fail 'cannot parse candidate diff metadata'
  metadata=${metadata#:}
  read -r old_mode new_mode old_oid new_oid change_status extra <<<"$metadata"
  if [[ -n "${extra:-}" || "$change_status" != M ||
    "$old_mode" != 100644 || "$new_mode" != 100644 ||
    "$old_oid" == "$new_oid" || "$path" != *.d.ts ]] || is_sensitive_path "$path"; then
    shape=behavioral
    break
  fi
done <"$raw_diff"

[[ -s "$raw_diff" ]] || shape=behavioral

printf 'VALIDATION_SHAPE=%s\n' "$shape"
printf 'CLASSIFIER_VERSION=%s\n' "$CLASSIFIER_VERSION"
printf 'CANDIDATE_BASE=%s\n' "$base_commit"
printf 'CANDIDATE_TREE=%s\n' "$tree_object"
printf 'CLASSIFIER_RULES=%s\n' "$CLASSIFIER_RULES"
