#!/usr/bin/env bash
set -uo pipefail

ARKIRA_DOCUMENTATION_ROUTER_TEMP=''
trap '[[ -z "${ARKIRA_DOCUMENTATION_ROUTER_TEMP:-}" ]] || rm -rf -- "$ARKIRA_DOCUMENTATION_ROUTER_TEMP"' EXIT

fail() { printf 'documentation gate: %s\n' "$*" >&2; return 1; }
invalid() { printf 'documentation gate: %s\n' "$*" >&2; return 2; }

materialize_trusted_router_file() {
  local source=$1 target=$2 expected_mode=$3 entry metadata mode kind blob
  entry="$(git -C "$repo" ls-tree "$base" -- "$source" 2>/dev/null)" || return 1
  [[ -n "$entry" ]] || return 1
  metadata=${entry%%$'\t'*}
  IFS=' ' read -r mode kind blob <<< "$metadata"
  [[ "$mode" == "$expected_mode" && "$kind" == blob && "$blob" =~ ^[0-9a-f]{40}$ ]] || return 1
  mkdir -p -- "$(dirname -- "$target")" || return 1
  git -C "$repo" cat-file blob "$blob" > "$target" || return 1
  [[ -f "$target" && ! -L "$target" ]] || return 1
}

load_trusted_router() {
  local running_root
  running_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 1
  if [[ "${ARKIRA_HARNESS_VERIFIED:-}" == true && "${ARKIRA_HARNESS_ROOT:-}" == "$running_root" ]]; then
    [[ -f "$running_root/ai-engineering/runtime/tier-routing.sh" &&
      ! -L "$running_root/ai-engineering/runtime/tier-routing.sh" ]] || return 1
    # The verified external harness supplies code; product risk rules still use the trusted base.
    builtin source "$running_root/ai-engineering/runtime/tier-routing.sh" || return 1
    arkira_tier_policy_valid "$ARKIRA_TIER_ROUTING_POLICY" || return 1
    jq -e . "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA" >/dev/null 2>&1 || return 1
    return 0
  fi
  ARKIRA_DOCUMENTATION_ROUTER_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/arkira-documentation-router.XXXXXX")" || return 1
  chmod 700 "$ARKIRA_DOCUMENTATION_ROUTER_TEMP" || return 1
  materialize_trusted_router_file ai-engineering/runtime/tier-routing.sh \
    "$ARKIRA_DOCUMENTATION_ROUTER_TEMP/tier-routing.sh" 100644 || return 1
  materialize_trusted_router_file ai-engineering/runtime/tier-routing-policy.json \
    "$ARKIRA_DOCUMENTATION_ROUTER_TEMP/tier-routing-policy.json" 100644 || return 1
  materialize_trusted_router_file ai-engineering/runtime/schemas/risk-paths.json \
    "$ARKIRA_DOCUMENTATION_ROUTER_TEMP/schemas/risk-paths.json" 100644 || return 1
  # shellcheck disable=SC1090  # The trusted base supplies this exact materialized path.
  builtin source "$ARKIRA_DOCUMENTATION_ROUTER_TEMP/tier-routing.sh" || return 1
  arkira_tier_policy_valid "$ARKIRA_TIER_ROUTING_POLICY" || return 1
  jq -e . "$ARKIRA_TIER_ROUTING_MANIFEST_SCHEMA" >/dev/null 2>&1 || return 1
}

resolve_inputs() {
  local resolved
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || {
    invalid 'invalid trusted base: expected an exact 40 hex commit'; return; }
  resolved="$(git -C "$repo" rev-parse --verify "$base^{commit}" 2>/dev/null)" \
    || { invalid 'invalid trusted base: commit is unavailable'; return; }
  [[ "$resolved" == "$base" ]] || { invalid 'invalid trusted base: commit is ambiguous'; return; }
  [[ "$tree" =~ ^[0-9a-f]{40}$ ]] || {
    invalid 'invalid candidate tree: expected an exact 40 hex tree'; return; }
  resolved="$(git -C "$repo" rev-parse --verify "$tree^{tree}" 2>/dev/null)" \
    || { invalid 'invalid candidate tree: tree is unavailable'; return; }
  [[ "$resolved" == "$tree" ]] || { invalid 'invalid candidate tree: object is ambiguous'; return; }
}

documentation_shape() {
  local stream content metadata path old_mode new_mode old_blob new_blob status extra count=0 routing tier
  routing="$(arkira_route_candidate "$repo" "$base" "$tree" quick documentation-path-routing)" || {
    invalid 'structured tier routing failed'; return; }
  tier="$(jq -er '.final_tier' <<< "$routing")" || { invalid 'structured tier routing is malformed'; return; }
  if [[ "$tier" == elevated ]]; then
    printf 'VALIDATION_SHAPE=complete\n'
    return 0
  fi
  stream="$(mktemp "${TMPDIR:-/tmp}/arkira-documentation-shape.XXXXXX")" || return 2
  content="$(mktemp "${TMPDIR:-/tmp}/arkira-documentation-content.XXXXXX")" || {
    rm -f -- "$stream"; return 2; }
  if ! git -C "$repo" diff-tree -r --no-renames --raw -z "$base" "$tree" > "$stream"; then
    rm -f -- "$stream" "$content"; invalid 'candidate diff cannot be computed'; return
  fi
  while IFS= read -r -d '' metadata; do
    if ! IFS= read -r -d '' path; then
      rm -f -- "$stream" "$content"; invalid 'candidate diff is malformed'; return
    fi
    metadata=${metadata#:}
    IFS=' ' read -r old_mode new_mode old_blob new_blob status extra <<< "$metadata"
    if [[ -n "${extra:-}" || ! "$old_mode" =~ ^[0-7]{6}$ || ! "$new_mode" =~ ^[0-7]{6}$ \
      || ! "$old_blob" =~ ^[0-9a-f]{40}$ || ! "$new_blob" =~ ^[0-9a-f]{40}$ \
      || ! "$status" =~ ^[A-Z]$ ]]; then
      rm -f -- "$stream" "$content"; invalid 'candidate diff metadata is malformed'; return
    fi
    count=$((count + 1))
    case "$status:$old_mode:$new_mode" in
      A:000000:100644|M:100644:100644) ;;
      *) rm -f -- "$stream" "$content"; printf 'VALIDATION_SHAPE=complete\n'; return 0 ;;
    esac
    case "$path" in
      reports/*.md|docs/specs/*.md|docs/plans/*.md) ;;
      *) rm -f -- "$stream" "$content"; printf 'VALIDATION_SHAPE=complete\n'; return 0 ;;
    esac
    [[ "$path" != */../* && "$path" != ../* && "$path" != */./* && "$path" != ./* ]] || {
      rm -f -- "$stream" "$content"; printf 'VALIDATION_SHAPE=complete\n'; return 0; }
    [[ "$(git -C "$repo" cat-file -t "$new_blob" 2>/dev/null)" == blob ]] || {
      rm -f -- "$stream" "$content"; invalid 'candidate blob is unavailable'; return; }
    git -C "$repo" cat-file blob "$new_blob" > "$content" || {
      rm -f -- "$stream" "$content"; invalid 'candidate blob cannot be read'; return; }
    if LC_ALL=C od -An -v -tx1 "$content" | grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
      rm -f -- "$stream" "$content"; printf 'VALIDATION_SHAPE=complete\n'; return 0
    fi
  done < "$stream"
  rm -f -- "$stream" "$content"
  [[ "$count" -gt 0 ]] && printf 'VALIDATION_SHAPE=report-only\n' \
    || printf 'VALIDATION_SHAPE=complete\n'
}

candidate_is_exact_and_clean() {
  local path
  [[ "$(git -C "$repo" write-tree 2>/dev/null)" == "$tree" ]] || {
    fail 'candidate tree moved'; return; }
  while IFS= read -r -d '' path; do
    fail "candidate residue: tracked path has unstaged modification: $path"
    return
  done < <(git -C "$repo" diff-files --name-only -z)
  while IFS= read -r -d '' path; do
    fail "candidate residue: untracked path is not ignored: $path"
    return
  done < <(git -C "$repo" ls-files --others --exclude-standard -z)
}

markdown_check() {
  awk '
    /^\140\140\140/ { ticks++; in_ticks = !in_ticks; next }
    /^~~~/ { tildes++; in_tildes = !in_tildes; next }
    in_ticks || in_tildes { next }
    /^#{7}/ { exit 1 }
    /^#{1,6}[^ #]/ { exit 1 }
    END { if (ticks % 2 || tildes % 2) exit 1 }
  ' "$1"
}

normalize_repo_path() {
  local input=$1 part normalized='' index
  local -a parts stack
  stack=()
  IFS='/' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        (( ${#stack[@]} > 0 )) || return 1
        unset "stack[$((${#stack[@]} - 1))]"
        ;;
      *) stack[${#stack[@]}]="$part" ;;
    esac
  done
  for ((index=0; index<${#stack[@]}; index++)); do
    [[ -z "$normalized" ]] || normalized="$normalized/"
    normalized="$normalized${stack[index]}"
  done
  [[ -n "$normalized" ]] || return 1
  printf '%s' "$normalized"
}

check_links() {
  local document=$1 file=$2 links link target resolved directory
  links="$(mktemp "${TMPDIR:-/tmp}/arkira-documentation-links.XXXXXX")" || return 1
  LC_ALL=C grep -Eo '\[[^][]*\]\([^()]+\)' "$file" > "$links" || true
  while IFS= read -r link; do
    target=${link#*(}
    target=${target%)}
    case "$target" in '<'*'>') target=${target#<}; target=${target%>} ;; esac
    case "$target" in
      ''|'#'*|http://*|https://*|mailto:*|tel:*|data:*|//*) continue ;;
    esac
    target=${target%%#*}
    target=${target%%\?*}
    [[ -n "$target" && "$target" != *[[:space:]]* && "$target" != *'%'* ]] || {
      rm -f -- "$links"; fail "ambiguous local link in $document: $target"; return; }
    if [[ "$target" == /* ]]; then
      target=${target#/}
    else
      directory=${document%/*}
      [[ "$directory" == "$document" ]] && directory=''
      target=${directory:+$directory/}$target
    fi
    resolved="$(normalize_repo_path "$target")" || {
      rm -f -- "$links"; fail "local link escapes the repository in $document: $target"; return; }
    git -C "$repo" cat-file -e "$tree:$resolved" 2>/dev/null || {
      rm -f -- "$links"; fail "unresolved local link in $document: $target"; return; }
  done < "$links"
  rm -f -- "$links"
}

run_validation() {
  local shape paths content path
  shape="$(documentation_shape)" || return
  [[ "$shape" == VALIDATION_SHAPE=report-only ]] || {
    fail 'candidate is not report-only'; return; }
  candidate_is_exact_and_clean || return
  git -C "$repo" diff --check "$base" "$tree" || { fail 'diff check failed'; return; }
  paths="$(mktemp "${TMPDIR:-/tmp}/arkira-documentation-paths.XXXXXX")" || return 1
  content="$(mktemp "${TMPDIR:-/tmp}/arkira-documentation-file.XXXXXX")" || {
    rm -f -- "$paths"; return 1; }
  git -C "$repo" diff-tree -r --no-renames --name-only -z "$base" "$tree" > "$paths" || {
    rm -f -- "$paths" "$content"; return 1; }
  while IFS= read -r -d '' path; do
    git -C "$repo" show "$tree:$path" > "$content" || {
      rm -f -- "$paths" "$content"; fail "changed document cannot be read: $path"; return; }
    markdown_check "$content" || {
      rm -f -- "$paths" "$content"; fail "Markdown check failed: $path"; return; }
    check_links "$path" "$content" || { rm -f -- "$paths" "$content"; return 1; }
  done < "$paths"
  rm -f -- "$paths" "$content"
  if [[ -n "${ARKIRA_DOCUMENTATION_GATE_TEST_HOOK:-}" ]]; then
    [[ -x "$ARKIRA_DOCUMENTATION_GATE_TEST_HOOK" && ! -L "$ARKIRA_DOCUMENTATION_GATE_TEST_HOOK" ]] \
      || { fail 'documentation test hook is invalid'; return; }
    "$ARKIRA_DOCUMENTATION_GATE_TEST_HOOK" "$repo" || {
      fail 'documentation test hook failed'; return; }
  fi
  candidate_is_exact_and_clean || return
  printf 'documentation gate: passed base=%s tree=%s shape=report-only\n' "$base" "$tree"
}

command=${1:-}
shift || true
repo=''
base=''
tree=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || { invalid 'missing value for --repo'; exit $?; }; repo=$2; shift 2 ;;
    --base) [[ $# -ge 2 ]] || { invalid 'missing value for --base'; exit $?; }; base=$2; shift 2 ;;
    --tree) [[ $# -ge 2 ]] || { invalid 'missing value for --tree'; exit $?; }; tree=$2; shift 2 ;;
    *) invalid "unknown argument: $1"; exit $? ;;
  esac
done
case "$command" in classify|validate) ;; *) invalid 'expected classify or validate'; exit $? ;; esac
[[ -n "$repo" && -n "$base" && -n "$tree" ]] || { invalid 'repo, base, and tree are required'; exit $?; }
repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || { invalid 'repository is unavailable'; exit $?; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { invalid 'repository is unavailable'; exit $?; }
resolve_inputs || exit $?
load_trusted_router || { invalid 'trusted tier-routing dependencies are missing, malformed, or unsafe'; exit $?; }
if [[ "$command" == classify ]]; then
  documentation_shape
else
  run_validation
fi
