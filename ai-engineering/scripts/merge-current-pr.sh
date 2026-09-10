#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

review_artifact=""
gate_receipt=""
reviewer_evidence=""
judge_evidence=""
allowed_signers=""
release_archive=""
release_provenance=""
high_assurance=0
remote_main_state=""
remote_main_sha=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --high-assurance) high_assurance=1; shift ;;
    --review-artifact) [ "$#" -ge 2 ] || die "--review-artifact requires a path."; review_artifact="$2"; shift 2 ;;
    --gate-receipt) [ "$#" -ge 2 ] || die "--gate-receipt requires a path."; gate_receipt="$2"; shift 2 ;;
    --reviewer-evidence) [ "$#" -ge 2 ] || die "--reviewer-evidence requires a path."; reviewer_evidence="$2"; shift 2 ;;
    --judge-evidence) [ "$#" -ge 2 ] || die "--judge-evidence requires a path."; judge_evidence="$2"; shift 2 ;;
    --allowed-signers) [ "$#" -ge 2 ] || die "--allowed-signers requires a path."; allowed_signers="$2"; shift 2 ;;
    --release-archive) [ "$#" -ge 2 ] || die "--release-archive requires a path."; release_archive="$2"; shift 2 ;;
    --release-provenance) [ "$#" -ge 2 ] || die "--release-provenance requires a path."; release_provenance="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh CLI is not installed or not on PATH."
command -v jq >/dev/null 2>&1 || die "jq is required."
git remote get-url origin >/dev/null 2>&1 \
  || die "git remote 'origin' is not configured."

repo_root="$(git rev-parse --show-toplevel)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
validator="$script_dir/validate-review-artifact.sh"
provenance_verifier="$repo_root/scripts/release-provenance.sh"
config="$repo_root/.arkira/config.json"

# Manual merge validates against the configured installed harness. PR creation
# intentionally uses the candidate runtime that certified its exact tree.
resolve_candidate_gate() {
  local pin_state config_dir install_record plugin_key record_entry install_path harness_root central_status
  gate_route=''
  candidate_gate=''
  locator=''
  if [[ -f "$script_dir/publication-harness.sh" && ! -L "$script_dir/publication-harness.sh" ]]; then
    . "$script_dir/publication-harness.sh"
    if candidate_gate="$(arkira_publication_central_gate "$config" "$script_dir")"; then
      gate_route=verified-snapshot
      return
    else
      central_status=$?
      [[ "$central_status" -eq 4 ]] || exit "$central_status"
    fi
  elif jq -e '(.harness.channel == "stable" and
    .harness.repository == "jeanchastel/arkira")' "$config" >/dev/null 2>&1; then
    die 'public publication resolver is missing or unsafe'
  fi
  if [ ! -e "$config" ] && [ ! -L "$config" ]; then
    gate_route=legacy
  else
    [ ! -L "$config" ] || die "target repository .arkira/config.json is a symlink"
    [ -f "$config" ] || die "target repository .arkira/config.json is not a regular file"
    [ -r "$config" ] || die "target repository .arkira/config.json is unreadable"
    if ! pin_state="$(jq -r '
      if .harness == null then
        "disabled"
      elif (.harness | type) != "object" then
        "invalid:\(.harness | type)"
      elif (.harness | has("pin")) and (.harness.pin != null) then
        "configured"
      else
        "disabled"
      end
    ' "$config" 2>/dev/null)"; then
      die "target repository .arkira/config.json is not valid JSON"
    fi
    if [[ "$pin_state" == invalid:* ]]; then
      die "target repository .arkira/config.json .harness must be an object; found ${pin_state#invalid:}"
    fi
    case "$pin_state" in
      configured) gate_route=central ;;
      disabled) gate_route=legacy ;;
      *) die "target repository .arkira/config.json did not resolve one harness route" ;;
    esac
  fi

  if [ "$gate_route" = legacy ]; then
    candidate_gate="$repo_root/ai-engineering/runtime/candidate-gate.sh"
    [ -f "$candidate_gate" ] && [ ! -L "$candidate_gate" ] \
      || die "candidate gate is missing or unsafe: $candidate_gate"
    return
  fi

  config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  install_record="$config_dir/plugins/installed_plugins.json"
  plugin_key='arkira@arkira-labs-standards'
  [ ! -L "$install_record" ] || die "Arkira installation record is a symlink: $install_record"
  [ -e "$install_record" ] || die "Arkira installation record is missing: $install_record"
  [ -f "$install_record" ] || die "Arkira installation record is not a regular file: $install_record"
  [ -r "$install_record" ] || die "Arkira installation record is unreadable: $install_record"
  jq -e --arg key "$plugin_key" \
    '.version == 2 and (.plugins[$key] | type == "array" and length > 0)' \
    "$install_record" >/dev/null 2>&1 \
    || die "Arkira installation record is invalid or has no $plugin_key entry"
  record_entry="$(jq -c --arg key "$plugin_key" '
    .plugins[$key] as $entries |
    (first($entries[] | select(.scope == "user")) // $entries[0])
  ' "$install_record" 2>/dev/null)" \
    || die "Arkira installation record could not be read"
  install_path="$(jq -r '.installPath // empty' <<< "$record_entry" 2>/dev/null)" \
    || die "installation record installPath is invalid"
  [ -n "$install_path" ] || die "installation record installPath is empty"
  [ -d "$install_path" ] && [ -r "$install_path" ] \
    || die "installation record installPath is not a readable directory"
  harness_root="$(realpath "$install_path" 2>/dev/null)" \
    || die "installation record installPath could not be resolved"
  locator="$harness_root/bin/arkira"
  [ ! -L "$locator" ] || die "central Arkira locator is a symlink: $locator"
  [ -e "$locator" ] || die "central Arkira locator is missing: $locator"
  [ -f "$locator" ] || die "central Arkira locator is not a regular file: $locator"
  [ -r "$locator" ] || die "central Arkira locator is unreadable: $locator"
  [ -x "$locator" ] || die "central Arkira locator is not executable: $locator"
}

run_candidate_gate() {
  local gate_command=$1
  shift
  if [ "$gate_route" = central ]; then
    env -u ARKIRA_HOME_DEV "$locator" gate "$repo_root" "$gate_command" "$@" | tail -n +2
  else
    /bin/bash "$candidate_gate" "$gate_command" --repo "$repo_root" "$@"
  fi
}

if [ "$high_assurance" -eq 1 ]; then
  [ -f "$config" ] && [ ! -L "$config" ] \
    || die "--high-assurance requires a safe .arkira/config.json"
  jq -e '.switches.high_assurance_release == true' "$config" >/dev/null 2>&1 \
    || die "--high-assurance requires high_assurance_release to be enabled"
  [ -n "$review_artifact" ] || die "--review-artifact is required with --high-assurance."
  [ -n "$gate_receipt" ] || die "--gate-receipt is required with --high-assurance."
  [ -n "$reviewer_evidence" ] || die "--reviewer-evidence is required with --high-assurance."
  [ -n "$judge_evidence" ] || die "--judge-evidence is required with --high-assurance."
  [ -n "$allowed_signers" ] || die "--allowed-signers is required with --high-assurance."
  [ -f "$validator" ] && [ ! -L "$validator" ] \
    || die "review artifact validator is missing or unsafe: $validator"
elif [ -n "$review_artifact$gate_receipt$reviewer_evidence$judge_evidence$allowed_signers$release_archive$release_provenance" ]; then
  die "high-assurance evidence requires the explicit --high-assurance flag"
fi
if [ "$high_assurance" -ne 1 ]; then
  resolve_candidate_gate
fi

current_branch="$(git branch --show-current)"
[ -n "$current_branch" ] \
  || die "cannot merge from a detached HEAD; check out the PR branch first."
[ "$current_branch" != main ] \
  || die "refusing to run from main; check out the PR branch first."
[ -z "$(git status --porcelain=v1)" ] \
  || die "working tree is dirty; commit, stash, or discard changes before merging."

fetch_candidate_refs() {
  git fetch --no-tags origin \
    "+refs/heads/main:refs/remotes/origin/main" \
    "+refs/heads/$current_branch:refs/remotes/origin/$current_branch" \
    >/dev/null
}

validate_candidate_evidence() {
  local gate_mode=${1:-committed} candidate_tree=${2:-} base=${3:-}
  if [ "$high_assurance" -ne 1 ]; then
    case "$gate_mode" in
      committed) run_candidate_gate require-committed || exit $? ;;
      recorded) run_candidate_gate require-recorded \
        --candidate-tree "$candidate_tree" --base "$base" || exit $? ;;
      *) die "unknown candidate evidence validation mode: $gate_mode" ;;
    esac
    return
  fi
  /bin/bash "$validator" --repo "$repo_root" \
    --artifact "$review_artifact" --gate-receipt "$gate_receipt" \
    --reviewer-evidence "$reviewer_evidence" --judge-evidence "$judge_evidence" \
    --allowed-signers "$allowed_signers" \
    || die "review evidence validation failed for current PR head."
  if [ -f "$provenance_verifier" ] && [ ! -L "$provenance_verifier" ]; then
    /bin/bash "$provenance_verifier" verify --repo "$repo_root" \
      --candidate "$local_head_sha" --archive "$release_archive" \
      --provenance "$release_provenance" \
      || die "release archive or provenance validation failed."
  fi
}

worktree_for_branch() {
  local listing
  listing="$(git worktree list --porcelain)" \
    || die "cannot list worktrees to resolve the checkout holding '$1'."
  awk -v ref="branch refs/heads/$1" '
    /^worktree /{ path = substr($0, 10) }
    $0 == ref { print path; exit }' <<< "$listing"
}

set_required_checks() {
  local base=$1 marker_type="" ci_mode=""
  if marker_type="$(git cat-file -t "$base:.claude-plugin/plugin.json" 2>/dev/null)" \
    && [ "$marker_type" = blob ]; then
    repository_class="standards"
    required_checks=(
      candidate-gate fast-checks remote-verify arkira-delivery-authorization
    )
    return
  fi
  if { marker_type="$(git cat-file -t "$base:.arkira/config.json" 2>/dev/null)" \
      && [ "$marker_type" = blob ]; } \
    || { marker_type="$(git cat-file -t "$base:.arkira/sync-state.json" 2>/dev/null)" \
      && [ "$marker_type" = blob ]; }; then
    repository_class="product"
    required_checks=("validate / validate" arkira-delivery-authorization)
    if marker_type="$(git cat-file -t "$base:.arkira/ci.json" 2>/dev/null)"; then
      [ "$marker_type" = blob ] \
        || die "trusted product CI contract is not a regular file"
      ci_mode="$(git ls-tree "$base" -- .arkira/ci.json | awk 'NR == 1 {print $1}')"
      [ "$ci_mode" = 100644 ] \
        || die "trusted product CI contract must be a non-executable regular file"
      required_checks+=("validate / candidate")
    fi
    return
  fi
  die "cannot derive repository class from trusted remote main"
}

always_checks=(candidate-gate fast-checks)

validate_check_rollup() {
  local json=$1 label=$2 required_check count always_json latest_checks
  latest_checks="$(jq -ce '
    (.statusCheckRollup // []) |
    map(. + {arkira_check_name:(.name // .context // "")}) |
    group_by(.arkira_check_name) |
    map(
      if length == 1 then .[0]
      elif all(.[];
        (.startedAt | type == "string") and (.startedAt | length > 0)) then
        (sort_by(.startedAt) as $runs |
          if $runs[-1].startedAt == $runs[-2].startedAt then
            error("duplicate checks have the same start time")
          else $runs[-1]
          end)
      else error("duplicate checks lack start times")
      end)
  ' <<< "$json")" || die "$label check history cannot identify one latest run per name."
  count="$(jq 'length' <<< "$latest_checks")"
  [ "$count" -gt 0 ] || die "$label has no reported checks."
  for required_check in "${required_checks[@]}"; do
    count="$(jq -r --arg name "$required_check" \
      '[.[] | select(.arkira_check_name == $name)] | length' \
      <<< "$latest_checks")"
    [ "$count" -eq 1 ] \
      || die "$label must report required check '$required_check' exactly once."
  done
  always_json="$(printf '%s\n' "${always_checks[@]}" | jq -R . | jq -s .)"
  if ! jq -e --argjson always "$always_json" '
    def successful:
      ((.status // "") == "COMPLETED" and (.conclusion // "") == "SUCCESS") or
      ((.status // "") == "" and (.state // "") == "SUCCESS");
    . as $checks |
    ([$checks[] | . as $check | select(
      successful or
      (((.status // "") == "COMPLETED" and (.conclusion // "") == "SKIPPED") and
        (.arkira_check_name as $name | ($always | index($name)) == null)) or
      # Central migration preserves registered legacy product workflows. The
      # 0.133.1 delivery guard named synchronize failures separately, so only
      # its later exact-candidate authorization can supersede that failure.
      ($check.arkira_check_name == "arkira-delivery-disarm" and
        ($check.status // "") == "COMPLETED" and
        ($check.conclusion // "") == "FAILURE" and
        ($check.startedAt | type) == "string" and ($check.startedAt | length) > 0 and
        any($checks[];
          .arkira_check_name == "arkira-delivery-authorization" and successful and
          (.startedAt | type) == "string" and (.startedAt | length) > 0 and
          .startedAt > $check.startedAt))
    )] | length) == ($checks | length)
  ' <<< "$latest_checks" >/dev/null; then
    die "$label has a pending, failed, cancelled, disallowed skipped, or unavailable check."
  fi
}

fetch_review_state() {
  gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviews(first:100,states:[APPROVED]){nodes{state commit{oid}} pageInfo{hasNextPage}} reviewThreads(first:100){nodes{isResolved} pageInfo{hasNextPage}}}}}' \
    -F owner="$repo_owner" -F name="$repo_short_name" -F number="$pr_number" 2>/dev/null
}

validate_review_state() {
  local json=$1 label=$2
  jq -e --arg head "$local_head_sha" \
    '.data.repository.pullRequest.reviews.nodes[]? | select(.state == "APPROVED" and .commit.oid == $head)' \
    <<< "$json" >/dev/null \
    || die "$label has no approval submitted for the current candidate commit."
  ! jq -e '.data.repository.pullRequest.reviews.pageInfo.hasNextPage == true' \
    <<< "$json" >/dev/null \
    || die "$label approval query is incomplete."
  validate_review_threads "$json" "$label"
}

validate_review_threads() {
  local json=$1 label=$2
  ! jq -e '.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved != true)' \
    <<< "$json" >/dev/null \
    || die "$label has unresolved review threads."
  ! jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == true' \
    <<< "$json" >/dev/null \
    || die "$label review-thread query is incomplete."
}

assert_auto_delete_disabled() {
  local setting
  setting="$(gh api "repos/$repo_name" --jq '.delete_branch_on_merge|tojson' 2>/dev/null)" \
    || die "cannot read repository settings for $repo_name; refusing to merge."
  [ "$setting" = false ] \
    || die "repository $repo_name reports delete_branch_on_merge='${setting:-<missing>}'. Disable 'Automatically delete head branches' in the repository settings before merging. This helper deletes the merged branch itself, under an exact reviewed-tip lease and only after the merged tree, recorded candidate evidence, green pull request checks, and remote-main convergence have all been verified. A branch deleted by GitHub at merge time bypasses every one of those proofs."
}

assert_main_worktree_ready() {
  local path head ancestry_status
  path="$(worktree_for_branch main)"
  [ -n "$path" ] || return 0
  [ -d "$path" ] \
    || die "the worktree holding main is missing: $path"
  head="$(git -C "$path" rev-parse HEAD 2>/dev/null)" \
    || die "cannot resolve HEAD in the worktree holding main: $path"
  [ -z "$(git -C "$path" status --porcelain=v1)" ] \
    || die "the worktree holding main is dirty: $path"
  if git merge-base --is-ancestor "$head" "$remote_base_sha"; then
    return
  else
    ancestry_status=$?
  fi
  if [ "$ancestry_status" -eq 1 ]; then
    die "main in $path is not an ancestor of remote main; fast-forward it before merging."
  fi
  die "cannot determine whether main in $path is an ancestor of remote main."
}

fetch_candidate_refs
local_head_sha="$(git rev-parse HEAD)"
remote_head_sha="$(git rev-parse "refs/remotes/origin/$current_branch^{commit}")"
remote_base_sha="$(git rev-parse 'refs/remotes/origin/main^{commit}')"
[ "$(git ls-remote --heads origin "$current_branch" | awk '{print $1}')" = "$remote_head_sha" ] \
  || die "fetched PR head does not match the remote branch."
[ "$(git ls-remote --heads origin main | awk '{print $1}')" = "$remote_base_sha" ] \
  || die "fetched main does not match remote main."
base_provenance_type="$(git cat-file -t "$remote_base_sha:scripts/release-provenance.sh" 2>/dev/null || true)"
if [ -n "$base_provenance_type" ] && [ "$base_provenance_type" != blob ]; then
  die "trusted base release provenance verifier is not a regular file"
fi
if [ "$high_assurance" -eq 1 ] && { [ "$base_provenance_type" = blob ] \
  || [ -e "$provenance_verifier" ] || [ -L "$provenance_verifier" ]; }; then
  [ -f "$provenance_verifier" ] && [ ! -L "$provenance_verifier" ] \
    || die "release provenance verifier is missing or unsafe: $provenance_verifier"
  [ -n "$release_archive" ] && [ -n "$release_provenance" ] \
    || die "this repository requires --release-archive and --release-provenance"
elif [ "$high_assurance" -eq 1 ] \
  && { [ -n "$release_archive" ] || [ -n "$release_provenance" ]; }; then
  die "release provenance arguments are unsupported because the repository has no verifier"
fi

if ! pr_json="$(gh pr view "$current_branch" \
  --json number,title,baseRefName,headRefName,state,headRefOid,reviewDecision,statusCheckRollup 2>/dev/null)"; then
  die "no GitHub PR found for branch '$current_branch'."
fi
pr_number="$(jq -r '.number // empty' <<< "$pr_json")"
pr_title="$(jq -r '.title // empty' <<< "$pr_json")"
pr_base="$(jq -r '.baseRefName // empty' <<< "$pr_json")"
pr_head="$(jq -r '.headRefName // empty' <<< "$pr_json")"
pr_state="$(jq -r '.state // empty' <<< "$pr_json")"
pr_head_sha="$(jq -r '.headRefOid // empty' <<< "$pr_json")"
review_decision="$(jq -r '.reviewDecision // empty' <<< "$pr_json")"
[ -n "$pr_number" ] || die "PR response is missing a number."
[ "$pr_state" = OPEN ] || die "PR #$pr_number is not open; current state is '$pr_state'."
[ "$pr_head" = "$current_branch" ] \
  || die "PR #$pr_number head '$pr_head' does not match current branch '$current_branch'."
[ "$pr_base" = main ] \
  || die "PR #$pr_number targets '$pr_base', but this helper only merges PRs targeting main."
[ "$pr_head_sha" = "$local_head_sha" ] \
  && [ "$remote_head_sha" = "$local_head_sha" ] \
  || die "PR, remote branch, and local candidate SHAs do not match."
if [ "$high_assurance" -eq 1 ]; then
  [ "$(jq -r '.candidate_sha // empty' "$review_artifact" 2>/dev/null)" = "$local_head_sha" ] \
    || die "review artifact candidate does not match the PR head."
  [ "$(jq -r '.base_sha // empty' "$review_artifact" 2>/dev/null)" = "$remote_base_sha" ] \
    || die "review artifact base does not match current remote main."
  [ "$review_decision" = APPROVED ] \
    || die "PR review decision is '$review_decision', not APPROVED."
fi

set_required_checks "$remote_base_sha"
validate_check_rollup "$pr_json" "PR #$pr_number"
repo_name="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
  || die "cannot resolve repository identity for review-thread validation."
repo_owner="${repo_name%%/*}"
repo_short_name="${repo_name#*/}"
assert_auto_delete_disabled
review_state_json="$(fetch_review_state)" \
  || die "cannot query exact-commit approvals and review threads."
if [ "$high_assurance" -eq 1 ]; then
  validate_review_state "$review_state_json" "PR #$pr_number"
else
  validate_review_threads "$review_state_json" "PR #$pr_number"
fi
validate_candidate_evidence
assert_main_worktree_ready

revalidate_at_acceptance() {
  assert_auto_delete_disabled
  [ "$(git rev-parse HEAD)" = "$local_head_sha" ] \
    && [ -z "$(git status --porcelain=v1)" ] \
    || die "local candidate changed while awaiting confirmation."
  fetch_candidate_refs
  [ "$(git rev-parse "refs/remotes/origin/$current_branch^{commit}")" = "$local_head_sha" ] \
    || die "remote PR head changed while awaiting confirmation."
  [ "$(git rev-parse 'refs/remotes/origin/main^{commit}')" = "$remote_base_sha" ] \
    || die "remote main changed while awaiting confirmation; re-run the gate and review."
  [ "$(git ls-remote --heads origin "$current_branch" | awk '{print $1}')" = "$local_head_sha" ] \
    || die "remote PR head changed after the acceptance fetch."
  [ "$(git ls-remote --heads origin main | awk '{print $1}')" = "$remote_base_sha" ] \
    || die "remote main changed after the acceptance fetch."

  local latest_pr_json latest_review_state
  latest_pr_json="$(gh pr view "$current_branch" \
    --json state,headRefOid,reviewDecision,statusCheckRollup 2>/dev/null)" \
    || die "cannot refresh PR state before merge."
  [ "$(jq -r '.state // empty' <<< "$latest_pr_json")" = OPEN ] \
    || die "PR is no longer open."
  [ "$(jq -r '.headRefOid // empty' <<< "$latest_pr_json")" = "$local_head_sha" ] \
    || die "PR head changed while awaiting confirmation."
  if [ "$high_assurance" -eq 1 ]; then
    [ "$(jq -r '.reviewDecision // empty' <<< "$latest_pr_json")" = APPROVED ] \
      || die "PR is no longer approved."
  fi
  validate_check_rollup "$latest_pr_json" "refreshed PR #$pr_number"
  latest_review_state="$(fetch_review_state)" \
    || die "cannot refresh approvals and review threads before merge."
  if [ "$high_assurance" -eq 1 ]; then
    validate_review_state "$latest_review_state" "refreshed PR #$pr_number"
  else
    validate_review_threads "$latest_review_state" "refreshed PR #$pr_number"
  fi
  validate_candidate_evidence
  assert_main_worktree_ready
}

verify_remote_main_convergence() {
  local ancestry_status
  if ! remote_main_sha="$(git ls-remote --heads origin main | awk '{print $1}')" \
    || ! [[ "$remote_main_sha" =~ ^[0-9a-f]{40}$ ]]; then
    die "cannot query remote main after merged-tree validation; the merged branch was retained."
  fi
  if [ "$remote_main_sha" = "$merged_sha" ]; then
    remote_main_state=equal
    return
  fi

  if ! git fetch --no-tags origin \
    "+refs/heads/main:refs/remotes/origin/main" >/dev/null \
    || [ "$(git rev-parse 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)" != "$remote_main_sha" ]; then
    die "cannot fetch the remote main commit after merged-tree validation; the merged branch was retained."
  fi
  if git merge-base --is-ancestor "$merged_sha" "$remote_main_sha"; then
    remote_main_state=advanced
    return
  else
    ancestry_status=$?
  fi
  if [ "$ancestry_status" -eq 1 ]; then
    die "remote main was rewritten after merged-tree validation; the merged branch was retained."
  fi
  die "cannot determine whether remote main contains the validated merge; the merged branch was retained."
}

printf 'Ready to merge PR with the following context:\n'
printf '  Current branch: %s\n' "$current_branch"
printf '  PR number:      #%s\n' "$pr_number"
printf '  PR title:       %s\n' "$pr_title"
printf '  Base branch:    %s\n' "$pr_base"
printf '  Repository:     %s\n' "$repository_class"
printf '  Merge method:   squash\n\n'
printf 'This will squash-merge the PR, verify merged-tree equality and remote-main convergence,\n'
printf 'fast-forward the local main checkout, then attempt optional remote and local branch cleanup.\n\n'
printf 'Type "yes" to merge PR #%s: ' "$pr_number"
read -r confirmation
[ "$confirmation" = yes ] || die "confirmation did not match; merge canceled."

revalidate_at_acceptance
original_candidate_tree="$(git rev-parse "$local_head_sha^{tree}")"
original_trusted_base="$remote_base_sha"
gh pr merge "$pr_number" --squash --match-head-commit "$local_head_sha"

merge_state_timeout="${ARKIRA_MERGE_STATE_TIMEOUT_SECONDS:-60}"
merge_state_poll="${ARKIRA_MERGE_STATE_POLL_SECONDS:-2}"
[[ "$merge_state_timeout" =~ ^[0-9]+$ ]] && [[ "$merge_state_poll" =~ ^[0-9]+$ ]] \
  || die "merge-state polling limits must be non-negative integers"
merge_started=$SECONDS
while :; do
  merged_pr_json="$(gh pr view "$pr_number" --json state,mergeCommit 2>/dev/null)" \
    || die "cannot resolve the squash-merge commit."
  merged_state="$(jq -r '.state // empty' <<< "$merged_pr_json")"
  merged_sha="$(jq -r '.mergeCommit.oid // empty' <<< "$merged_pr_json")"
  if [ "$merged_state" = MERGED ] && [[ "$merged_sha" =~ ^[0-9a-f]{40}$ ]]; then
    break
  fi
  [ $((SECONDS - merge_started)) -lt "$merge_state_timeout" ] \
    || die "merge completed but its exact commit SHA is still unavailable."
  sleep "$merge_state_poll"
done

git fetch --no-tags origin "+refs/heads/main:refs/remotes/origin/main" >/dev/null
[ "$(git rev-parse 'refs/remotes/origin/main^{commit}')" = "$merged_sha" ] \
  && [ "$(git ls-remote --heads origin main | awk '{print $1}')" = "$merged_sha" ] \
  || die "remote main does not match GitHub's squash-merge commit."
candidate_tree="$original_candidate_tree"
merged_tree="$(git rev-parse "$merged_sha^{tree}")"
[ "$candidate_tree" = "$merged_tree" ] \
  || die "squash-merge tree differs from the reviewed candidate; main is not deploy-safe."
validate_candidate_evidence recorded "$original_candidate_tree" "$original_trusted_base"
# Tree equality between the merged commit and reviewed candidate, plus the green pull request run,
# is the guarantee. There is no post-merge CI wait.
verify_remote_main_convergence

# Keep stacked children open before deleting the branch they target.
bash "$script_dir/retarget-stacked-prs.sh" "$current_branch" "$pr_base" \
  || die "a stacked PR could not be retargeted; the merged branch was retained"
main_worktree="$(worktree_for_branch main)"
if [ -n "$main_worktree" ]; then
  git -C "$main_worktree" merge --ff-only "$merged_sha" \
    || die "cannot fast-forward main in $main_worktree; the merged branch was retained."
  [ "$(git -C "$main_worktree" rev-parse HEAD)" = "$merged_sha" ] \
    || die "main in $main_worktree did not update to the validated squash-merge commit."
else
  git switch main
  git merge --ff-only "$merged_sha"
  [ "$(git rev-parse HEAD)" = "$merged_sha" ] \
    || die "local main did not update to the validated squash-merge commit."
fi
verify_remote_main_convergence

# One rule: the publication guard authorizes a direct deletion only when the leased tip is an
# ancestor of the trusted base, and a squash-merged tip never is. Deletion of a merged branch is
# therefore owned by this helper, which has already proven reviewed-tree equality, recorded
# candidate evidence, green pull request checks, and remote-main convergence above. Without
# every one of those proofs nothing is deleted.
remote_branch_deleted=no
cleanup_failed=0
remote_ref_status=0
git ls-remote --exit-code --heads origin "$current_branch" >/dev/null 2>&1 || remote_ref_status=$?
if [ "$remote_ref_status" -eq 0 ]; then
  if ! git push --force-with-lease="refs/heads/$current_branch:$local_head_sha" \
    origin --delete "$current_branch"; then
    printf 'Remote branch retained because its reviewed-tip lease did not hold: %s\n' "$current_branch" >&2
    cleanup_failed=1
  else
    remote_branch_deleted=yes
  fi
elif [ "$remote_ref_status" -eq 2 ]; then
  remote_branch_deleted=absent
else
  printf 'Remote branch retained because its state could not be queried (git ls-remote exit %s): %s\n' \
    "$remote_ref_status" "$current_branch" >&2
  cleanup_failed=1
fi
local_branch_deleted="no"
if git show-ref --verify --quiet "refs/heads/$current_branch"; then
  branch_worktree="$(worktree_for_branch "$current_branch")"
  if [ -n "$branch_worktree" ]; then
    printf 'Local branch retained because it is checked out in a worktree: %s\n' "$current_branch"
    printf 'Worktree holding it: %s\n' "$branch_worktree"
    printf 'Delete the branch from a checkout that is not on it, or remove that worktree.\n'
  elif git branch -d "$current_branch"; then
    local_branch_deleted="yes"
  else
    printf 'Local branch retained because Git did not consider it fully merged after squash: %s\n' "$current_branch"
    printf 'Review and delete it manually when appropriate; this helper will not force-delete branches.\n'
  fi
else
  printf 'Local branch already absent: %s\n' "$current_branch"
  local_branch_deleted="yes"
fi

printf '\nMerged PR #%s with squash merge.\n' "$pr_number"
printf 'Reviewed candidate: %s\n' "$local_head_sha"
if [ "$remote_main_state" = advanced ]; then
  printf 'Merged commit:             %s\n' "$merged_sha"
  printf 'Candidate-equivalent tree: %s\n' "$merged_tree"
  printf 'Pull request checks:       PASS\n'
  printf 'Remote main now:           %s  (not candidate-checked by this run)\n' "$remote_main_sha"
  printf 'Local main left at:        %s\n' "$merged_sha"
else
  printf 'Merged commit:             %s\n' "$merged_sha"
  printf 'Candidate-equivalent tree: %s\n' "$merged_tree"
  printf 'Pull request checks:       PASS\n'
fi
case "$remote_branch_deleted" in
  yes) printf 'Deleted remote branch: %s\n' "$current_branch" ;;
  absent) printf 'Remote branch already absent: %s\n' "$current_branch" ;;
  no) printf 'Retained remote branch: %s\n' "$current_branch" ;;
esac
if [ "$local_branch_deleted" = yes ]; then
  printf 'Deleted local branch: %s\n' "$current_branch"
else
  printf 'Retained local branch: %s\n' "$current_branch"
fi
if [ "$cleanup_failed" -ne 0 ]; then
  printf 'Merge verified; optional cleanup incomplete.\n' >&2
fi
