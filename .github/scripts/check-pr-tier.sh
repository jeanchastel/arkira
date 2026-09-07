#!/usr/bin/env bash
# Report the candidate tier without invoking any gate.  This suite is itself a
# member of the canonical inventory, so invoking a gate here would recurse.
set -euo pipefail

export ARKIRA_IN_CANDIDATE_GATE_SUITE=1

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

# shellcheck source=../../ai-engineering/runtime/role-runtime.sh
source "$repo_root/ai-engineering/runtime/role-runtime.sh"

fail() { printf 'FAIL: candidate-gate: %s\n' "$*" >&2; exit 1; }

resolve_commit() {
  local value=$1 resolved
  resolved="$(git rev-parse --verify "$value^{commit}" 2>/dev/null)" || return 1
  [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$resolved"
}

resolve_tree() {
  local value=$1 resolved
  resolved="$(git rev-parse --verify "$value^{tree}" 2>/dev/null)" || return 1
  [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$resolved"
}

derive_standard_base() {
  local candidate="${ARKIRA_TRUSTED_BASE_SHA:-${VERSION_BASE_REF:-}}"
  if [[ -z "$candidate" ]] && git show-ref --verify --quiet refs/remotes/origin/main; then
    candidate="refs/remotes/origin/main"
  fi
  resolve_commit "$candidate"
}

base=""
tree=""
mode=""
if [[ -n "${ARKIRA_CANDIDATE_BASE:-}" && -n "${ARKIRA_CANDIDATE_TREE:-}" ]]; then
  if [[ -n "${GITHUB_EVENT_NAME:-}" ]]; then
    case "$GITHUB_EVENT_NAME" in
      pull_request)
        [[ -n "${GITHUB_BASE_REF:-}" ]] || fail 'pull_request base ref is unavailable'
        ;;
      push)
        [[ "${GITHUB_REF:-refs/heads/main}" == refs/heads/main ]] \
          || fail 'push event is not for main'
        ;;
      *) fail "unsupported GitHub event: $GITHUB_EVENT_NAME" ;;
    esac
  fi
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    mode="ci-exact-candidate"
  else
    mode="local-exact-candidate"
  fi
  base="$(resolve_commit "$ARKIRA_CANDIDATE_BASE")" \
    || fail 'exported candidate base cannot be resolved'
  tree="$(resolve_tree "$ARKIRA_CANDIDATE_TREE")" \
    || fail 'exported candidate tree cannot be resolved'
elif [[ -n "${ARKIRA_CANDIDATE_BASE:-}" || -n "${ARKIRA_CANDIDATE_TREE:-}" ]]; then
  fail 'local exact-candidate mode requires both ARKIRA_CANDIDATE_BASE and ARKIRA_CANDIDATE_TREE'
elif [[ -n "${GITHUB_EVENT_NAME:-}" ]]; then
  mode="github-event"
  case "$GITHUB_EVENT_NAME" in
    pull_request)
      [[ -n "${GITHUB_BASE_REF:-}" ]] || fail 'pull_request base ref is unavailable'
      base="$(resolve_commit "refs/remotes/origin/$GITHUB_BASE_REF")" \
        || fail 'pull_request base cannot be derived'
      ;;
    push)
      [[ "${GITHUB_REF:-refs/heads/main}" == refs/heads/main ]] \
        || fail 'push event is not for main'
      [[ -n "${GITHUB_EVENT_BEFORE:-}" ]] || fail 'push before SHA is unavailable'
      base="$(resolve_commit "$GITHUB_EVENT_BEFORE")" \
        || fail 'push base cannot be derived'
      ;;
    *) fail "unsupported GitHub event: $GITHUB_EVENT_NAME" ;;
  esac
  tree="$(resolve_tree HEAD)" || fail 'candidate tree cannot be resolved'
else
  mode="local-derived"
  base="$(derive_standard_base)" || fail 'trusted base cannot be derived'
  tree="$(resolve_tree HEAD)" || fail 'candidate tree cannot be resolved'
fi

temp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-pr-tier.XXXXXX")" || fail 'could not create temporary directory'
paths="$temp/paths"
trap 'rm -rf -- "$temp"' EXIT
git diff-tree -r --no-renames --name-only -z "$base" "$tree" > "$paths" \
  || fail 'candidate path range cannot be computed'
routing="$(arkira_route_candidate "$repo_root" "$base" "$tree" quick remote-path-routing)" \
  || fail 'tier cannot be computed'
tier="$(jq -er '.final_tier' <<< "$routing")" || fail 'tier result is malformed'
policy_digest="$(jq -er '.policy.digest' <<< "$routing")" || fail 'policy digest is unavailable'
routing_file="$temp/routing.json"
jq -S -c . <<< "$routing" > "$routing_file" || fail 'routing receipt is malformed'
routing_digest="$(arkira_tier_sha256_file "$routing_file")" || fail 'routing digest is unavailable'
rule_ids="$(jq -r '[.matches[].rule_id] | unique | sort | join(",")' <<< "$routing")" \
  || fail 'routing rule identifiers are unavailable'

config_change_is_version_only() {
  local config_diff line changed=0
  if ! config_diff="$(git diff --no-ext-diff --unified=0 "$base" "$tree" -- .arkira/config.json 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      '+++'*|'---'*) ;;
      +*|-*)
        changed=1
        [[ "$line" == *standards_version* ]] || return 1
        ;;
    esac
  done <<< "$config_diff"
  [[ "$changed" -eq 1 ]]
}

candidate_is_docs_only() {
  local path basename changed=0
  while IFS= read -r -d '' path; do
    changed=1
    basename="${path##*/}"
    case "$basename" in
      AGENTS.md|CLAUDE.md|CODEX.md|SKILL.md) return 1 ;;
    esac
    case "$path" in
      ai-engineering/root/*) return 1 ;;
      docs/*|reports/*) ;;
      CHANGELOG.md|VERSION.md|README.md|.claude-plugin/plugin.json|.claude-plugin/marketplace.json) ;;
      .arkira/config.json) config_change_is_version_only || return 1 ;;
      *) return 1 ;;
    esac
  done < "$paths"
  [[ "$changed" -eq 1 ]]
}

docs_only=false
if candidate_is_docs_only; then
  docs_only=true
fi

repository_class="product"
if git cat-file -e "$base:.claude-plugin/plugin.json" 2>/dev/null; then
  repository_class="standards"
fi
required_check="validate"
[[ "$repository_class" == standards ]] && required_check="candidate-gate"
inventory="${ARKIRA_REQUIRED_CHECKS:-}"
if [[ -z "$inventory" && "$repository_class" == standards ]]; then
  inventory="$(awk '/^jobs:/{jobs=1;next} jobs && /^  [A-Za-z0-9_-]+:$/ {job=$1;sub(/:$/, "", job); print job}' .github/workflows/ci.yml)" \
    || fail 'required-check inventory cannot be read'
elif [[ -z "$inventory" ]]; then
  inventory="validate"
fi
if [[ "$tier" == elevated ]]; then
  found=0
  for check in $inventory; do [[ "$check" == "$required_check" ]] && found=1; done
  [[ "$found" -eq 1 ]] || fail "Elevated tier requires required check '$required_check'"
fi

printf 'CANDIDATE_MODE=%s\n' "$mode"
printf 'CANDIDATE_BASE=%s\n' "$base"
printf 'CANDIDATE_TREE=%s\n' "$tree"
printf 'CANDIDATE_TIER=%s\n' "$tier"
printf 'CANDIDATE_POLICY_DIGEST=%s\n' "$policy_digest"
printf 'CANDIDATE_ROUTING_DIGEST=%s\n' "$routing_digest"
printf 'CANDIDATE_ROUTING_RULE_IDS=%s\n' "$rule_ids"
printf 'CANDIDATE_DOCS_ONLY=%s\n' "$docs_only"
classifier="$repo_root/ai-engineering/bootstrap/classify-validation-shape.sh"
if [[ -x "$classifier" ]]; then
  classifier_output="$(bash "$classifier" --repo "$repo_root" --base "$base" --tree "$tree" 2>/dev/null)" || fail 'trusted validation shape cannot be classified'
  validation_shape="$(awk -F= '$1 == "VALIDATION_SHAPE" {print $2}' <<< "$classifier_output")"
  [[ "$validation_shape" == type-only || "$validation_shape" == behavioral ]] || fail 'trusted validation shape is malformed'
  printf 'VALIDATION_SHAPE=%s\n' "$validation_shape"
else
  printf 'VALIDATION_SHAPE=behavioral\n'
fi
printf 'REQUIRED_CHECK=%s\n' "$required_check"
printf 'REVIEW_EVIDENCE=not-asserted (candidate-gate cannot inspect review evidence)\n'
