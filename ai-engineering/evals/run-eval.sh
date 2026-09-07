#!/usr/bin/env bash
# run-eval.sh: minimal offline-capable eval runner.
#
# Usage:
#   bash ai-engineering/evals/run-eval.sh <rubric.json> <fixture-dir>
#
# Rubric format:
# {
#   "threshold": 100,
#   "criteria": [
#     {
#       "id": "stable-id",
#       "text": "observable assertion",
#       "kind": "deterministic",
#       "weight": 1,
#       "hard_fail": false,
#       "check": { "type": "grep|count|schema|exit_code", ... }
#     }
#   ]
# }
#
# Deterministic checks run locally. Judge checks use .judge.command or
# ARKIRA_EVAL_JUDGE_COMMAND. If no judge command is configured, the criterion is
# skipped and excluded from the score. A rubric with require_judge=true returns
# UNVERIFIED when that skip occurs.
#
# Exit codes:
#   0 pass
#   1 fail
#   2 environment skip or required evidence unverified

set -uo pipefail

rubric="${1:-}"
fixture_dir="${2:-}"

die_env() {
  printf 'ENV SKIP: %s\n' "$*" >&2
  exit 2
}

die_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

json_get() {
  local query="$1"
  local file="$2"
  jq -r "$query" "$file"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die_env "required file not found: $path"
}

if [[ -z "$rubric" || -z "$fixture_dir" ]]; then
  printf 'usage: run-eval.sh <rubric.json> <fixture-dir>\n' >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || die_env "jq is required"
require_file "$rubric"
[[ -d "$fixture_dir" ]] || die_env "fixture directory not found: $fixture_dir"
jq -e '.criteria | type == "array"' "$rubric" >/dev/null 2>&1 \
  || die_env "rubric must contain a criteria array"

# Security gate: exit_code checks and the judge run `bash -c` with command strings
# taken from the rubric, so a rubric is executable code, not data. Only run rubrics
# from trusted locations (this plugin, or an explicit ARKIRA_EVAL_TRUSTED_DIR) so
# untrusted repo content cannot inject commands. See harness-audit-2026-06-29.
eval_self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd -- "$eval_self_dir/../.." && pwd -P)}"
rubric_abs="$(cd -- "$(dirname -- "$rubric")" 2>/dev/null && pwd -P)/$(basename -- "$rubric")"
rubric_trusted=0
case "$rubric_abs" in "$plugin_root"/*) rubric_trusted=1 ;; esac
if [ "$rubric_trusted" -eq 0 ] && [ -n "${ARKIRA_EVAL_TRUSTED_DIR:-}" ]; then
  trusted_abs="$(cd -- "$ARKIRA_EVAL_TRUSTED_DIR" 2>/dev/null && pwd -P || true)"
  [ -n "$trusted_abs" ] && case "$rubric_abs" in "$trusted_abs"/*) rubric_trusted=1 ;; esac
fi
[ "$rubric_trusted" -eq 1 ] \
  || die_env "refusing rubric outside trusted paths: $rubric_abs (set ARKIRA_EVAL_TRUSTED_DIR to allow)"

threshold="$(json_get '.threshold // 100' "$rubric")"
criteria_rows="$(
  jq -r '
    .criteria
    | to_entries[]
    | .key as $i
    | .value as $criterion
    | ([
        ($criterion.id // ("criterion-" + ($i | tostring))),
        ($criterion.kind // "deterministic"),
        ($criterion.weight // 1),
        ($criterion.hard_fail // false)
      ] | @tsv) + "\t" + ($criterion | @json)
  ' "$rubric"
)"

passed_weight=0
total_weight=0
skipped_count=0
failed_count=0
hard_failed=0
required_judge_skipped=0
require_judge="$(json_get '.require_judge // false' "$rubric")"
target_provider=""
target_model=""
targets_rel="$(json_get '.targets_file // empty' "$rubric")"
if [ -n "$targets_rel" ]; then
  targets_path="$(dirname -- "$rubric")/$targets_rel"
  [ -f "$targets_path" ] || die_env "configured targets file not found: $targets_path"
  target_row="$(jq -r '.providers | to_entries[] | .key as $provider | .value[] | [$provider, .model] | @tsv' "$targets_path" | head -1)"
  [ -n "$target_row" ] || die_env "configured targets file has no model"
  target_provider="${target_row%%$'\t'*}"
  target_model="${target_row#*$'\t'}"
fi

evaluate_deterministic() {
  local criterion_json="$1"
  local check_type
  local rel_file
  local file
  check_type="$(jq -r '.check.type // empty' <<<"$criterion_json")"
  rel_file="$(jq -r '.check.file // empty' <<<"$criterion_json")"

  case "$check_type" in
    grep)
      local pattern invert
      pattern="$(jq -r '.check.pattern // empty' <<<"$criterion_json")"
      invert="$(jq -r '.check.invert // false' <<<"$criterion_json")"
      [[ -n "$rel_file" ]] || return 1
      [[ -n "$pattern" ]] || return 1
      file="$fixture_dir/$rel_file"
      [[ -f "$file" ]] || return 1
      if grep -Eq "$pattern" "$file"; then
        [[ "$invert" == "true" ]] && return 1
        return 0
      fi
      [[ "$invert" == "true" ]] && return 0
      return 1
      ;;
    count)
      local pattern min max count
      pattern="$(jq -r '.check.pattern // empty' <<<"$criterion_json")"
      min="$(jq -r '.check.min // 0' <<<"$criterion_json")"
      max="$(jq -r '.check.max // empty' <<<"$criterion_json")"
      [[ -n "$rel_file" ]] || return 1
      [[ -n "$pattern" ]] || return 1
      file="$fixture_dir/$rel_file"
      [[ -f "$file" ]] || return 1
      count="$(grep -Eo "$pattern" "$file" | wc -l | tr -d ' ')"
      [[ "$count" -ge "$min" ]] || return 1
      if [[ -n "$max" && "$count" -gt "$max" ]]; then
        return 1
      fi
      return 0
      ;;
    schema)
      local jq_expr
      jq_expr="$(jq -r '.check.jq // empty' <<<"$criterion_json")"
      [[ -n "$rel_file" ]] || return 1
      [[ -n "$jq_expr" ]] || return 1
      file="$fixture_dir/$rel_file"
      [[ -f "$file" ]] || return 1
      jq -e "$jq_expr" "$file" >/dev/null 2>&1
      return $?
      ;;
    exit_code)
      local cmd expected status
      cmd="$(jq -r '.check.command // empty' <<<"$criterion_json")"
      expected="$(jq -r '.check.expected // 0' <<<"$criterion_json")"
      [[ -n "$cmd" ]] || return 1
      (
        cd "$fixture_dir" || exit 127
        bash -c "$cmd"
      ) >/dev/null 2>&1
      status=$?
      [[ "$status" -eq "$expected" ]]
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

evaluate_judge() {
  local criterion_json="$1"
  local command verdict real confidence evidence
  command="$(jq -r '.judge.command // empty' <<<"$criterion_json")"
  if [[ -z "$command" ]]; then
    command="${ARKIRA_EVAL_JUDGE_COMMAND:-}"
  fi
  if [[ -z "$command" ]]; then
    return 2
  fi

  verdict="$(
    ARKIRA_EVAL_RUBRIC="$rubric" \
    ARKIRA_EVAL_FIXTURE="$fixture_dir" \
    ARKIRA_EVAL_CRITERION="$criterion_json" \
    ARKIRA_EVAL_TARGET_PROVIDER="$target_provider" \
    ARKIRA_EVAL_TARGET_MODEL="$target_model" \
    bash -c "$command"
  )" || return 1

  real="$(jq -r '.real // false' <<<"$verdict" 2>/dev/null)" || return 1
  confidence="$(jq -r '.confidence // 0' <<<"$verdict" 2>/dev/null)" || return 1
  evidence="$(jq -r '.evidence // ""' <<<"$verdict" 2>/dev/null)" || return 1

  [[ "$real" == "true" ]] || return 1
  [[ "$confidence" -ge 2 ]] || return 1
  if [[ "$(jq -r '.evidence_required // false' <<<"$criterion_json")" == "true" \
    && -z "$evidence" ]]; then
    return 1
  fi
  return 0
}

printf 'EVAL: %s\n' "$(json_get '.name // .id // "unnamed eval"' "$rubric")"
printf 'RUBRIC: %s\n' "$rubric"
printf 'FIXTURE: %s\n' "$fixture_dir"

if [[ -n "$criteria_rows" ]]; then
  while IFS=$'\t' read -r id kind weight hard_fail criterion_json; do
    case "$kind" in
      deterministic)
        total_weight=$((total_weight + weight))
        if evaluate_deterministic "$criterion_json"; then
          passed_weight=$((passed_weight + weight))
          printf 'PASS %s\n' "$id"
        else
          failed_count=$((failed_count + 1))
          printf 'FAIL %s\n' "$id"
          [[ "$hard_fail" == "true" ]] && hard_failed=1
        fi
        ;;
      judge)
        evaluate_judge "$criterion_json"
        status=$?
        if [[ "$status" -eq 2 ]]; then
          skipped_count=$((skipped_count + 1))
          printf 'SKIP %s: no judge command configured; excluded from score\n' "$id"
          [ "$require_judge" = "true" ] && required_judge_skipped=1
        elif [[ "$status" -eq 0 ]]; then
          total_weight=$((total_weight + weight))
          passed_weight=$((passed_weight + weight))
          printf 'PASS %s\n' "$id"
        else
          total_weight=$((total_weight + weight))
          failed_count=$((failed_count + 1))
          printf 'FAIL %s\n' "$id"
          [[ "$hard_fail" == "true" ]] && hard_failed=1
        fi
        ;;
      *)
        total_weight=$((total_weight + weight))
        failed_count=$((failed_count + 1))
        printf 'FAIL %s: unknown criterion kind %s\n' "$id" "$kind"
        [[ "$hard_fail" == "true" ]] && hard_failed=1
        ;;
    esac
  done <<<"$criteria_rows"
fi

if [[ "$total_weight" -eq 0 ]]; then
  printf 'RESULT: SKIP\n'
  printf 'SCORE: no scorable criteria; %s skipped\n' "$skipped_count"
  exit 2
fi

score="$(
  awk -v passed="$passed_weight" -v total="$total_weight" \
    'BEGIN { printf "%.2f", (passed / total) * 100 }'
)"
meets_threshold="$(
  awk -v score="$score" -v threshold="$threshold" \
    'BEGIN { print (score + 0 >= threshold + 0) ? "yes" : "no" }'
)"

printf 'SCORE: %s (%s/%s weight passed, %s skipped)\n' \
  "$score" "$passed_weight" "$total_weight" "$skipped_count"

if [[ "$hard_failed" -eq 1 || "$meets_threshold" != "yes" ]]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi

if [[ "$required_judge_skipped" -eq 1 ]]; then
  printf 'RESULT: UNVERIFIED\n'
  exit 2
fi

printf 'RESULT: PASS\n'
exit 0
