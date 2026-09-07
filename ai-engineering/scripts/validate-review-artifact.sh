#!/usr/bin/env bash
# Validate role-signed release evidence against one exact committed candidate.
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

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
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
    || die "$signing_var must not be passed to candidate-owned validation code"
done
unset ARKIRA_GATE_SIGNING_KEY ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY SSH_AUTH_SOCK

repo=""
artifact=""
gate_receipt=""
reviewer_evidence=""
judge_evidence=""
allowed_signers=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a path"; repo="$2"; shift 2 ;;
    --artifact) [ "$#" -ge 2 ] || die "--artifact requires a path"; artifact="$2"; shift 2 ;;
    --gate-receipt) [ "$#" -ge 2 ] || die "--gate-receipt requires a path"; gate_receipt="$2"; shift 2 ;;
    --reviewer-evidence) [ "$#" -ge 2 ] || die "--reviewer-evidence requires a path"; reviewer_evidence="$2"; shift 2 ;;
    --judge-evidence) [ "$#" -ge 2 ] || die "--judge-evidence requires a path"; judge_evidence="$2"; shift 2 ;;
    --allowed-signers) [ "$#" -ge 2 ] || die "--allowed-signers requires a path"; allowed_signers="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ] || die "--repo is required"
[ -n "$artifact" ] || die "--artifact is required"
[ -n "$gate_receipt" ] || die "--gate-receipt is required"
[ -n "$reviewer_evidence" ] || die "--reviewer-evidence is required"
[ -n "$judge_evidence" ] || die "--judge-evidence is required"
[ -n "$allowed_signers" ] || die "--allowed-signers is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
command -v realpath >/dev/null 2>&1 || die "realpath is required"

repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || die "repository is unavailable"
trust_policy="${ARKIRA_RELEASE_TRUST_POLICY:-}"
trust_policy_pin="${ARKIRA_RELEASE_TRUST_POLICY_SHA256:-}"
sha_re='^[0-9a-f]{40}$'
hash_re='^[0-9a-f]{64}$'
timestamp_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
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

[ -f "$artifact" ] && [ ! -L "$artifact" ] \
  || die "review artifact must be a regular non-symlink file"
for evidence in "$gate_receipt" "$reviewer_evidence" "$judge_evidence"; do
  [ -f "$evidence" ] && [ ! -L "$evidence" ] \
    || die "evidence must be a regular non-symlink file: $evidence"
  [ -f "$evidence.sig" ] && [ ! -L "$evidence.sig" ] \
    || die "evidence signature is missing or unsafe: $evidence.sig"
done

head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || die "cannot resolve candidate HEAD"
[[ "$head_sha" =~ $sha_re ]] || die "candidate HEAD is not an exact SHA"
[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] \
  || die "candidate repository is dirty"

jq -e --arg timestamp_re "$timestamp_re" --arg hash_re "$hash_re" '
  . as $root |
  type == "object" and .schema == 4 and
  (.candidate_sha | type == "string") and (.base_sha | type == "string") and
  (.author == "Claude" or .author == "Codex") and
  (.reviewer == "Claude" or .reviewer == "Codex") and
  (.canonical_gate.result == "PASS") and
  (.canonical_gate.receipt_sha256 | test($hash_re)) and
  (.canonical_gate.signature_sha256 | test($hash_re)) and
  (.canonical_gate.inventory_sha256 | test($hash_re)) and
  .canonical_gate.required_skips == 0 and .canonical_gate.failures == 0 and
  (.reviewer_evidence.sha256 | test($hash_re)) and
  (.reviewer_evidence.signature_sha256 | test($hash_re)) and
  (.reviewer_evidence.executable | type == "string" and startswith("/")) and
  (.reviewer_evidence.executable_sha256 | test($hash_re)) and
  (.findings.counts | type == "object") and
  (["P0","P1","P2","P3"] | all(. as $s |
    ($root.findings.counts[$s] | type == "number" and . >= 0 and floor == .))) and
  (.findings.items | type == "array") and
  (.findings.unresolved | type == "array") and
  .judge.status == "PASS" and
  (.judge.tool_version | type == "string" and length > 0) and
  (.judge.evidence_sha256 | test($hash_re)) and
  (.judge.signature_sha256 | test($hash_re)) and
  (.judge.executable | type == "string" and startswith("/")) and
  (.judge.executable_sha256 | test($hash_re)) and
  .judge.finding_confidence_eval.result == "PASS" and
  .judge.finding_confidence_eval.score == 100 and
  (.judge.finding_confidence_eval.sha256 | test($hash_re)) and
  (.judge.finding_confidence_eval.rubric_sha256 | test($hash_re)) and
  (.judge.finding_confidence_eval.evidence_count | type == "number" and . >= 0 and floor == .) and
  (.trust.policy_sha256 | test($hash_re)) and
  (.trust.allowed_signers_sha256 | test($hash_re)) and
  (.timestamp | test($timestamp_re)) and
  (.tool_version | type == "string" and length > 0)
' "$artifact" >/dev/null 2>&1 || die "review artifact is malformed or incomplete"

candidate="$(jq -r '.candidate_sha' "$artifact")"
base="$(jq -r '.base_sha' "$artifact")"
author="$(jq -r '.author' "$artifact")"
reviewer="$(jq -r '.reviewer' "$artifact")"
[[ "$candidate" =~ $sha_re ]] || die "artifact candidate SHA is invalid"
[[ "$base" =~ $sha_re ]] || die "artifact base SHA is invalid"
[ "$candidate" = "$head_sha" ] || die "review artifact is stale for current HEAD"
[ "$author" != "$reviewer" ] || die "signed author and reviewer identities must be distinct"
[ "$base" != "$candidate" ] || die "base and candidate SHA must differ"
git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || die "base SHA is not a commit"
git -C "$repo" merge-base --is-ancestor "$base" "$candidate" 2>/dev/null \
  || die "base is not an ancestor of candidate"

gate_identity="$(jq -r '.producer.identity // empty' "$gate_receipt")"
gate_author="$(jq -r '.author_identity // empty' "$gate_receipt")"
review_identity="$(jq -r '.producer.identity // empty' "$reviewer_evidence")"
judge_identity="$(jq -r '.producer.identity // empty' "$judge_evidence")"
[ "$gate_identity" = release-gate ] || die "gate producer identity is invalid"
[ "$gate_author" = "$author" ] || die "artifact author does not match signed gate author evidence"
[ "$review_identity" = "$reviewer" ] || die "reviewer label does not match signed producer"
[ "$judge_identity" = semantic-judge ] || die "judge producer identity is invalid"
verify_signature "$gate_receipt" release-gate arkira-release-gate \
  || die "gate receipt producer signature is invalid"
verify_signature "$reviewer_evidence" "$reviewer" arkira-reviewer \
  || die "reviewer producer signature is invalid"
verify_signature "$judge_evidence" semantic-judge arkira-judge \
  || die "judge producer signature is invalid"

jq -e --arg candidate "$candidate" --arg base "$base" --arg author "$author" \
  --arg timestamp_re "$timestamp_re" --arg hash_re "$hash_re" '
  type == "object" and .schema == 4 and
  .candidate_sha == $candidate and .base_sha == $base and .author_identity == $author and
  .producer.identity == "release-gate" and
  (.producer.script_sha256 | test($hash_re)) and
  .result == "PASS" and .scope == "full" and
  (.suite_count | type == "number" and . > 0 and floor == .) and
  .fail == 0 and .required_skips == 0 and
  (.pass + .warn + .skip == .suite_count) and
  (.inventory_sha256 | test($hash_re)) and
  (.timestamp | test($timestamp_re)) and
  (.tool_version | type == "string" and length > 0)
' "$gate_receipt" >/dev/null 2>&1 || die "gate receipt is malformed, stale, or not a clean PASS"

jq -e --arg candidate "$candidate" --arg base "$base" --arg reviewer "$reviewer" \
  --arg timestamp_re "$timestamp_re" --arg hash_re "$hash_re" '
  . as $root |
  type == "object" and .schema == 3 and
  .candidate_sha == $candidate and .base_sha == $base and
  .producer.identity == $reviewer and
  (.producer.model | type == "string" and test("^(claude|codex)$")) and
  (.producer.executable | type == "string" and startswith("/")) and
  (.producer.executable_sha256 | test($hash_re)) and
  (.producer.invocation_sha256 | test($hash_re)) and
  .result == "PASS" and
  (.findings.counts | type == "object") and
  (["P0","P1","P2","P3"] | all(. as $s |
    ($root.findings.counts[$s] | type == "number" and . >= 0 and floor == .))) and
  (.findings.items | type == "array") and
  ([.findings.items[].id] | length == (unique | length)) and
  ([.findings.items[] | select(
    (.id | type == "string" and length > 0) and
    (.severity | type == "string" and test("^P[0-3]$")) and
    (.evidence.file | type == "string" and length > 0) and
    (.evidence.line | type == "number" and . > 0 and floor == .) and
    (.evidence.observation | type == "string" and length > 0)
  )] | length == ($root.findings.items | length)) and
  (["P0","P1","P2","P3"] | all(. as $s |
    ($root.findings.counts[$s] == ([$root.findings.items[] | select(.severity == $s)] | length)))) and
  (.findings.unresolved | type == "array") and
  ([.findings.unresolved[].id] - [.findings.items[].id] | length == 0) and
  (.timestamp | test($timestamp_re)) and
  (.tool_version | type == "string" and length > 0)
' "$reviewer_evidence" >/dev/null 2>&1 \
  || die "reviewer producer evidence is malformed, stale, or not a PASS"

reviewer_sha="$(sha256_file "$reviewer_evidence")"
reviewer_signature_sha="$(sha256_file "$reviewer_evidence.sig")"
jq -e --arg candidate "$candidate" --arg base "$base" \
  --arg reviewer_sha "$reviewer_sha" --arg reviewer_signature_sha "$reviewer_signature_sha" \
  --arg timestamp_re "$timestamp_re" --arg hash_re "$hash_re" '
  type == "object" and .schema == 3 and
  .candidate_sha == $candidate and .base_sha == $base and
  .producer.identity == "semantic-judge" and
  (.producer.executable | type == "string" and startswith("/")) and
  (.producer.executable_sha256 | test($hash_re)) and
  (.producer.invocation_sha256 | test($hash_re)) and
  .result == "PASS" and
  .reviewer_evidence_sha256 == $reviewer_sha and
  .reviewer_signature_sha256 == $reviewer_signature_sha and
  .finding_confidence_eval.result == "PASS" and
  .finding_confidence_eval.score == 100 and
  (.finding_confidence_eval.path | type == "string" and startswith("/")) and
  (.finding_confidence_eval.sha256 | test($hash_re)) and
  (.finding_confidence_eval.rubric_sha256 | test($hash_re)) and
  (.finding_confidence_eval.evidence_count | type == "number" and . >= 0 and floor == .) and
  (.timestamp | test($timestamp_re)) and
  (.tool_version | type == "string" and length > 0)
' "$judge_evidence" >/dev/null 2>&1 \
  || die "semantic judge producer evidence is malformed, stale, or not a PASS"

reviewer_path="$(jq -r '.producer.executable' "$reviewer_evidence")"
reviewer_executable_sha="$(jq -r '.producer.executable_sha256' "$reviewer_evidence")"
judge_path="$(jq -r '.producer.executable' "$judge_evidence")"
judge_executable_sha="$(jq -r '.producer.executable_sha256' "$judge_evidence")"
require_pinned_producer reviewer "$reviewer" "$reviewer_path" "$reviewer_executable_sha"
require_pinned_producer judge semantic-judge "$judge_path" "$judge_executable_sha"
case "$reviewer" in
  Claude) expected_reviewer_model=claude ;;
  Codex) expected_reviewer_model=codex ;;
  *) die "reviewer identity cannot be mapped to a model" ;;
esac
[ "$(jq -r '.producer.model' "$reviewer_evidence")" = "$expected_reviewer_model" ] \
  || die "signed reviewer model does not match reviewer identity"
expected_reviewer_invocation_sha="$(
  printf '%s\0' "$reviewer_path" "$expected_reviewer_model" --mode reviewer | sha256_stream
)"
[ "$(jq -r '.producer.invocation_sha256' "$reviewer_evidence")" = "$expected_reviewer_invocation_sha" ] \
  || die "signed reviewer invocation does not match the fixed identity contract"
expected_judge_invocation_sha="$(printf '%s\0' "$judge_path" | sha256_stream)"
[ "$(jq -r '.producer.invocation_sha256' "$judge_evidence")" = "$expected_judge_invocation_sha" ] \
  || die "signed judge invocation does not match the fixed signoff contract"

gate_sha="$(sha256_file "$gate_receipt")"
gate_signature_sha="$(sha256_file "$gate_receipt.sig")"
judge_sha="$(sha256_file "$judge_evidence")"
judge_signature_sha="$(sha256_file "$judge_evidence.sig")"
[ "$gate_sha" = "$(jq -r '.canonical_gate.receipt_sha256' "$artifact")" ] \
  && [ "$gate_signature_sha" = "$(jq -r '.canonical_gate.signature_sha256' "$artifact")" ] \
  || die "gate receipt or signature digest does not match review artifact"
[ "$reviewer_sha" = "$(jq -r '.reviewer_evidence.sha256' "$artifact")" ] \
  && [ "$reviewer_signature_sha" = "$(jq -r '.reviewer_evidence.signature_sha256' "$artifact")" ] \
  || die "reviewer evidence or signature digest does not match review artifact"
[ "$judge_sha" = "$(jq -r '.judge.evidence_sha256' "$artifact")" ] \
  && [ "$judge_signature_sha" = "$(jq -r '.judge.signature_sha256' "$artifact")" ] \
  || die "judge evidence or signature digest does not match review artifact"
[ "$(jq -r '.reviewer_evidence.producer_identity' "$artifact")" = "$reviewer" ] \
  && [ "$(jq -r '.judge.producer_identity' "$artifact")" = semantic-judge ] \
  || die "artifact producer identities do not match signed evidence"
[ "$(jq -r '.reviewer_evidence.executable' "$artifact")" = "$reviewer_path" ] \
  && [ "$(jq -r '.reviewer_evidence.executable_sha256' "$artifact")" = "$reviewer_executable_sha" ] \
  && [ "$(jq -r '.judge.executable' "$artifact")" = "$judge_path" ] \
  && [ "$(jq -r '.judge.executable_sha256' "$artifact")" = "$judge_executable_sha" ] \
  || die "artifact producer executables do not match signed evidence"
jq -e --slurpfile evidence "$reviewer_evidence" '.findings == $evidence[0].findings' \
  "$artifact" >/dev/null 2>&1 || die "review findings do not match signed reviewer evidence"
[ "$(jq -r '.judge.tool_version' "$artifact")" = "$(jq -r '.tool_version' "$judge_evidence")" ] \
  || die "judge tool version does not match signed evidence"
[ "$(jq -r '.trust.policy_sha256' "$artifact")" = "$(sha256_file "$trust_policy")" ] \
  && [ "$(jq -r '.trust.allowed_signers_sha256' "$artifact")" = "$(sha256_file "$allowed_signers")" ] \
  || die "artifact trust fingerprints do not match the operator-pinned policy"

if jq -e '.findings.unresolved[]? | select(.severity == "P0" or .severity == "P1")' \
  "$artifact" >/dev/null; then
  die "review has unresolved P0 or P1 findings"
fi
[ "$(jq -r '.findings.counts.P0' "$artifact")" -eq 0 ] \
  && [ "$(jq -r '.findings.counts.P1' "$artifact")" -eq 0 ] \
  || die "review reports P0 or P1 findings"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-review-validation.XXXXXX")" || exit 1
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
git -C "$repo" show "$candidate:scripts/test-suites.tsv" > "$tmp/test-suites.tsv" \
  || die "candidate suite inventory is unavailable"
git -C "$repo" show "$candidate:scripts/run-all-tests.sh" > "$tmp/run-all-tests.sh" \
  || die "candidate release runner is unavailable"
git -C "$repo" show "$candidate:ai-engineering/workflows/evals/review-pass-rubric.json" \
  > "$tmp/review-pass-rubric.json" || die "candidate finding-confidence rubric is unavailable"
inventory_sha="$(sha256_file "$tmp/test-suites.tsv")"
runner_sha="$(sha256_file "$tmp/run-all-tests.sh")"
rubric_sha="$(sha256_file "$tmp/review-pass-rubric.json")"
[ "$inventory_sha" = "$(jq -r '.inventory_sha256' "$gate_receipt")" ] \
  && [ "$inventory_sha" = "$(jq -r '.canonical_gate.inventory_sha256' "$artifact")" ] \
  || die "gate inventory does not match the candidate suite inventory"
[ "$runner_sha" = "$(jq -r '.producer.script_sha256' "$gate_receipt")" ] \
  || die "gate producer does not match the candidate release runner"
suite_count="$(awk -F '\t' '$1 !~ /^#/ && $1 != "" { count++ } END { print count + 0 }' "$tmp/test-suites.tsv")"
[ "$suite_count" = "$(jq -r '.suite_count' "$gate_receipt")" ] \
  || die "gate receipt suite count does not match full candidate inventory"
candidate_version="$(candidate_tool_version "$candidate")" \
  || die "candidate harness version is unavailable"
[ "$candidate_version" = "$(jq -r '.tool_version' "$gate_receipt")" ] \
  && [ "$candidate_version" = "$(jq -r '.tool_version' "$artifact")" ] \
  || die "evidence tool version does not match candidate version"

eval_path="$(jq -r '.finding_confidence_eval.path' "$judge_evidence")"
[ -f "$eval_path" ] && [ ! -L "$eval_path" ] \
  || die "signed finding-confidence eval artifact is unavailable"
eval_path="$(realpath -- "$eval_path")" || die "finding-confidence eval artifact cannot be resolved"
case "$eval_path" in "$repo"|"$repo"/*) die "finding-confidence eval artifact must live outside the candidate repository" ;; esac
eval_sha="$(sha256_file "$eval_path")"
[ "$eval_sha" = "$(jq -r '.finding_confidence_eval.sha256' "$judge_evidence")" ] \
  && [ "$eval_sha" = "$(jq -r '.judge.finding_confidence_eval.sha256' "$artifact")" ] \
  || die "finding-confidence eval digest is not bound through judge and artifact"
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
[ "$eval_count" = "$(jq -r '.finding_confidence_eval.evidence_count' "$judge_evidence")" ] \
  && [ "$eval_count" = "$(jq -r '.judge.finding_confidence_eval.evidence_count' "$artifact")" ] \
  && [ "$rubric_sha" = "$(jq -r '.finding_confidence_eval.rubric_sha256' "$judge_evidence")" ] \
  && [ "$rubric_sha" = "$(jq -r '.judge.finding_confidence_eval.rubric_sha256' "$artifact")" ] \
  || die "finding-confidence eval result is not fully bound through final validation"

printf 'Review artifact valid for signed candidate %s and base %s.\n' "$candidate" "$base"
