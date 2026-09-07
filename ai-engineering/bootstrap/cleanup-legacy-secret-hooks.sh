#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--apply] <repo-root>\n' "$0" >&2
  exit 2
}

apply=0
if [[ "${1:-}" == --apply ]]; then
  apply=1
  shift
fi
[[ "$#" -eq 1 ]] || usage

repo_input=$1
[[ -d "$repo_input" && ! -L "$repo_input" ]] || usage
repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null)" || usage
# Use the common Git directory, not the per-worktree one. Git executes the
# default hooks from the common directory for every linked worktree, so a
# worktree-scoped directory would miss the hooks that actually run. Git may
# report this relative to the invocation directory, which is the work tree
# root here. core.hooksPath is deliberately ignored: sync only retires the
# hooks it installed inside this repository.
git_root="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || usage
[[ -n "$git_root" ]] || usage
[[ "$git_root" == /* ]] || git_root="$repo_root/$git_root"

dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/bootstrap/lib/file-safety.sh
. "$dir/lib/file-safety.sh"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
. "$dir/../runtime/receipt-lib.sh"

git_root="$(arkira_safe_root "$git_root")" || {
  printf 'ERROR: target Git directory is unsafe.\n' >&2
  exit 1
}
hooks_dir="$(arkira_safe_target "$git_root" hooks)" || {
  printf 'ERROR: target hooks directory is unsafe.\n' >&2
  exit 1
}
if [[ -e "$hooks_dir" || -L "$hooks_dir" ]]; then
  [[ -d "$hooks_dir" && ! -L "$hooks_dir" ]] || {
    printf 'ERROR: target hooks directory is unsafe.\n' >&2
    exit 1
  }
else
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/arkira-hook-cleanup.XXXXXX")"
chmod 700 "$tmp"
lock_owned=0
lock_identity=""
lock_root=""
transaction_active=0
transaction_committed=0
declare -a hook_names=("")
declare -a hook_rels=("")
declare -a snapshots=("")
declare -a candidates=("")
declare -a original_claims=("")
declare -a original_claim_identities=("")
declare -a published_identities=("")
hook_count=0

private_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

safe_file_matches() {
  local rel=$1 expected=$2 live_copy live_mode expected_mode matches=1
  live_copy="$(mktemp "$tmp/live.XXXXXX")" || return 1
  if ! arkira_safe_read "$git_root" "$rel" > "$live_copy"; then
    rm -f -- "$live_copy"
    return 1
  fi
  live_mode="$(arkira_safe_file_mode "$git_root" "$rel")" || matches=0
  expected_mode="$(private_mode "$expected")" || matches=0
  cmp -s "$live_copy" "$expected" || matches=0
  rm -f -- "$live_copy"
  [[ "$matches" -eq 1 && "$live_mode" == "$expected_mode" ]]
}

cleanup_lock() {
  local lock_path
  if [[ "$lock_owned" -eq 1 ]]; then
    lock_path="$(arkira_safe_target "$lock_root" arkira-legacy-hook-cleanup.lock \
      2>/dev/null || true)"
    if [[ -n "$lock_path" && -d "$lock_path" && ! -L "$lock_path" \
      && "$(arkira_stat_identity "$lock_path" 2>/dev/null || true)" == "$lock_identity" ]]; then
      arkira_safe_rmdir "$lock_root" arkira-legacy-hook-cleanup.lock || true
    fi
    lock_owned=0
  fi
  rm -rf -- "$tmp"
}

rollback_hooks() {
  local index rel rollback_claim rollback_identity
  [[ "$transaction_active" -eq 1 && "$transaction_committed" -eq 0 ]] || return 0
  for ((index=hook_count; index>=1; index--)); do
    rel=${hook_rels[$index]}
    if [[ -n "${published_identities[$index]:-}" ]]; then
      rollback_claim="$(arkira_claim_regular_file "$git_root" "$rel" \
        .arkira-hook-rollback 2>/dev/null || true)"
      if [[ -z "$rollback_claim" ]]; then
        printf 'ERROR: could not claim published hook during rollback: %s\n' "$rel" >&2
        continue
      fi
      rollback_identity="$(arkira_stat_identity "$git_root/$rollback_claim" \
        2>/dev/null || true)"
      if [[ "$rollback_identity" != "${published_identities[$index]}" ]] \
        || ! safe_file_matches "$rollback_claim" "${candidates[$index]}"; then
        arkira_restore_claim_new "$git_root" "$rollback_claim" "$rel" || true
        printf 'ERROR: concurrently changed hook retained during rollback: %s\n' "$rel" >&2
        continue
      fi
      if ! arkira_restore_claim_new "$git_root" "${original_claims[$index]}" "$rel"; then
        arkira_restore_claim_new "$git_root" "$rollback_claim" "$rel" || true
        printf 'ERROR: could not restore original hook: %s\n' "$rel" >&2
        continue
      fi
      arkira_safe_remove_file "$git_root" "$rollback_claim" || true
      original_claims[$index]=""
      published_identities[$index]=""
    elif [[ -n "${original_claims[$index]:-}" ]]; then
      if [[ ! -e "$git_root/$rel" && ! -L "$git_root/$rel" ]]; then
        arkira_restore_claim_new "$git_root" "${original_claims[$index]}" "$rel" || true
        original_claims[$index]=""
      fi
    fi
  done
}

on_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  rollback_hooks
  cleanup_lock
  exit "$rc"
}

on_signal() {
  local signal=$1
  trap - EXIT HUP INT TERM
  rollback_hooks
  cleanup_lock
  kill -s "$signal" "$$"
  exit 1
}

trap on_exit EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

if [[ "$apply" -eq 1 ]]; then
  lock_runtime_root="$(arkira_receipt_runtime_root)"
  lock_repo_identity="$(arkira_receipt_repo_identity "$repo_root")" || {
    printf 'ERROR: legacy hook cleanup lock identity is unavailable.\n' >&2
    exit 1
  }
  lock_locks_root="$lock_runtime_root/locks"
  lock_root="$lock_locks_root/$lock_repo_identity"
  if ! {
    arkira_receipt_reject_symlink_components "$lock_runtime_root" &&
      arkira_receipt_reject_symlink_components "$lock_locks_root" &&
      arkira_receipt_reject_symlink_components "$lock_root" &&
      mkdir -p -- "$lock_root" &&
      [[ -d "$lock_runtime_root" && -d "$lock_locks_root" && \
        -d "$lock_root" ]] &&
      arkira_receipt_reject_symlink_components "$lock_runtime_root" &&
      arkira_receipt_reject_symlink_components "$lock_locks_root" &&
      arkira_receipt_reject_symlink_components "$lock_root" &&
      chmod 700 "$lock_runtime_root" "$lock_locks_root" "$lock_root"
  }; then
    printf 'ERROR: legacy hook cleanup lock directory could not be created.\n' >&2
    exit 1
  fi
  lock_root="$(arkira_safe_root "$lock_root")" || {
    printf 'ERROR: legacy hook cleanup lock directory is unsafe.\n' >&2
    exit 1
  }
  arkira_safe_mkdir_new "$lock_root" arkira-legacy-hook-cleanup.lock || {
    printf 'ERROR: another legacy hook cleanup is active.\n' >&2
    exit 1
  }
  lock_owned=1
  lock_identity="$(arkira_stat_identity \
    "$lock_root/arkira-legacy-hook-cleanup.lock")" || exit 1
fi

for hook_name in pre-commit pre-push; do
  hook_rel="hooks/$hook_name"
  hook_path="$(arkira_safe_target "$git_root" "$hook_rel")" || exit 1
  if [[ ! -e "$hook_path" && ! -L "$hook_path" ]]; then
    continue
  fi
  [[ -f "$hook_path" && ! -L "$hook_path" ]] || {
    printf 'ERROR: legacy hook target is not a regular file: %s\n' "$hook_rel" >&2
    exit 1
  }
  snapshot="$tmp/$hook_name.before"
  candidate="$tmp/$hook_name.after"
  arkira_safe_read "$git_root" "$hook_rel" > "$snapshot" || exit 1
  hook_mode="$(arkira_safe_file_mode "$git_root" "$hook_rel")" || exit 1
  chmod "$hook_mode" "$snapshot"
  if [[ "$hook_name" == pre-commit ]]; then
    legacy_line='ggshield secret scan pre-commit "$@"'
  else
    legacy_line='ggshield secret scan pre-push "$@"'
  fi
  changed="$(node - "$snapshot" "$candidate" "$legacy_line" "$hook_name" <<'NODE'
const fs = require("fs");
const [source, destination, legacyLine, hookName] = process.argv.slice(2);
const input = fs.readFileSync(source, "utf8");
const lines = input.match(/[^\n]*(?:\n|$)/g) || [];
let removed = 0;
const kept = [];
for (let index = 0; index < lines.length; index += 1) {
  const line = lines[index];
  if (line === "") continue;
  const withoutLf = line.endsWith("\n") ? line.slice(0, -1) : line;
  const body = withoutLf.endsWith("\r") ? withoutLf.slice(0, -1) : withoutLf;
  if (hookName === "pre-commit" && body === "# >>> arkira dash-guard >>>") {
    let end = index + 1;
    while (end < lines.length) {
      const candidate = lines[end].replace(/\r?\n$/, "");
      if (candidate === "# <<< arkira dash-guard <<<") break;
      end += 1;
    }
    if (end < lines.length) {
      removed += end - index + 1;
      index = end;
      continue;
    }
  }
  if (body === legacyLine) {
    removed += 1;
  } else {
    kept.push(line);
  }
}
fs.writeFileSync(destination, kept.join(""));
fs.chmodSync(destination, fs.statSync(source).mode & 0o777);
process.stdout.write(removed > 0 ? "1" : "0");
NODE
)" || exit 1
  [[ "$changed" == 1 ]] || continue
  hook_count=$((hook_count + 1))
  hook_names[$hook_count]=$hook_name
  hook_rels[$hook_count]=$hook_rel
  snapshots[$hook_count]=$snapshot
  candidates[$hook_count]=$candidate
  original_claims[$hook_count]=""
  original_claim_identities[$hook_count]=""
  published_identities[$hook_count]=""
done

if [[ "$hook_count" -eq 0 ]]; then
  transaction_committed=1
  exit 0
fi

if [[ "$apply" -eq 0 ]]; then
  for ((index=1; index<=hook_count; index++)); do
    printf 'WOULD CLEAN %s\n' "${hook_rels[$index]}"
  done
  transaction_committed=1
  exit 0
fi

transaction_active=1
for ((index=1; index<=hook_count; index++)); do
  hook_name=${hook_names[$index]}
  hook_rel=${hook_rels[$index]}
  if [[ "${ARKIRA_HOOK_CLEANUP_TEST_MUTATE_AFTER_SNAPSHOT:-}" == "$hook_name" ]]; then
    printf '\nconcurrent hook edit\n' >> "$git_root/$hook_rel"
    unset ARKIRA_HOOK_CLEANUP_TEST_MUTATE_AFTER_SNAPSHOT
  fi
  original_claim="$(arkira_claim_regular_file "$git_root" "$hook_rel" \
    .arkira-hook-original)" || exit 1
  original_claims[$index]=$original_claim
  original_claim_identities[$index]="$(arkira_stat_identity \
    "$git_root/$original_claim")" || exit 1
  if ! safe_file_matches "$original_claim" "${snapshots[$index]}"; then
    arkira_restore_claim_new "$git_root" "$original_claim" "$hook_rel" || true
    original_claims[$index]=""
    printf 'ERROR: hook changed while legacy cleanup was staged: %s\n' \
      "$hook_rel" >&2
    exit 1
  fi
  published_identities[$index]="$(arkira_atomic_copy_new_with_identity \
    "$git_root" "$hook_rel" "${candidates[$index]}")" || exit 1
  if [[ -n "${ARKIRA_HOOK_CLEANUP_FAIL_AFTER_PUBLISH_COUNT:-}" \
    && "$index" -eq "$ARKIRA_HOOK_CLEANUP_FAIL_AFTER_PUBLISH_COUNT" ]]; then
    printf 'ERROR: injected legacy hook publication failure\n' >&2
    false
  fi
done

for ((index=1; index<=hook_count; index++)); do
  hook_rel=${hook_rels[$index]}
  [[ "$(arkira_stat_identity "$git_root/$hook_rel" 2>/dev/null || true)" \
    == "${published_identities[$index]}" ]] \
    && safe_file_matches "$hook_rel" "${candidates[$index]}" || {
      printf 'ERROR: cleaned hook changed before commit: %s\n' "$hook_rel" >&2
      exit 1
    }
done

transaction_committed=1
for ((index=1; index<=hook_count; index++)); do
  original_claim=${original_claims[$index]}
  if [[ -n "$original_claim" ]]; then
    [[ "$(arkira_stat_identity "$git_root/$original_claim" 2>/dev/null || true)" \
      == "${original_claim_identities[$index]}" ]] \
      && safe_file_matches "$original_claim" "${snapshots[$index]}" || {
        printf 'ERROR: original hook claim changed before cleanup: %s\n' \
          "$original_claim" >&2
        exit 1
      }
    arkira_safe_remove_file "$git_root" "$original_claim" || exit 1
    printf 'CLEANED %s\n' "${hook_rels[$index]}"
  fi
done

transaction_active=0
trap - EXIT HUP INT TERM
cleanup_lock
