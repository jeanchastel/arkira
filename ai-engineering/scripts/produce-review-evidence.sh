#!/usr/bin/env bash
# Invoke one operator-approved reviewer or judge and emit unsigned evidence.
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

require_pinned_producer() {
  local role="$1" path="$2" digest="$3" count producer_owner producer_mode
  count="$(jq -r --arg role "$role" --arg path "$path" --arg digest "$digest" '
    [.producers[$role][]? | select(.path == $path and .sha256 == $digest)] | length
  ' "$trust_policy")"
  [ "$count" -eq 1 ] || die "$role producer is not uniquely approved by the release trust policy"
  identity="$(jq -r --arg role "$role" --arg path "$path" --arg digest "$digest" '
    .producers[$role][] | select(.path == $path and .sha256 == $digest) | .identity
  ' "$trust_policy")"
  case "$role:$identity" in
    reviewer:Claude|reviewer:Codex|judge:semantic-judge) ;;
    *) die "$role producer has an invalid policy identity" ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ] \
    || die "$role producer must be an executable regular non-symlink file"
  case "$path" in "$repo"|"$repo"/*) die "$role producer must live outside the candidate repository" ;; esac
  producer_owner="$(file_owner "$path")" || die "$role producer owner is unavailable"
  [ "$producer_owner" = "$(id -u)" ] \
    || die "$role producer must be owned by the invoking operator"
  producer_mode="$(file_mode "$path")" || die "$role producer mode is unavailable"
  if (( (8#$producer_mode & 0022) != 0 )); then
    die "$role producer must not be group- or world-writable"
  fi
}

for signing_var in \
  ARKIRA_GATE_SIGNING_KEY \
  ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY; do
  [ -z "${!signing_var:-}" ] \
    || die "$signing_var must not be passed to candidate-owned evidence code; sign only after this process exits"
done
unset ARKIRA_GATE_SIGNING_KEY ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY SSH_AUTH_SOCK

mode="${1:-}"
[ "$#" -gt 0 ] && shift
repo=""
candidate=""
base=""
output=""
reviewer_evidence=""
eval_evidence=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a path"; repo="$2"; shift 2 ;;
    --candidate) [ "$#" -ge 2 ] || die "--candidate requires a SHA"; candidate="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || die "--base requires a SHA"; base="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || die "--output requires a path"; output="$2"; shift 2 ;;
    --reviewer-evidence)
      [ "$#" -ge 2 ] || die "--reviewer-evidence requires a path"
      reviewer_evidence="$2"
      shift 2
      ;;
    --eval-evidence)
      [ "$#" -ge 2 ] || die "--eval-evidence requires a path"
      eval_evidence="$2"
      shift 2
      ;;
    --) shift; break ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$mode" in
  reviewer)
    namespace="arkira-reviewer"
    [ -z "$reviewer_evidence" ] || die "reviewer mode does not accept --reviewer-evidence"
    [ -z "$eval_evidence" ] || die "reviewer mode does not accept --eval-evidence"
    ;;
  judge)
    namespace="arkira-judge"
    [ -n "$reviewer_evidence" ] || die "judge mode requires --reviewer-evidence"
    [ -n "$eval_evidence" ] || die "judge mode requires --eval-evidence"
    ;;
  *) die "mode must be reviewer or judge" ;;
esac

[ -n "$repo" ] || die "--repo is required"
[ -n "$candidate" ] || die "--candidate is required"
[ -n "$base" ] || die "--base is required"
[ -n "$output" ] || die "--output is required"
[ "$#" -gt 0 ] || die "a producer executable is required after --"
sha_re='^[0-9a-f]{40}$'
hash_re='^[0-9a-f]{64}$'
[[ "$candidate" =~ $sha_re ]] || die "candidate must be an exact lowercase SHA"
[[ "$base" =~ $sha_re ]] || die "base must be an exact lowercase SHA"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v realpath >/dev/null 2>&1 || die "realpath is required"

repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || die "repository is unavailable"
head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || die "candidate HEAD is unavailable"
[ "$head_sha" = "$candidate" ] || die "candidate is stale for repository HEAD"
[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] \
  || die "candidate repository is dirty"
git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || die "base is not a commit"
git -C "$repo" merge-base --is-ancestor "$base" "$candidate" 2>/dev/null \
  || die "base is not an ancestor of candidate"

trust_policy="${ARKIRA_RELEASE_TRUST_POLICY:-}"
trust_policy_pin="${ARKIRA_RELEASE_TRUST_POLICY_SHA256:-}"
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
  (.producers.judge | type == "array" and length > 0) and
  ([.producers.reviewer[], .producers.judge[]] |
    all((.identity | type == "string" and length > 0) and
        (.path | type == "string" and startswith("/")) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
' "$trust_policy" >/dev/null || die "release trust policy is malformed"

output_parent="$(dirname -- "$output")"
[ -d "$output_parent" ] && [ ! -L "$output_parent" ] \
  || die "output parent must be an existing non-symlink directory"
output_parent="$(cd -- "$output_parent" && pwd -P)" || die "output parent cannot be resolved"
case "$output_parent" in "$repo"|"$repo"/*) die "evidence output must live outside the candidate repository" ;; esac
output="$output_parent/$(basename -- "$output")"
[ ! -e "$output" ] && [ ! -L "$output" ] \
  && [ ! -e "$output.sig" ] && [ ! -L "$output.sig" ] \
  || die "refusing to replace existing evidence or signature"

producer_command=("$@")
producer_path="${producer_command[0]}"
if [[ "$producer_path" != */* ]]; then
  producer_path="$(command -v -- "$producer_path" 2>/dev/null)" \
    || die "producer executable is unavailable"
fi
producer_path="$(realpath -- "$producer_path" 2>/dev/null)" \
  || die "producer executable cannot be resolved"
executable_sha="$(sha256_file "$producer_path")"
require_pinned_producer "$mode" "$producer_path" "$executable_sha"
producer_command[0]="$producer_path"
producer_model=""
if [ "$mode" = reviewer ]; then
  case "$identity" in
    Claude) producer_model=claude ;;
    Codex) producer_model=codex ;;
    *) die "reviewer producer identity cannot be mapped to a model" ;;
  esac
  [ "${#producer_command[@]}" -eq 4 ] \
    && [ "${producer_command[1]}" = "$producer_model" ] \
    && [ "${producer_command[2]}" = --mode ] \
    && [ "${producer_command[3]}" = reviewer ] \
    || die "reviewer producer invocation must match its policy identity and fixed reviewer contract"
else
  [ "${#producer_command[@]}" -eq 1 ] \
    || die "judge producer invocation does not accept caller-controlled arguments"
fi

tmp="$(mktemp -d "$output_parent/.arkira-evidence.XXXXXX")" \
  || die "cannot create evidence staging directory"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
raw="$tmp/raw.json"
stderr_log="$tmp/producer.stderr"
argv_file="$tmp/argv"
printf '%s\0' "${producer_command[@]}" > "$argv_file"
invocation_sha="$(sha256_file "$argv_file")"

export ARKIRA_CANDIDATE_SHA="$candidate"
export ARKIRA_BASE_SHA="$base"
if [ "$mode" = judge ]; then
  [ -f "$reviewer_evidence" ] && [ ! -L "$reviewer_evidence" ] \
    || die "reviewer evidence must be a regular non-symlink file"
  [ -f "$reviewer_evidence.sig" ] && [ ! -L "$reviewer_evidence.sig" ] \
    || die "reviewer evidence signature is missing or unsafe"
  [ -f "$eval_evidence" ] && [ ! -L "$eval_evidence" ] \
    || die "finding-confidence eval evidence must be a regular non-symlink file"
  reviewer_evidence="$(realpath -- "$reviewer_evidence")"
  eval_evidence="$(realpath -- "$eval_evidence")"
  case "$reviewer_evidence:$eval_evidence" in
    "$repo"/*:*|*:"$repo"/*) die "review and eval evidence must live outside the candidate repository" ;;
  esac
  export ARKIRA_REVIEWER_EVIDENCE_PATH="$reviewer_evidence"
  export ARKIRA_FINDING_CONFIDENCE_EVAL_PATH="$eval_evidence"
  reviewer_sha="$(sha256_file "$reviewer_evidence")"
  reviewer_signature_sha="$(sha256_file "$reviewer_evidence.sig")"
  eval_sha="$(sha256_file "$eval_evidence")"
  rubric_tmp="$tmp/review-pass-rubric.json"
  git -C "$repo" show "$candidate:ai-engineering/workflows/evals/review-pass-rubric.json" \
    > "$rubric_tmp" || die "candidate finding-confidence rubric is unavailable"
  rubric_sha="$(sha256_file "$rubric_tmp")"
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
        (.id | type == "string" and length > 0) and
        .real == true and
        (.confidence | type == "number" and . >= 2 and . <= 3 and floor == .) and
        (.evidence | type == "string" and length > 0)
      )] | length == ($root.finding_verdicts | length))
    ' "$eval_evidence" >/dev/null \
    || die "finding-confidence eval evidence is malformed, stale, or not a PASS"
  reviewer_ids="$(jq -c '[.findings.items[].id] | sort' "$reviewer_evidence")"
  eval_ids="$(jq -c '[.finding_verdicts[].id] | sort' "$eval_evidence")"
  [ "$reviewer_ids" = "$eval_ids" ] \
    || die "finding-confidence eval does not cover every signed reviewer finding"
fi

if ! (cd "$repo" && env -u ARKIRA_GATE_SIGNING_KEY \
  -u ARKIRA_REVIEWER_SIGNING_KEY -u ARKIRA_JUDGE_SIGNING_KEY -u SSH_AUTH_SOCK \
  ARKIRA_PRODUCER_IDENTITY="$identity" \
  "${producer_command[@]}") > "$raw" 2> "$stderr_log"; then
  die "$mode producer exited unsuccessfully"
fi
[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" = "$candidate" ] \
  && [ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] \
  || die "$mode producer changed the exact candidate"

if [ "$mode" = reviewer ]; then
  jq -e '
    . as $root |
    type == "object" and
    (.result == "PASS" or .result == "FAIL") and
    (.findings | type == "object") and
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
    (.tool_version | type == "string" and length > 0)
  ' "$raw" >/dev/null || die "reviewer producer output is malformed"
else
  jq -e '
    type == "object" and
    (.result == "PASS" or .result == "FAIL" or .result == "UNVERIFIED") and
    (.tool_version | type == "string" and length > 0)
  ' "$raw" >/dev/null || die "judge producer output is malformed"
fi

evidence_tmp="$tmp/evidence.json"
if [ "$mode" = reviewer ]; then
  jq -n --slurpfile raw "$raw" \
    --arg candidate "$candidate" --arg base "$base" --arg identity "$identity" \
    --arg model "$producer_model" \
    --arg executable "$producer_path" \
    --arg executable_sha "$executable_sha" --arg invocation_sha "$invocation_sha" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      {schema:3,candidate_sha:$candidate,base_sha:$base,
       producer:{identity:$identity,model:$model,executable:$executable,executable_sha256:$executable_sha,invocation_sha256:$invocation_sha},
       result:$raw[0].result,findings:$raw[0].findings,
       timestamp:$timestamp,tool_version:$raw[0].tool_version}
    ' > "$evidence_tmp"
else
  eval_count="$(jq -r '.finding_verdicts | length' "$eval_evidence")"
  jq -n --slurpfile raw "$raw" \
    --arg candidate "$candidate" --arg base "$base" --arg identity "$identity" \
    --arg executable "$producer_path" \
    --arg executable_sha "$executable_sha" --arg invocation_sha "$invocation_sha" \
    --arg reviewer_sha "$reviewer_sha" --arg reviewer_signature_sha "$reviewer_signature_sha" \
    --arg eval_path "$eval_evidence" --arg eval_sha "$eval_sha" --arg rubric_sha "$rubric_sha" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson eval_count "$eval_count" '
      {schema:3,candidate_sha:$candidate,base_sha:$base,
       producer:{identity:$identity,executable:$executable,executable_sha256:$executable_sha,invocation_sha256:$invocation_sha},
       result:$raw[0].result,reviewer_evidence_sha256:$reviewer_sha,
       reviewer_signature_sha256:$reviewer_signature_sha,
       finding_confidence_eval:{path:$eval_path,sha256:$eval_sha,result:"PASS",score:100,
         rubric_sha256:$rubric_sha,evidence_count:$eval_count},
       timestamp:$timestamp,tool_version:$raw[0].tool_version}
    ' > "$evidence_tmp"
fi

mv "$evidence_tmp" "$output" || die "could not publish $mode evidence"
printf 'Produced unsigned %s evidence: %s\n' "$mode" "$output"
printf 'UNSIGNED: operator must verify this evidence, then sign it in a separate process with namespace %s\n' "$namespace"
