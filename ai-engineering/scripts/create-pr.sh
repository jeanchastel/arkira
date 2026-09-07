#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: create-pr.sh [--base <branch>] [--supersedes <PR-number>]... [--no-auto-merge] [--verify-staged] [--high-assurance <evidence options>]' \
    '' \
    'Create a pull request from the current branch after validating the exact candidate.' \
    '' \
    'Options:' \
    '  --base <branch>               Pull request base branch. Defaults to main.' \
    '  --supersedes <PR-number>      Source pull request replaced by this candidate. Repeatable.' \
    '  --no-auto-merge               Leave the created pull request for manual acceptance.' \
    '  --verify-staged               Validate the current staged candidate and exit.' \
    '  --high-assurance              Require the complete high-assurance evidence set.' \
    '  --review-artifact <path>      Review artifact for high-assurance publication.' \
    '  --gate-receipt <path>         Candidate gate receipt for high-assurance publication.' \
    '  --reviewer-evidence <path>    Reviewer evidence for high-assurance publication.' \
    '  --judge-evidence <path>       Judge evidence for high-assurance publication.' \
    '  --allowed-signers <path>      Allowed signers file for high-assurance publication.' \
    '  --release-archive <path>      Release archive when repository policy requires it.' \
    '  --release-provenance <path>   Release provenance when repository policy requires it.' \
    '  -h, --help                    Show this help and exit.'
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

review_artifact=""
gate_receipt=""
reviewer_evidence=""
judge_evidence=""
allowed_signers=""
release_archive=""
release_provenance=""
high_assurance=0
verify_staged=0
auto_merge=1
selected_base=main
supersedes=()
supersedes_count=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ "$#" -ge 2 ] || die "--base requires a branch."; selected_base="$2"; shift 2 ;;
    --supersedes) [ "$#" -ge 2 ] || die "--supersedes requires a pull request number."; supersedes+=("$2"); supersedes_count=$((supersedes_count + 1)); shift 2 ;;
    --high-assurance) high_assurance=1; shift ;;
    --no-auto-merge) auto_merge=0; shift ;;
    --verify-staged) verify_staged=1; shift ;;
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

if [ "$supersedes_count" -gt 0 ]; then
  for superseded_pr in "${supersedes[@]}"; do
    [[ "$superseded_pr" =~ ^[1-9][0-9]*$ ]] \
      || die "--supersedes requires a positive pull request number."
    duplicate_count=0
    for candidate_pr in "${supersedes[@]}"; do
      [ "$candidate_pr" = "$superseded_pr" ] && duplicate_count=$((duplicate_count + 1))
    done
    [ "$duplicate_count" -eq 1 ] || die "duplicate --supersedes pull request: #$superseded_pr"
  done
fi

command -v gh >/dev/null 2>&1 || die "gh CLI is not installed or not on PATH."
command -v jq >/dev/null 2>&1 || die "jq is required."
git remote get-url origin >/dev/null 2>&1 \
  || die "git remote 'origin' is not configured."

repo_root="$(git rev-parse --show-toplevel)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
validator="$script_dir/validate-review-artifact.sh"
provenance_verifier="$repo_root/scripts/release-provenance.sh"
config="$repo_root/.arkira/config.json"
plugin_manifest="$repo_root/.claude-plugin/plugin.json"
if [ -f "$plugin_manifest" ] && [ ! -L "$plugin_manifest" ] \
  && [ "$(jq -r '.name // empty' "$plugin_manifest" 2>/dev/null || true)" = arkira ]; then
  auto_merge=0
fi

resolve_candidate_gate() {
  local central_status
  if [[ -f "$script_dir/publication-harness.sh" && ! -L "$script_dir/publication-harness.sh" ]]; then
    . "$script_dir/publication-harness.sh"
    if candidate_gate="$(arkira_publication_central_gate "$config" "$script_dir")"; then
      return
    else
      central_status=$?
      [[ "$central_status" -eq 4 ]] || exit "$central_status"
    fi
  elif jq -e '(.harness.channel == "stable" and
    .harness.repository == "jeanchastel/arkira")' "$config" >/dev/null 2>&1; then
    die 'public publication resolver is missing or unsafe'
  fi
  candidate_gate="$repo_root/ai-engineering/runtime/candidate-gate.sh"
  [ -f "$candidate_gate" ] && [ ! -L "$candidate_gate" ] && [ -r "$candidate_gate" ] \
    || die "candidate gate is missing or unsafe: $candidate_gate"
}

run_candidate_gate() {
  local gate_command=$1
  shift
  /bin/bash "$candidate_gate" "$gate_command" --repo "$repo_root" "$@"
}

if [ "$verify_staged" -eq 1 ]; then
  [ "$high_assurance" -eq 0 ] || die '--verify-staged cannot use --high-assurance'
  resolve_candidate_gate
  run_candidate_gate require-staged
  exit 0
fi

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

current_branch="$(git branch --show-current)"
[ -n "$current_branch" ] \
  || die "cannot create a PR from a detached HEAD; check out the branch first."
[ "$current_branch" != "$selected_base" ] \
  || die "refusing to create a PR from the selected base branch '$selected_base'; check out a feature branch first."
[ -z "$(git status --porcelain=v1)" ] \
  || die "working tree is dirty; commit or discard changes before creating a PR."

local_branch_sha="$(git rev-parse HEAD)"
existing_pr_count="$(gh pr list --head "$current_branch" --state all --json number --jq 'length')"
retry_pr_url=""
if [ "$existing_pr_count" != 0 ]; then
  [ "$auto_merge" -eq 1 ] \
    || die "a PR already exists for branch '$current_branch'; manual-acceptance publication does not alter it."
  [ "$supersedes_count" -gt 0 ] \
    || die "a PR already exists for branch '$current_branch'; refusing to create a duplicate."
  retry_pr_url="$(gh pr list --head "$current_branch" --state open --json url --jq 'if length == 1 then .[0].url else empty end')"
  [ -n "$retry_pr_url" ] \
    || die "a PR already exists for branch '$current_branch', but no unique open replacement can resume supersession."
fi
resolve_candidate_gate
publication_base="$(run_candidate_gate publication-base --base-branch "$selected_base")" \
  || exit $?
read -r base_branch base_sha extra_base_field <<< "$publication_base"
[ -n "$base_branch" ] && [ -n "$base_sha" ] && [ -z "$extra_base_field" ] \
  || die "publication base resolver returned malformed output."
base_provenance_type="$(git cat-file -t "$base_sha:scripts/release-provenance.sh" 2>/dev/null || true)"
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

validate_candidate_evidence() {
  if [ "$high_assurance" -ne 1 ]; then
    publication_routing="$(run_candidate_gate publication-routing \
      --base-branch "$base_branch" --base "$base_sha")" || exit $?
    jq -e '
      (keys_unsorted | sort) == (["final_tier","floor_source","policy_digest"] | sort) and
      (.final_tier == "quick" or .final_tier == "normal" or .final_tier == "elevated") and
      (.floor_source | type == "string" and length > 0) and
      (.policy_digest | type == "string" and test("^[a-f0-9]{64}$"))
    ' <<< "$publication_routing" >/dev/null 2>&1 \
      || die "candidate publication routing is malformed."
    publication_tier="$(jq -r '.final_tier' <<< "$publication_routing")"
    return
  fi
  publication_tier=elevated
  /bin/bash "$validator" --repo "$repo_root" \
    --artifact "$review_artifact" --gate-receipt "$gate_receipt" \
    --reviewer-evidence "$reviewer_evidence" --judge-evidence "$judge_evidence" \
    --allowed-signers "$allowed_signers" \
    || die "review artifact validation failed."
  if [ -f "$provenance_verifier" ] && [ ! -L "$provenance_verifier" ]; then
    /bin/bash "$provenance_verifier" verify --repo "$repo_root" \
      --candidate "$local_branch_sha" --archive "$release_archive" \
      --provenance "$release_provenance" \
      || die "release archive or provenance validation failed."
  fi
}

validate_candidate_evidence
if [ "$high_assurance" -eq 1 ]; then
  artifact_base="$(jq -r '.base_sha' "$review_artifact")"
  [ "$artifact_base" = "$base_sha" ] \
    || die "review artifact base does not match current remote $base_branch."
  artifact_candidate="$(jq -r '.candidate_sha' "$review_artifact")"
  [ "$artifact_candidate" = "$local_branch_sha" ] \
    || die "review artifact candidate does not match local HEAD."
fi

ahead_count="$(git rev-list --count "$base_sha"..HEAD)"
[ "$ahead_count" != 0 ] || die "current branch has no commits ahead of origin/$base_branch."

superseded_urls=()
superseded_states=()
validate_superseded_sources() {
  local allow_closed=${1:-0} source_pr source_json source_number source_state source_base
  local source_head source_repo source_url current_repo
  current_repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" \
    || die "could not resolve the current GitHub repository."
  [ -n "$current_repo" ] || die "current GitHub repository is empty."
  superseded_urls=()
  superseded_states=()
  for source_pr in "${supersedes[@]}"; do
    source_json="$(gh pr view "$source_pr" --json number,state,baseRefName,headRefName,headRepository,url)" \
      || die "could not read superseded pull request #$source_pr."
    source_number="$(jq -r '.number // empty' <<< "$source_json")"
    source_state="$(jq -r '.state // empty' <<< "$source_json")"
    source_base="$(jq -r '.baseRefName // empty' <<< "$source_json")"
    source_head="$(jq -r '.headRefName // empty' <<< "$source_json")"
    source_repo="$(jq -r '.headRepository.nameWithOwner // empty' <<< "$source_json")"
    source_url="$(jq -r '.url // empty' <<< "$source_json")"
    [ "$source_number" = "$source_pr" ] && [ -n "$source_url" ] \
      || die "superseded pull request #$source_pr returned malformed metadata."
    if [ "$allow_closed" -eq 1 ]; then
      [ "$source_state" = OPEN ] || [ "$source_state" = CLOSED ] \
        || die "superseded pull request #$source_pr is not open or already closed."
    else
      [ "$source_state" = OPEN ] \
        || die "superseded pull request #$source_pr must be open before replacement publication."
    fi
    [ "$source_base" = "$base_branch" ] \
      || die "superseded pull request #$source_pr targets '$source_base', not '$base_branch'."
    [ "$source_repo" = "$current_repo" ] \
      || die "superseded pull request #$source_pr is not from the current repository."
    [ "$source_head" != "$current_branch" ] \
      || die "superseded pull request #$source_pr uses the replacement branch."
    superseded_urls+=("$source_url")
    superseded_states+=("$source_state")
  done
}

close_superseded_sources() {
  local replacement_url=$1 close_failed=0 index source_pr
  for index in "${!supersedes[@]}"; do
    source_pr="${supersedes[$index]}"
    [ "${superseded_states[$index]}" = CLOSED ] && continue
    gh pr close "$source_pr" --comment "Superseded by $replacement_url." \
      || close_failed=1
  done
  [ "$close_failed" -eq 0 ] \
    || die "replacement auto-merge is armed, but one or more source pull requests could not be closed; rerun this command to retry."
}

if [ "$supersedes_count" -gt 0 ]; then
  if [ -n "$retry_pr_url" ]; then
    validate_superseded_sources 1
    retry_state="$(gh pr view "$retry_pr_url" --json headRefOid,baseRefName,baseRefOid,autoMergeRequest,body)" \
      || die "could not read the existing replacement pull request."
    retry_head="$(jq -r '.headRefOid // empty' <<< "$retry_state")"
    retry_base_branch="$(jq -r '.baseRefName // empty' <<< "$retry_state")"
    retry_base_sha="$(jq -r '.baseRefOid // empty' <<< "$retry_state")"
    [ "$retry_head" = "$local_branch_sha" ] \
      && [ "$retry_base_branch" = "$base_branch" ] && [ "$retry_base_sha" = "$base_sha" ] \
      || die "existing replacement pull request no longer matches the certified candidate."
    jq -e '.autoMergeRequest != null' <<< "$retry_state" >/dev/null 2>&1 \
      || die "existing replacement pull request does not have auto-merge armed."
    retry_body="$(jq -r '.body // ""' <<< "$retry_state")"
    recorded_supersedes="$(sed -nE 's/^<!-- ARKIRA:SUPERSEDES #([1-9][0-9]*) (https:\/\/[^ ]+) -->$/\1\t\2/p' \
      <<< "$retry_body" | sort)"
    expected_supersedes="$({
      for source_index in "${!supersedes[@]}"; do
        printf '%s\t%s\n' "${supersedes[$source_index]}" "${superseded_urls[$source_index]}"
      done
    } | sort)"
    [ "$recorded_supersedes" = "$expected_supersedes" ] \
      || die "retry source set does not match the source set recorded on the replacement pull request."
    close_superseded_sources "$retry_pr_url"
    printf 'Resumed PR supersession: %s\n' "$retry_pr_url"
    exit 0
  fi
  validate_superseded_sources 0
fi
remote_branch_sha="$(git ls-remote --heads origin "$current_branch" | awk '{print $1}')"

latest_commit_message="$(git log -1 --pretty=%s)"
changed_files_summary="$(git diff --name-status "$base_sha"...HEAD)"
task_files="$(git diff --name-only "$base_sha"...HEAD -- tasks 2>/dev/null || true)"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
{
  printf '## Summary\n'
  printf -- '- Branch: `%s`\n' "$current_branch"
  printf -- '- Latest commit: `%s`\n' "$latest_commit_message"
  if [ -n "$task_files" ]; then
    printf -- '- Remediation task file(s):\n'
    while IFS= read -r task_file; do
      [ -n "$task_file" ] && printf '  - `%s`\n' "$task_file"
    done <<< "$task_files"
  else
    printf -- '- Remediation task file(s): none detected in this branch diff\n'
  fi
  printf '\n## Changed Files\n'
  if [ -n "$changed_files_summary" ]; then
    printf '```text\n%s\n```\n' "$changed_files_summary"
  else
    printf 'No changed files detected against `origin/%s`.\n' "$base_branch"
  fi
  printf '\n## Validation\n'
  printf -- '- Candidate SHA: `%s`\n' "$local_branch_sha"
  printf -- '- Base branch: `%s`\n' "$base_branch"
  printf -- '- Base SHA: `%s`\n' "$base_sha"
  if [ "$high_assurance" -eq 1 ]; then
    review_author="$(jq -r '.author' "$review_artifact")"
    review_reviewer="$(jq -r '.reviewer' "$review_artifact")"
    review_judge="$(jq -r '.judge.status' "$review_artifact")"
    review_counts="$(jq -r '.findings.counts | "P0=\(.P0) P1=\(.P1) P2=\(.P2) P3=\(.P3)"' "$review_artifact")"
    gate_hash="$(jq -r '.canonical_gate.receipt_sha256' "$review_artifact")"
    printf -- '- Canonical release gate: PASS\n'
    printf -- '- Gate receipt SHA-256: `%s`\n' "$gate_hash"
    if [ -f "$provenance_verifier" ] && [ ! -L "$provenance_verifier" ]; then
      printf -- '- Release archive SHA-256: `%s`\n' "$(sha256_file "$release_archive")"
      printf -- '- Release provenance SHA-256: `%s`\n' "$(sha256_file "$release_provenance")"
    fi
    printf '\n## Cross-Agent Review\n'
    printf -- '- Author agent: %s\n' "$review_author"
    printf -- '- Reviewer agent: %s\n' "$review_reviewer"
    printf -- '- Finding counts: %s\n' "$review_counts"
    printf -- '- Semantic judge: %s\n' "$review_judge"
    printf -- '- Status: high-assurance evidence validated before publication\n'
  else
    printf -- '- Review mode: tier-proportionate host review; high-assurance evidence not requested\n'
  fi
  if [ "$supersedes_count" -gt 0 ]; then
    printf '\n## Supersedes\n'
    for source_index in "${!supersedes[@]}"; do
      printf -- '- #%s: %s\n' "${supersedes[$source_index]}" "${superseded_urls[$source_index]}"
      printf '<!-- ARKIRA:SUPERSEDES #%s %s -->\n' \
        "${supersedes[$source_index]}" "${superseded_urls[$source_index]}"
    done
  fi
} > "$body_file"

[ "$(git rev-parse HEAD)" = "$local_branch_sha" ] \
  && [ -z "$(git status --porcelain=v1)" ] \
  || die "candidate changed after evidence validation; re-run review."
validate_candidate_evidence

if [ -n "$remote_branch_sha" ]; then
  [ "$remote_branch_sha" = "$local_branch_sha" ] || git push origin "$current_branch"
else
  git push -u origin "$current_branch"
fi
published_branch_sha="$(git ls-remote --heads origin "$current_branch" | awk '{print $1}')"
[ "$published_branch_sha" = "$local_branch_sha" ] \
  || die "published branch does not match the reviewed candidate."
publication_base_recheck="$(run_candidate_gate publication-base --base-branch "$base_branch")" \
  || exit $?
read -r rechecked_base_branch rechecked_base_sha extra_base_field <<< "$publication_base_recheck"
[ -z "$extra_base_field" ] && [ "$rechecked_base_branch" = "$base_branch" ] \
  && [ "$rechecked_base_sha" = "$base_sha" ] \
  || die "publication base changed after evidence validation; re-run the gate and review."
[ "$(git rev-parse HEAD)" = "$local_branch_sha" ] \
  && [ -z "$(git status --porcelain=v1)" ] \
  || die "local candidate changed before pull request creation."
validate_candidate_evidence

ensure_full_ci_label() {
  gh label create full-ci --color 1D76DB \
    --description 'Requires complete CI validation.' --force >/dev/null
}

ensure_auto_delivery_label() {
  gh label create arkira-auto-delivery --color 0E8A16 \
    --description 'Arkira-certified candidate tracked for delivery.' --force >/dev/null
}

ensure_auto_delivery_label
pr_labels=(--label arkira-auto-delivery)
if [ "$publication_tier" = elevated ]; then
  ensure_full_ci_label
  pr_labels+=(--label full-ci)
fi
pr_url="$(gh pr create --base "$base_branch" --head "$current_branch" \
  --title "$latest_commit_message" --body-file "$body_file" "${pr_labels[@]}")"
pr_number="$(gh pr view "$pr_url" --json number --jq '.number' 2>/dev/null || true)"
pr_state="$(gh pr view "$pr_url" --json headRefOid,baseRefName,baseRefOid 2>/dev/null || true)"
pr_head="$(jq -r '.headRefOid // empty' <<< "$pr_state" 2>/dev/null || true)"
pr_base_branch="$(jq -r '.baseRefName // empty' <<< "$pr_state" 2>/dev/null || true)"
pr_base_sha="$(jq -r '.baseRefOid // empty' <<< "$pr_state" 2>/dev/null || true)"
[ "$pr_head" = "$local_branch_sha" ] \
  || die 'pull request head does not match the certified candidate; auto-merge was not armed.'
[ "$pr_base_branch" = "$base_branch" ] && [ "$pr_base_sha" = "$base_sha" ] \
  || die 'pull request base moved or was retargeted after certification; auto-merge was not armed.'
if [ "$supersedes_count" -gt 0 ]; then
  for superseded_pr in "${supersedes[@]}"; do
    [ "$superseded_pr" != "$pr_number" ] \
      || die 'replacement pull request cannot supersede itself; auto-merge was not armed.'
  done
fi
final_pr_state="$(gh pr view "$pr_url" --json headRefOid,baseRefName,baseRefOid,labels,body 2>/dev/null || true)"
final_pr_head="$(jq -r '.headRefOid // empty' <<< "$final_pr_state" 2>/dev/null || true)"
final_pr_base_branch="$(jq -r '.baseRefName // empty' <<< "$final_pr_state" 2>/dev/null || true)"
final_pr_base_sha="$(jq -r '.baseRefOid // empty' <<< "$final_pr_state" 2>/dev/null || true)"
final_pr_body="$(jq -r '.body // empty' <<< "$final_pr_state" 2>/dev/null || true)"
[ "$final_pr_head" = "$local_branch_sha" ] \
  && [ "$final_pr_base_branch" = "$base_branch" ] && [ "$final_pr_base_sha" = "$base_sha" ] \
  || die 'pull request identity changed while publishing certified metadata; auto-merge was not armed.'
jq -e '[.labels[]?.name] | index("arkira-auto-delivery")' <<< "$final_pr_state" >/dev/null 2>&1 \
  || die 'pull request delivery label is missing after publication; auto-merge was not armed.'
if [ "$publication_tier" = elevated ]; then
  jq -e '[.labels[]?.name] | index("full-ci")' <<< "$final_pr_state" >/dev/null 2>&1 \
    || die 'pull request full-ci label is missing after publication; auto-merge was not armed.'
fi
grep -Fqx -- "- Candidate SHA: \`$local_branch_sha\`" <<< "$final_pr_body" \
  && grep -Fqx -- "- Base branch: \`$base_branch\`" <<< "$final_pr_body" \
  && grep -Fqx -- "- Base SHA: \`$base_sha\`" <<< "$final_pr_body" \
  || die 'pull request certification metadata is incomplete after publication; auto-merge was not armed.'
if [ "$auto_merge" -eq 1 ]; then
  gh pr merge --auto --squash --match-head-commit "$local_branch_sha" "$pr_url" \
    || die 'pull request was created but GitHub auto-merge could not be armed; resolve the reported GitHub blocker and leave the PR open.'
  if [ "$supersedes_count" -gt 0 ]; then
    close_superseded_sources "$pr_url"
  fi
fi

printf 'Created PR: %s\n' "$pr_url"
printf 'Branch: %s\n' "$current_branch"
if [ -n "$pr_number" ]; then
  printf 'PR number: #%s\n' "$pr_number"
else
  printf 'PR number: unavailable\n'
fi
if [ "$auto_merge" -eq 1 ]; then
  printf 'Auto-merge: armed (squash, exact candidate SHA)\n'
else
  printf 'Auto-merge: not armed; human acceptance is required before merge.\n'
  if [ "$supersedes_count" -gt 0 ]; then
    printf 'Superseded PRs: left open until this replacement is accepted.\n'
  fi
fi
