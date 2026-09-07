#!/usr/bin/env bash
# Build a review index from externally signed, exact-candidate evidence.
set -euo pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
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

file_owner() {
  if stat -f '%u' "$1" >/dev/null 2>&1; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

require_owner_only_file() {
  local path="$1" label="$2" resolved owner mode
  [ -n "$path" ] && [[ "$path" = /* ]] || die "$label path must be absolute"
  [ -f "$path" ] && [ ! -L "$path" ] || die "$label must be a regular non-symlink file"
  resolved="$(realpath -- "$path" 2>/dev/null)" || die "$label cannot be resolved"
  [ "$resolved" = "$path" ] || die "$label path must be canonical"
  case "$resolved" in "$repo"|"$repo"/*) die "$label must live outside the candidate repository" ;; esac
  owner="$(file_owner "$resolved")" || die "$label owner is unavailable"
  [ "$owner" = "$(id -u)" ] || die "$label must be owned by the invoking operator"
  mode="$(file_mode "$resolved")" || die "$label mode is unavailable"
  case "$mode" in 400|600) ;; *) die "$label mode must be 0400 or 0600" ;; esac
}

validate_trust_root() {
  local configured_path configured_sha line_count principal key_line fingerprint expected fingerprints=""
  configured_path="$(jq -r '.allowed_signers.path' "$trust_policy")"
  configured_sha="$(jq -r '.allowed_signers.sha256' "$trust_policy")"
  [ "$allowed_signers" = "$configured_path" ] \
    || die "allowed signers path does not match the operator-pinned trust policy"
  require_owner_only_file "$allowed_signers" "allowed signers trust root"
  [ "$(sha256_file "$allowed_signers")" = "$configured_sha" ] \
    || die "allowed signers fingerprint does not match the operator-pinned trust policy"
  line_count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$allowed_signers")"
  [ "$line_count" -eq 4 ] || die "allowed signers must contain exactly four role principals"
  for principal in release-gate Claude Codex semantic-judge; do
    line_count="$(awk -v principal="$principal" '$1 == principal { count++ } END { print count + 0 }' "$allowed_signers")"
    [ "$line_count" -eq 1 ] || die "allowed signers must contain principal $principal exactly once"
    key_line="$(awk -v principal="$principal" '$1 == principal { print $2 " " $3 }' "$allowed_signers")"
    fingerprint="$(printf '%s\n' "$key_line" | ssh-keygen -lf - -E sha256 2>/dev/null | awk '{print $2}')"
    [ -n "$fingerprint" ] || die "allowed signers key for $principal is invalid"
    expected="$(jq -r --arg principal "$principal" '.principals[$principal]' "$trust_policy")"
    [ "$fingerprint" = "$expected" ] || die "allowed signers key for $principal does not match policy fingerprint"
    fingerprints="$fingerprints$fingerprint\n"
  done
  [ "$(printf '%b' "$fingerprints" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')" -eq 4 ] \
    || die "release-gate, Claude, Codex, and semantic-judge must use distinct public keys"
}

require_pinned_producer() {
  local role="$1" identity="$2" path="$3" digest="$4" count producer_owner producer_mode
  [ -n "$path" ] && [[ "$path" = /* ]] || die "$role producer path must be absolute"
  [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ] \
    || die "$role producer must remain an executable regular non-symlink file"
  [ "$(realpath -- "$path")" = "$path" ] || die "$role producer path must be canonical"
  case "$path" in "$repo"|"$repo"/*) die "$role producer must live outside the candidate repository" ;; esac
  [ "$(sha256_file "$path")" = "$digest" ] || die "$role producer executable changed after evidence production"
  producer_owner="$(file_owner "$path")" || die "$role producer owner is unavailable"
  [ "$producer_owner" = "$(id -u)" ] || die "$role producer must be owned by the invoking operator"
  producer_mode="$(file_mode "$path")" || die "$role producer mode is unavailable"
  if (( (8#$producer_mode & 0022) != 0 )); then
    die "$role producer must not be group- or world-writable"
  fi
  count="$(jq -r --arg role "$role" --arg identity "$identity" --arg path "$path" --arg digest "$digest" '
    [.producers[$role][]? |
      select(.identity == $identity and .path == $path and .sha256 == $digest)] | length
  ' "$trust_policy")"
  [ "$count" -eq 1 ] || die "$role producer is not uniquely approved by the release trust policy"
}

verify_signature() {
  local file="$1" identity="$2" namespace="$3"
  ssh-keygen -Y verify -f "$allowed_signers" -I "$identity" -n "$namespace" \
    -s "$file.sig" < "$file" >/dev/null 2>&1
}

candidate_tool_version() {
  local candidate_sha="$1" version=""
  if git -C "$repo" cat-file -e "$candidate_sha:.claude-plugin/plugin.json" 2>/dev/null; then
    version="$(git -C "$repo" show "$candidate_sha:.claude-plugin/plugin.json" \
      | jq -r '.version // empty')"
  elif git -C "$repo" cat-file -e "$candidate_sha:.arkira/sync-state.json" 2>/dev/null; then
    version="$(git -C "$repo" show "$candidate_sha:.arkira/sync-state.json" \
      | jq -r '.plugin_version // empty')"
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

for signing_var in \
  ARKIRA_GATE_SIGNING_KEY \
  ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY; do
  [ -z "${!signing_var:-}" ] \
    || die "$signing_var must not be passed to candidate-owned artifact code"
done
unset ARKIRA_GATE_SIGNING_KEY ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY SSH_AUTH_SOCK

repo=""
gate_receipt=""
reviewer_evidence=""
judge_evidence=""
allowed_signers=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a path"; repo="$2"; shift 2 ;;
    --gate-receipt) [ "$#" -ge 2 ] || die "--gate-receipt requires a path"; gate_receipt="$2"; shift 2 ;;
    --reviewer-evidence) [ "$#" -ge 2 ] || die "--reviewer-evidence requires a path"; reviewer_evidence="$2"; shift 2 ;;
    --judge-evidence) [ "$#" -ge 2 ] || die "--judge-evidence requires a path"; judge_evidence="$2"; shift 2 ;;
    --allowed-signers) [ "$#" -ge 2 ] || die "--allowed-signers requires a path"; allowed_signers="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || die "--output requires a path"; output="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ] || die "--repo is required"
[ -n "$gate_receipt" ] || die "--gate-receipt is required"
[ -n "$reviewer_evidence" ] || die "--reviewer-evidence is required"
[ -n "$judge_evidence" ] || die "--judge-evidence is required"
[ -n "$allowed_signers" ] || die "--allowed-signers is required"
[ -n "$output" ] || die "--output is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
command -v realpath >/dev/null 2>&1 || die "realpath is required"

repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || die "repository is unavailable"
trust_policy="${ARKIRA_RELEASE_TRUST_POLICY:-}"
trust_policy_pin="${ARKIRA_RELEASE_TRUST_POLICY_SHA256:-}"
hash_re='^[0-9a-f]{64}$'
[[ "$trust_policy_pin" =~ $hash_re ]] \
  || die "ARKIRA_RELEASE_TRUST_POLICY_SHA256 must pin the external trust policy"
require_owner_only_file "$trust_policy" "release trust policy"
[ "$(sha256_file "$trust_policy")" = "$trust_policy_pin" ] \
  || die "release trust policy fingerprint does not match the operator pin"
jq -e '
  . as $root |
  type == "object" and .schema == 1 and
  (.allowed_signers.path | type == "string" and startswith("/")) and
  (.allowed_signers.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.principals | type == "object") and
  (["release-gate","Claude","Codex","semantic-judge"] |
    all(. as $p | ($root.principals[$p] | type == "string" and startswith("SHA256:")))) and
  (.producers.reviewer | type == "array" and length > 0) and
  (.producers.judge | type == "array" and length > 0)
' "$trust_policy" >/dev/null || die "release trust policy is malformed"
validate_trust_root

for evidence in "$gate_receipt" "$reviewer_evidence" "$judge_evidence"; do
  [ -f "$evidence" ] && [ ! -L "$evidence" ] \
    || die "evidence must be a regular non-symlink file: $evidence"
  [ -f "$evidence.sig" ] && [ ! -L "$evidence.sig" ] \
    || die "producer signature is missing or unsafe: $evidence.sig"
done
output_parent="$(dirname -- "$output")"
[ -d "$output_parent" ] && [ ! -L "$output_parent" ] \
  || die "output parent must be an existing non-symlink directory"
output_parent="$(cd -- "$output_parent" && pwd -P)" || die "output parent cannot be resolved"
case "$output_parent" in "$repo"|"$repo"/*) die "review artifact must live outside the candidate repository" ;; esac
output="$output_parent/$(basename -- "$output")"
[ ! -e "$output" ] && [ ! -L "$output" ] || die "refusing to replace an existing review artifact"

reviewer="$(jq -r '.producer.identity // empty' "$reviewer_evidence")"
judge="$(jq -r '.producer.identity // empty' "$judge_evidence")"
[ "$reviewer" = Claude ] || [ "$reviewer" = Codex ] \
  || die "reviewer evidence has an unsupported producer identity"
[ "$judge" = semantic-judge ] || die "judge evidence has an unsupported producer identity"
verify_signature "$gate_receipt" release-gate arkira-release-gate \
  || die "gate receipt producer signature is invalid"
verify_signature "$reviewer_evidence" "$reviewer" arkira-reviewer \
  || die "reviewer producer signature is invalid"
verify_signature "$judge_evidence" semantic-judge arkira-judge \
  || die "judge producer signature is invalid"

candidate="$(jq -r '.candidate_sha // empty' "$gate_receipt")"
base="$(jq -r '.base_sha // empty' "$gate_receipt")"
author="$(jq -r '.author_identity // empty' "$gate_receipt")"
sha_re='^[0-9a-f]{40}$'
[[ "$candidate" =~ $sha_re ]] || die "gate candidate SHA is invalid"
[[ "$base" =~ $sha_re ]] || die "gate base SHA is invalid"
[ "$author" = Claude ] || [ "$author" = Codex ] || die "signed gate author identity is invalid"
[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" = "$candidate" ] \
  || die "gate candidate is stale for repository HEAD"
[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] \
  || die "candidate repository is dirty"
[ "$base" != "$candidate" ] || die "base and candidate SHA must differ"
git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || die "base is not a commit"
git -C "$repo" merge-base --is-ancestor "$base" "$candidate" 2>/dev/null \
  || die "base is not an ancestor of candidate"
[ "$(jq -r '.candidate_sha // empty' "$reviewer_evidence")" = "$candidate" ] \
  && [ "$(jq -r '.base_sha // empty' "$reviewer_evidence")" = "$base" ] \
  || die "reviewer evidence is for a different candidate or base"
[ "$(jq -r '.candidate_sha // empty' "$judge_evidence")" = "$candidate" ] \
  && [ "$(jq -r '.base_sha // empty' "$judge_evidence")" = "$base" ] \
  || die "judge evidence is for a different candidate or base"
[ "$author" != "$reviewer" ] || die "signed author and reviewer identities must be distinct"

jq -e --arg candidate "$candidate" --arg base "$base" --arg author "$author" '
  type == "object" and .schema == 4 and
  .candidate_sha == $candidate and .base_sha == $base and .author_identity == $author and
  .producer.identity == "release-gate" and .result == "PASS" and .scope == "full" and
  (.suite_count | type == "number" and . > 0 and floor == .) and
  .fail == 0 and .required_skips == 0 and
  (.pass + .warn + .skip == .suite_count)
' "$gate_receipt" >/dev/null || die "signed gate receipt is not a clean full PASS"
jq -e '
  . as $root |
  type == "object" and .schema == 3 and .result == "PASS" and
  (.findings.counts | type == "object") and
  (["P0","P1","P2","P3"] | all(. as $s |
    ($root.findings.counts[$s] | type == "number" and . >= 0 and floor == .))) and
  (.findings.items | type == "array") and
  ([.findings.items[].id] | length == (unique | length)) and
  (["P0","P1","P2","P3"] | all(. as $s |
    ($root.findings.counts[$s] == ([$root.findings.items[] | select(.severity == $s)] | length)))) and
  (.findings.unresolved | type == "array")
' "$reviewer_evidence" >/dev/null || die "signed reviewer evidence is malformed or not a PASS"
[ "$(jq -r '.findings.counts.P0' "$reviewer_evidence")" -eq 0 ] \
  && [ "$(jq -r '.findings.counts.P1' "$reviewer_evidence")" -eq 0 ] \
  || die "signed reviewer evidence reports P0 or P1 findings"
if jq -e '.findings.unresolved[]? | select(.severity == "P0" or .severity == "P1")' \
  "$reviewer_evidence" >/dev/null; then
  die "signed reviewer evidence has unresolved P0 or P1 findings"
fi
jq -e '
  type == "object" and .schema == 3 and .result == "PASS" and
  .producer.identity == "semantic-judge" and
  .finding_confidence_eval.result == "PASS" and
  .finding_confidence_eval.score == 100
' "$judge_evidence" >/dev/null || die "signed judge evidence is malformed or not a PASS"

reviewer_path="$(jq -r '.producer.executable // empty' "$reviewer_evidence")"
reviewer_executable_sha="$(jq -r '.producer.executable_sha256 // empty' "$reviewer_evidence")"
judge_path="$(jq -r '.producer.executable // empty' "$judge_evidence")"
judge_executable_sha="$(jq -r '.producer.executable_sha256 // empty' "$judge_evidence")"
require_pinned_producer reviewer "$reviewer" "$reviewer_path" "$reviewer_executable_sha"
require_pinned_producer judge semantic-judge "$judge_path" "$judge_executable_sha"

gate_sha="$(sha256_file "$gate_receipt")"
gate_signature_sha="$(sha256_file "$gate_receipt.sig")"
reviewer_sha="$(sha256_file "$reviewer_evidence")"
reviewer_signature_sha="$(sha256_file "$reviewer_evidence.sig")"
judge_sha="$(sha256_file "$judge_evidence")"
judge_signature_sha="$(sha256_file "$judge_evidence.sig")"
[ "$(jq -r '.reviewer_evidence_sha256 // empty' "$judge_evidence")" = "$reviewer_sha" ] \
  || die "judge is not bound to the reviewer evidence"
[ "$(jq -r '.reviewer_signature_sha256 // empty' "$judge_evidence")" = "$reviewer_signature_sha" ] \
  || die "judge is not bound to the reviewer signature"

eval_path="$(jq -r '.finding_confidence_eval.path // empty' "$judge_evidence")"
[ -f "$eval_path" ] && [ ! -L "$eval_path" ] \
  || die "signed finding-confidence eval artifact is unavailable"
eval_path="$(realpath -- "$eval_path")" || die "finding-confidence eval artifact cannot be resolved"
case "$eval_path" in "$repo"|"$repo"/*) die "finding-confidence eval artifact must live outside the candidate repository" ;; esac
eval_sha="$(sha256_file "$eval_path")"
[ "$eval_sha" = "$(jq -r '.finding_confidence_eval.sha256 // empty' "$judge_evidence")" ] \
  || die "finding-confidence eval artifact does not match signed judge evidence"
tmp="$(mktemp -d "$output_parent/.arkira-review-artifact.XXXXXX")" \
  || die "could not create review artifact staging directory"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
rubric_file="$tmp/review-pass-rubric.json"
git -C "$repo" show "$candidate:ai-engineering/workflows/evals/review-pass-rubric.json" \
  > "$rubric_file" || die "candidate finding-confidence rubric is unavailable"
rubric_sha="$(sha256_file "$rubric_file")"
jq -e --arg candidate "$candidate" --arg base "$base" \
  --arg reviewer_sha "$reviewer_sha" --arg reviewer_signature_sha "$reviewer_signature_sha" \
  --arg rubric_sha "$rubric_sha" '
    . as $root |
    type == "object" and .schema == 1 and
    .eval_id == "review-pass-finding-confidence" and
    .candidate_sha == $candidate and .base_sha == $base and
    .reviewer_evidence_sha256 == $reviewer_sha and
    .reviewer_signature_sha256 == $reviewer_signature_sha and
    .rubric_sha256 == $rubric_sha and .result == "PASS" and .score == 100 and
    (.finding_verdicts | type == "array") and
    ([.finding_verdicts[].id] | length == (unique | length)) and
    ([.finding_verdicts[] | select(
      (.id | type == "string" and length > 0) and .real == true and
      (.confidence | type == "number" and . >= 2 and . <= 3 and floor == .) and
      (.evidence | type == "string" and length > 0)
    )] | length == ($root.finding_verdicts | length))
  ' "$eval_path" >/dev/null || die "finding-confidence eval artifact is malformed, stale, or not a PASS"
reviewer_ids="$(jq -c '[.findings.items[].id] | sort' "$reviewer_evidence")"
eval_ids="$(jq -c '[.finding_verdicts[].id] | sort' "$eval_path")"
[ "$reviewer_ids" = "$eval_ids" ] || die "finding-confidence eval does not cover every reviewer finding"
eval_count="$(jq -r '.finding_verdicts | length' "$eval_path")"
[ "$eval_count" = "$(jq -r '.finding_confidence_eval.evidence_count // -1' "$judge_evidence")" ] \
  && [ "$(jq -r '.finding_confidence_eval.result // empty' "$judge_evidence")" = PASS ] \
  && [ "$(jq -r '.finding_confidence_eval.score // -1' "$judge_evidence")" -eq 100 ] \
  && [ "$(jq -r '.finding_confidence_eval.rubric_sha256 // empty' "$judge_evidence")" = "$rubric_sha" ] \
  || die "judge evidence has an incomplete finding-confidence eval binding"

version="$(candidate_tool_version "$candidate")" \
  || die "candidate harness version is unavailable"
trust_policy_sha="$(sha256_file "$trust_policy")"
trust_root_sha="$(sha256_file "$allowed_signers")"
artifact_tmp="$tmp/review.json"
jq -n --slurpfile gate "$gate_receipt" --slurpfile review "$reviewer_evidence" \
  --slurpfile judge "$judge_evidence" \
  --arg gate_sha "$gate_sha" --arg gate_signature_sha "$gate_signature_sha" \
  --arg reviewer_sha "$reviewer_sha" --arg reviewer_signature_sha "$reviewer_signature_sha" \
  --arg judge_sha "$judge_sha" --arg judge_signature_sha "$judge_signature_sha" \
  --arg eval_sha "$eval_sha" --arg rubric_sha "$rubric_sha" --argjson eval_count "$eval_count" \
  --arg trust_policy_sha "$trust_policy_sha" --arg trust_root_sha "$trust_root_sha" \
  --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg version "$version" '
    {schema:4,candidate_sha:$gate[0].candidate_sha,base_sha:$gate[0].base_sha,
     author:$gate[0].author_identity,reviewer:$review[0].producer.identity,
     canonical_gate:{result:$gate[0].result,receipt_sha256:$gate_sha,
       signature_sha256:$gate_signature_sha,inventory_sha256:$gate[0].inventory_sha256,
       required_skips:$gate[0].required_skips,failures:$gate[0].fail},
     reviewer_evidence:{sha256:$reviewer_sha,signature_sha256:$reviewer_signature_sha,
       producer_identity:$review[0].producer.identity,
       executable:$review[0].producer.executable,
       executable_sha256:$review[0].producer.executable_sha256},
     findings:$review[0].findings,
     judge:{status:$judge[0].result,tool_version:$judge[0].tool_version,
       evidence_sha256:$judge_sha,signature_sha256:$judge_signature_sha,
       producer_identity:$judge[0].producer.identity,
       executable:$judge[0].producer.executable,
       executable_sha256:$judge[0].producer.executable_sha256,
       finding_confidence_eval:{result:"PASS",score:100,sha256:$eval_sha,
         rubric_sha256:$rubric_sha,evidence_count:$eval_count}},
     trust:{policy_sha256:$trust_policy_sha,allowed_signers_sha256:$trust_root_sha},
     timestamp:$timestamp,tool_version:$version}
  ' > "$artifact_tmp"
mv "$artifact_tmp" "$output" || die "could not publish review artifact"
printf 'Built signed-evidence review artifact: %s\n' "$output"
