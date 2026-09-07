#!/usr/bin/env bash
# Run the canonical Arkira test inventory in development, CI, or release mode.
set -uo pipefail

runner_file="$(realpath "${BASH_SOURCE[0]}")" || exit 1
[ "${ARKIRA_IN_CANDIDATE_GATE_SUITE:-}" != 1 ] || { printf 'FAIL: ARKIRA_IN_CANDIDATE_GATE_SUITE forbids run-all-tests.sh recursion\n' >&2; exit 1; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 1

gate_mode="development"
group_filter=""
suite_filter=""
manifest_path="scripts/test-suites.tsv"
central_product=false
lane_filter=""
lane_manifest_path="scripts/test-suite-lanes.tsv"
receipt_path=""
receipt_base=""
receipt_author=""
release_candidate_sha=""
release_runner_sha=""
release_manifest_sha=""
full_gate_lock_dir=""
full_gate_lock_acquired=0
npm_cache=""
active_suite_pgid=""
suite_timer_pid=""
suite_timeout_marker=""

usage() {
  printf 'usage: %s [--mode development|ci|release] [--suite ID | --group GROUP [--lane ID]] [--manifest PATH] [--lane-manifest PATH] [--receipt PATH --base SHA --author Claude|Codex]\n' "$0" >&2
}

# Release evidence is signed only after this candidate-owned runner exits.  A
# durable key or signing agent must never cross into this process or any suite.
for signing_var in \
  ARKIRA_GATE_SIGNING_KEY \
  ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY; do
  if [ -n "${!signing_var:-}" ]; then
    printf 'FAIL: %s must not be passed to candidate-owned release code; sign the unsigned receipt in a separate operator process\n' \
      "$signing_var" >&2
    exit 1
  fi
done
unset ARKIRA_GATE_SIGNING_KEY ARKIRA_REVIEWER_SIGNING_KEY \
  ARKIRA_JUDGE_SIGNING_KEY SSH_AUTH_SOCK

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'FAIL: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

candidate_is_unchanged() {
  [ -n "$release_candidate_sha" ] || return 0
  [ "$(git rev-parse HEAD 2>/dev/null)" = "$release_candidate_sha" ] || return 1
  [ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || return 1
  [ "$(sha256_file "$runner_file")" = "$release_runner_sha" ] \
    || return 1
  [ -z "$release_manifest_sha" ] || [ "$(sha256_file "$manifest_path")" = "$release_manifest_sha" ] || return 1
}

candidate_tool_version() {
  local version=""
  if git cat-file -e "$release_candidate_sha:.claude-plugin/plugin.json" 2>/dev/null; then
    version="$(git show "$release_candidate_sha:.claude-plugin/plugin.json" \
      | jq -r '.version // empty')"
  elif git cat-file -e "$release_candidate_sha:.arkira/sync-state.json" 2>/dev/null; then
    version="$(git show "$release_candidate_sha:.arkira/sync-state.json" \
      | jq -r '.plugin_version // empty')"
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --central-product)
      central_product=true
      shift
      ;;
    --mode)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      gate_mode="$2"
      shift 2
      ;;
    --group)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      group_filter="$2"
      shift 2
      ;;
    --suite)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ -n "$2" ] || { printf 'FAIL: --suite value must not be empty\n' >&2; exit 2; }
      suite_filter="$2"
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      manifest_path="$2"
      shift 2
      ;;
    --lane)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ -n "$2" ] || { printf 'FAIL: --lane value must not be empty\n' >&2; exit 2; }
      lane_filter="$2"
      shift 2
      ;;
    --lane-manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ -n "$2" ] || { printf 'FAIL: --lane-manifest value must not be empty\n' >&2; exit 2; }
      lane_manifest_path="$2"
      shift 2
      ;;
    --receipt)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      receipt_path="$2"
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      receipt_base="$2"
      shift 2
      ;;
    --author)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      receipt_author="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$gate_mode" in
  development|ci|release) ;;
  *) usage; exit 2 ;;
esac

if [ "$central_product" = true ]; then
  [ "$gate_mode" = release ] && [ "${ARKIRA_HARNESS_VERIFIED:-}" = true ] &&
    [ -n "${ARKIRA_HARNESS_ROOT:-}" ] &&
    [ "$runner_file" = "$ARKIRA_HARNESS_ROOT/scripts/run-all-tests.sh" ] &&
    [ "$manifest_path" = scripts/test-suites.tsv ] &&
    [ -z "$receipt_path" ] && [ -z "$receipt_base" ] && [ -z "$receipt_author" ] \
    || { printf 'FAIL: central product mode requires the verified canonical release runner and inventory\n' >&2; exit 1; }
fi

if [ "$gate_mode" = "release" ]; then
  { [ -z "$suite_filter" ] && [ -z "$group_filter" ] && [ -z "$lane_filter" ]; } \
    || { printf 'FAIL: release mode requires the full unfiltered inventory\n' >&2; exit 1; }
  [ "$manifest_path" = "scripts/test-suites.tsv" ] \
    || { printf 'FAIL: release mode requires scripts/test-suites.tsv\n' >&2; exit 1; }
fi

if [ -n "$suite_filter" ] && { [ -n "$group_filter" ] || [ -n "$lane_filter" ]; }; then
  printf 'FAIL: --suite cannot be combined with --group or --lane\n' >&2
  exit 1
fi

if [ "$gate_mode" = "ci" ] && [ -n "$suite_filter" ]; then
  printf 'FAIL: CI mode does not permit exact suite selection\n' >&2
  exit 1
fi

if [ -n "$lane_filter" ] && [ -z "$group_filter" ]; then
  printf 'FAIL: --lane requires --group\n' >&2
  exit 1
fi

if [ "$central_product" = true ]; then
  manifest_path="$ARKIRA_HARNESS_ROOT/ai-engineering/distribution/product-test-suites.tsv"
  [ -f "$manifest_path" ] && [ ! -L "$manifest_path" ] || {
    printf 'FAIL: central product inventory is missing or unsafe\n' >&2; exit 1;
  }
  release_manifest_sha="$(sha256_file "$manifest_path")" || exit 1
fi

if [ "$gate_mode" = "ci" ] && [ "$manifest_path" != "scripts/test-suites.tsv" ]; then
  printf 'FAIL: CI mode requires scripts/test-suites.tsv\n' >&2
  exit 1
fi

if [ "$gate_mode" = "ci" ] && [ -n "$lane_filter" ] \
  && [ "$lane_manifest_path" != "scripts/test-suite-lanes.tsv" ]; then
  printf 'FAIL: CI mode requires scripts/test-suite-lanes.tsv\n' >&2
  exit 1
fi

if [ "$gate_mode" = "release" ]; then
  release_candidate_sha="$(git rev-parse HEAD 2>/dev/null)" \
    || { printf 'FAIL: candidate HEAD is unavailable\n' >&2; exit 1; }
  [ -z "$(git status --porcelain=v1 --untracked-files=all)" ] \
    || { printf 'FAIL: refusing to test a dirty release candidate\n' >&2; exit 1; }
  release_runner_sha="$(sha256_file "$runner_file")" \
    || exit 1
fi

if [ -n "$receipt_path" ] || [ -n "$receipt_base" ] || [ -n "$receipt_author" ]; then
  [ "$gate_mode" = "release" ] || { printf 'FAIL: gate receipts require release mode\n' >&2; exit 1; }
  [ -n "$receipt_path" ] && [ -n "$receipt_base" ] && [ -n "$receipt_author" ] \
    || { printf 'FAIL: --receipt, --base, and --author are required together\n' >&2; exit 1; }
  [ "$receipt_author" = Claude ] || [ "$receipt_author" = Codex ] \
    || { printf 'FAIL: author must be Claude or Codex\n' >&2; exit 1; }
  case "$receipt_base" in *[!0-9a-f]*|'') printf 'FAIL: base must be an exact lowercase SHA\n' >&2; exit 1 ;; esac
  [ "${#receipt_base}" -eq 40 ] || { printf 'FAIL: base must be an exact 40-character SHA\n' >&2; exit 1; }
  git cat-file -e "$receipt_base^{commit}" 2>/dev/null \
    || { printf 'FAIL: base is not a commit\n' >&2; exit 1; }
  git merge-base --is-ancestor "$receipt_base" "$release_candidate_sha" 2>/dev/null \
    || { printf 'FAIL: base is not an ancestor of the captured candidate\n' >&2; exit 1; }
  receipt_parent="$(dirname -- "$receipt_path")"
  [ -d "$receipt_parent" ] && [ ! -L "$receipt_parent" ] \
    || { printf 'FAIL: receipt parent must be an existing non-symlink directory\n' >&2; exit 1; }
  [ ! -e "$receipt_path" ] && [ ! -L "$receipt_path" ] \
    || { printf 'FAIL: refusing to replace an existing receipt\n' >&2; exit 1; }
  committed_runner_sha="$(git show "$release_candidate_sha:scripts/run-all-tests.sh" \
    | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } \
    | awk '{print $1}')" || exit 1
  [ "$release_runner_sha" = "$committed_runner_sha" ] \
    || { printf 'FAIL: release runner does not match the captured candidate\n' >&2; exit 1; }
  export VERSION_BASE_REF="$receipt_base"
fi

if [ ! -f "$manifest_path" ]; then
  printf 'FAIL: suite manifest is not a regular file: %s\n' "$manifest_path" >&2
  exit 1
fi

if [ -n "$lane_filter" ] && [ ! -f "$lane_manifest_path" ]; then
  printf 'FAIL: lane manifest is not a regular file: %s\n' "$lane_manifest_path" >&2
  exit 1
fi

suite_timeout_seconds="${ARKIRA_SUITE_TIMEOUT_SECONDS:-900}"
case "$suite_timeout_seconds" in
  ''|*[!0-9]*|0) printf 'FAIL: ARKIRA_SUITE_TIMEOUT_SECONDS must be a positive integer\n' >&2; exit 2 ;;
esac

stop_active_suite() {
  if [[ "$active_suite_pgid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "-$active_suite_pgid" 2>/dev/null || true
    sleep 1
    kill -KILL "-$active_suite_pgid" 2>/dev/null || true
    active_suite_pgid=""
  fi
}

release_full_gate_lock() {
  local owner=""
  [ "$full_gate_lock_acquired" -eq 1 ] || return 0
  if [ -d "$full_gate_lock_dir" ] && [ ! -L "$full_gate_lock_dir" ]; then
    IFS= read -r owner < "$full_gate_lock_dir/owner" 2>/dev/null || owner=""
    if [ "$owner" = "$$" ]; then
      rm -f -- "$full_gate_lock_dir/owner"
      rmdir -- "$full_gate_lock_dir" 2>/dev/null || true
    fi
  fi
  full_gate_lock_acquired=0
}

cleanup() {
  if [[ "$suite_timer_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill "$suite_timer_pid" 2>/dev/null || true
    wait "$suite_timer_pid" 2>/dev/null || true
    suite_timer_pid=""
  fi
  stop_active_suite
  [ -z "$suite_timeout_marker" ] || rm -f -- "$suite_timeout_marker"
  release_full_gate_lock
  [ -z "$npm_cache" ] || rm -rf -- "$npm_cache"
}

exit_for_signal() {
  local status=$1
  cleanup
  trap - EXIT
  exit "$status"
}

acquire_full_gate_lock() {
  local git_dir owner=""
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  full_gate_lock_dir="$git_dir/arkira-full-gate.lock"
  [ ! -L "$full_gate_lock_dir" ] || {
    printf 'FAIL: full gate lock path is a symlink\n' >&2
    return 1
  }
  if ! mkdir -m 700 "$full_gate_lock_dir" 2>/dev/null; then
    if [ -d "$full_gate_lock_dir" ] && [ ! -L "$full_gate_lock_dir" ]; then
      IFS= read -r owner < "$full_gate_lock_dir/owner" 2>/dev/null || owner=""
    fi
    if [[ "$owner" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner" 2>/dev/null; then
      printf 'FAIL: full gate already running with pid %s\n' "$owner" >&2
      return 1
    fi
    rm -f -- "$full_gate_lock_dir/owner" 2>/dev/null || true
    rmdir -- "$full_gate_lock_dir" 2>/dev/null || {
      printf 'FAIL: stale full gate lock could not be reclaimed\n' >&2
      return 1
    }
    mkdir -m 700 "$full_gate_lock_dir" 2>/dev/null || {
      printf 'FAIL: full gate lock was acquired concurrently\n' >&2
      return 1
    }
  fi
  printf '%s\n' "$$" > "$full_gate_lock_dir/owner" || {
    rmdir -- "$full_gate_lock_dir" 2>/dev/null || true
    return 1
  }
  chmod 600 "$full_gate_lock_dir/owner" || {
    rm -f -- "$full_gate_lock_dir/owner"
    rmdir -- "$full_gate_lock_dir" 2>/dev/null || true
    return 1
  }
  full_gate_lock_acquired=1
}

run_suite_command() {
  local suite_id=$1 suite_command=$2 suite_pid status
  suite_timeout_marker="$npm_cache/suite-timeout-$selected_count"
  rm -f -- "$suite_timeout_marker"
  if command -v setsid >/dev/null 2>&1; then
    setsid env -u ARKIRA_GATE_SIGNING_KEY -u ARKIRA_REVIEWER_SIGNING_KEY \
      -u ARKIRA_JUDGE_SIGNING_KEY -u SSH_AUTH_SOCK \
      bash -c "$suite_command" </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!"; exec @ARGV' -- \
      env -u ARKIRA_GATE_SIGNING_KEY -u ARKIRA_REVIEWER_SIGNING_KEY \
      -u ARKIRA_JUDGE_SIGNING_KEY -u SSH_AUTH_SOCK \
      bash -c "$suite_command" </dev/null &
  else
    printf 'FAIL: setsid or perl is required for suite process isolation\n' >&2
    return 13
  fi
  suite_pid=$!
  active_suite_pgid=$suite_pid
  perl -e '
    use strict;
    use warnings;
    my ($seconds, $pgid, $marker) = @ARGV;
    my $deadline = time + $seconds;
    while ((my $left = $deadline - time) > 0) { sleep($left > 30 ? 30 : $left); }
    open my $handle, ">", $marker or exit 1;
    close $handle;
    chmod 0600, $marker;
    kill "TERM", -$pgid;
    select undef, undef, undef, 1;
    kill "KILL", -$pgid;
  ' "$suite_timeout_seconds" "$suite_pid" "$suite_timeout_marker" &
  suite_timer_pid=$!
  if wait "$suite_pid"; then status=0; else status=$?; fi
  kill "$suite_timer_pid" 2>/dev/null || true
  wait "$suite_timer_pid" 2>/dev/null || true
  suite_timer_pid=""
  active_suite_pgid=""
  if [ -f "$suite_timeout_marker" ] && [ ! -L "$suite_timeout_marker" ]; then
    rm -f -- "$suite_timeout_marker"
    suite_timeout_marker=""
    printf 'TIMEOUT: suite %s exceeded %s seconds\n' "$suite_id" "$suite_timeout_seconds" >&2
    return 124
  fi
  suite_timeout_marker=""
  return "$status"
}

cache_parent="${ARKIRA_GATE_CACHE_PARENT:-${TMPDIR:-/tmp}}"
if [ ! -d "$cache_parent" ]; then
  printf 'FAIL: task cache parent is not a directory: %s\n' "$cache_parent" >&2
  exit 1
fi
trap cleanup EXIT
trap 'exit_for_signal 129' HUP
trap 'exit_for_signal 130' INT
trap 'exit_for_signal 143' TERM

if [ -z "$suite_filter" ] && [ -z "$group_filter" ] && [ -z "$lane_filter" ]; then
  acquire_full_gate_lock || exit 1
fi

npm_cache="$(mktemp -d "$cache_parent/arkira-release-gate-npm.XXXXXX")" || {
  printf 'FAIL: could not create isolated npm cache\n' >&2
  exit 1
}
export npm_config_cache="$npm_cache"
suite_gate_mode="$gate_mode"
[ "$suite_gate_mode" = "ci" ] && suite_gate_mode="release"
export ARKIRA_GATE_MODE="$suite_gate_mode"

pass_count=0
warn_count=0
skip_count=0
fail_count=0
release_blockers=0
selected_count=0
deferred_suites=""
gate_started_epoch=$(date +%s)

suite_in_lane() {
  local candidate_suite_id=$1 lane_suite_id lane_id
  while IFS="$(printf '\t')" read -r lane_suite_id lane_id; do
    case "$lane_suite_id" in
      ''|'#'*) continue ;;
    esac
    if [ "$lane_suite_id" = "$candidate_suite_id" ] && [ "$lane_id" = "$lane_filter" ]; then
      return 0
    fi
  done < "$lane_manifest_path"
  return 1
}

while IFS="$(printf '\t')" read -r suite_id suite_group suite_mode suite_command; do
  case "$suite_id" in
    ''|'#'*) continue ;;
  esac
  if [ -n "$suite_filter" ] && [ "$suite_id" != "$suite_filter" ]; then
    continue
  fi
  if [ -n "$group_filter" ] && [ "$suite_group" != "$group_filter" ]; then
    continue
  fi
  if [ -n "$lane_filter" ] && ! suite_in_lane "$suite_id"; then
    continue
  fi
  if [ "$suite_mode" = "remote-authoritative" ]; then
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      suite_mode="required"
    else
      printf 'DEFERRED\t%s\t%s\t%s\n' "$suite_id" "$suite_group" "$suite_group"
      if [ -n "$deferred_suites" ]; then
        deferred_suites+=','
      fi
      deferred_suites+="$suite_id"
      continue
    fi
  fi
  selected_count=$((selected_count + 1))
  printf '\n=== %s ===\n' "$suite_id"
  suite_started_epoch=$(date +%s)

  run_suite_command "$suite_id" "$suite_command"
  suite_status=$?
  candidate_changed=0
  if [ "$gate_mode" = "release" ] && ! candidate_is_unchanged; then
    printf 'FAIL: candidate changed during release gate at suite %s\n' "$suite_id" >&2
    suite_status=1
    candidate_changed=1
  fi
  if [ "$suite_status" -eq 0 ]; then
    state="PASS"
    pass_count=$((pass_count + 1))
  elif [ "$suite_status" -eq 77 ]; then
    state="SKIP"
    skip_count=$((skip_count + 1))
    if { [ "$gate_mode" = "release" ] || [ "$gate_mode" = "ci" ]; } \
      && [ "$suite_mode" = "required" ]; then
      release_blockers=$((release_blockers + 1))
      printf 'RELEASE_BLOCKER\t%s\n' "$suite_id"
    fi
  elif [ "$suite_mode" = "informational" ]; then
    state="WARN"
    warn_count=$((warn_count + 1))
  else
    state="FAIL"
    fail_count=$((fail_count + 1))
  fi
  suite_elapsed_seconds=$(( $(date +%s) - suite_started_epoch ))
  printf 'RESULT\t%s\t%s\n' "$state" "$suite_id"
  printf 'DURATION\t%s\t%s\n' "$suite_id" "$suite_elapsed_seconds"
  [ "$candidate_changed" -eq 0 ] || break
done < "$manifest_path"

if [ "$selected_count" -eq 0 ]; then
  printf 'FAIL: no suites selected from %s\n' "$manifest_path" >&2
  exit 1
fi

printf '\nSUMMARY PASS=%d WARN=%d SKIP=%d FAIL=%d\n' \
  "$pass_count" "$warn_count" "$skip_count" "$fail_count"
printf 'DEFERRED_SUITES=%s\n' "$deferred_suites"
printf 'RELEASE_BLOCKERS=%d\n' "$release_blockers"
gate_elapsed_seconds=$(( $(date +%s) - gate_started_epoch ))
printf 'TOTAL_DURATION_SECONDS=%s\n' "$gate_elapsed_seconds"

if [ "$fail_count" -gt 0 ] || [ "$release_blockers" -gt 0 ]; then
  exit 1
fi

if [ $((pass_count + warn_count)) -eq 0 ]; then
  printf 'INDETERMINATE: no suites executed successfully\n' >&2
  exit 2
fi

if [ -n "$receipt_path" ]; then
  command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required to write a gate receipt\n' >&2; exit 1; }
  candidate_is_unchanged \
    || { printf 'FAIL: candidate changed before gate receipt publication\n' >&2; exit 1; }
  inventory_sha="$(sha256_file "$manifest_path")" || exit 1
  version="$(candidate_tool_version)" \
    || { printf 'FAIL: candidate harness version is unavailable\n' >&2; exit 1; }
  receipt_tmp="$(mktemp "$receipt_parent/.arkira-gate-receipt.XXXXXX")" || exit 1
  jq -n \
    --arg candidate_sha "$release_candidate_sha" \
    --arg base_sha "$receipt_base" \
    --arg author_identity "$receipt_author" \
    --arg inventory_sha256 "$inventory_sha" \
    --arg producer_script_sha256 "$release_runner_sha" \
    --arg tool_version "$version" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson pass "$pass_count" \
    --argjson warn "$warn_count" \
    --argjson skip "$skip_count" \
    --argjson suite_count "$selected_count" \
    '{schema:4,candidate_sha:$candidate_sha,base_sha:$base_sha,author_identity:$author_identity,result:"PASS",scope:"full",suite_count:$suite_count,pass:$pass,warn:$warn,skip:$skip,fail:0,required_skips:0,inventory_sha256:$inventory_sha256,producer:{identity:"release-gate",script_sha256:$producer_script_sha256},tool_version:$tool_version,timestamp:$timestamp}' \
    > "$receipt_tmp" || { rm -f "$receipt_tmp"; exit 1; }
  mv "$receipt_tmp" "$receipt_path" \
    || { rm -f "$receipt_tmp"; exit 1; }
  printf 'GATE_RECEIPT=%s\n' "$receipt_path"
  printf 'UNSIGNED: operator must verify this receipt, then sign it in a separate process with namespace arkira-release-gate\n'
fi
exit 0
