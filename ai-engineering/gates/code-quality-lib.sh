#!/usr/bin/env bash
# Pure matching and report-record helpers for code-quality qualification.

arkira_code_quality_match() {
  local expected=${1:-} result=${2:-}
  [[ -f "$expected" && ! -L "$expected" && -f "$result" && ! -L "$result" ]] || return 1
  jq -e --slurpfile expected "$expected" '
    . as $result |
    $expected[0] as $contract |
    $result.fixture == $contract.fixture_id and
    any($result.findings[];
      .category == $contract.expected.category and
      .path == $contract.expected.path and
      (.summary | type == "string" and length > 0))
  ' "$result" >/dev/null
}

arkira_code_quality_append_record() {
  local records=${1:-} expected=${2:-} result=${3:-} passed=${4:-false}
  local detail=${5:-} duration=${6:-0} usage=${7:-null} stderr=${8:-} output=${9:-}
  local result_json=null
  [[ -f "$records" && ! -L "$records" && -f "$expected" && ! -L "$expected" ]] || return 1
  [[ "$passed" == true || "$passed" == false ]] || return 1
  [[ "$duration" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$usage" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  if [[ -n "$result" && -f "$result" && ! -L "$result" ]] && jq -e . "$result" >/dev/null 2>&1; then
    result_json="$(jq -c . "$result")"
  fi
  jq --slurpfile expected "$expected" --argjson result "$result_json" \
    --argjson passed "$passed" --arg detail "$detail" --argjson duration_seconds "$duration" \
    --argjson token_use "$usage" --arg stderr "$stderr" '
    . + [{
      fixture:$expected[0].expected.category,
      fixture_id:$expected[0].fixture_id,
      fixture_version:$expected[0].fixture_version,
      expected:$expected[0].expected,
      passed:$passed,
      detail:$detail,
      duration_seconds:$duration_seconds,
      token_use:$token_use,
      result:$result,
      stderr:$stderr
    }]
  ' "$records" > "$output"
}
