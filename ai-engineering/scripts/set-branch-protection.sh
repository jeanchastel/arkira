#!/usr/bin/env bash
# Configure classic GitHub branch protection deliberately. --dry-run is safe.
set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { cat >&2 <<'EOF'
Usage: set-branch-protection.sh --repo <owner/name> [--branch <name>] (--preset <standards|product> | --check <name> ...) (--dry-run|--apply)

Writes classic branch protection and enables repository auto-merge. --dry-run
prints the exact composite payload and does not call GitHub. --apply writes it,
then reads both settings back.
EOF
}

repo="" branch="main" preset="" action=""; checks=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --branch) branch=${2:-}; shift 2 ;;
    --preset) preset=${2:-}; shift 2 ;;
    --check) checks+=("${2:-}"); shift 2 ;;
    --dry-run|--apply) [[ -z "$action" ]] || die 'choose one of --dry-run or --apply'; action=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || { usage; die '--repo is required'; }
[[ -n "$preset" || ${#checks[@]} -gt 0 ]] || { usage; die '--preset or at least one --check is required'; }
[[ -n "$action" ]] || { usage; die '--dry-run or --apply is required'; }
command -v jq >/dev/null 2>&1 || die 'jq is not installed or not on PATH.'

case "$preset" in
  '') ;;
  standards)
    preset_checks=(candidate-gate fast-checks remote-verify arkira-delivery-authorization)
    checks=("${preset_checks[@]}" "${checks[@]}") ;;
  product) checks=(validate arkira-delivery-authorization "${checks[@]}") ;;
  *) usage; die '--preset must be one of: standards, product' ;;
esac

contexts_json="$(printf '%s\n' "${checks[@]}" | jq -R . | jq -cs .)"
branch_payload="$(jq -n --argjson contexts "$contexts_json" '{required_pull_request_reviews:{required_approving_review_count:0},required_status_checks:{strict:true,contexts:$contexts},required_conversation_resolution:true,allow_force_pushes:false,allow_deletions:false,enforce_admins:true,restrictions:null}')"
payload="$(jq -n --argjson branch_protection "$branch_payload" '{branch_protection:$branch_protection,repository:{allow_auto_merge:true}}')"
if [[ "$action" == --dry-run ]]; then printf '%s\n' "$payload"; exit 0; fi

command -v gh >/dev/null 2>&1 || die 'gh CLI is not installed or not on PATH.'
gh auth status >/dev/null 2>&1 || die 'gh is not authenticated; run gh auth login.'
endpoint="repos/$repo/branches/$branch/protection"
printf '%s\n' "$branch_payload" | gh api -X PUT "$endpoint" --input - || die "failed to set classic branch protection on $repo:$branch"
gh api -X PATCH "repos/$repo" -f allow_auto_merge=true >/dev/null \
  || die "failed to enable GitHub auto-merge on $repo"
auto_merge_readback="$(gh api "repos/$repo" --jq '.allow_auto_merge')" \
  || die "failed to read back GitHub auto-merge setting on $repo"
[[ "$auto_merge_readback" == true ]] || die "GitHub auto-merge read-back is not enabled on $repo"
readback="$(gh api "$endpoint")" || die "failed to read back classic branch protection on $repo:$branch"
relevant_filter='{
  required_pull_request_reviews:{required_approving_review_count:(.required_pull_request_reviews.required_approving_review_count // null)},
  required_status_checks:{strict:(.required_status_checks.strict // null),contexts:((.required_status_checks.contexts // null) | if type == "array" then sort else . end)},
  required_conversation_resolution:(.required_conversation_resolution | if type == "object" then .enabled else . end),
  allow_force_pushes:(.allow_force_pushes | if type == "object" then .enabled else . end),
  allow_deletions:(.allow_deletions | if type == "object" then .enabled else . end),
  enforce_admins:(.enforce_admins | if type == "object" then .enabled else . end),
  restrictions:(.restrictions // null)
}'
sent_relevant="$(jq -c "$relevant_filter" <<< "$branch_payload")" || die 'could not normalize protection payload'
read_relevant="$(jq -c "$relevant_filter" <<< "$readback")" || die 'could not normalize classic branch protection read-back'
[[ "$sent_relevant" == "$read_relevant" ]] || die 'classic branch protection read-back differs from the payload sent'
printf 'Done. Classic branch protection and GitHub auto-merge verified on %s:%s\n' "$repo" "$branch"
