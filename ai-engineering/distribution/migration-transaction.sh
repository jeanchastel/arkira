#!/usr/bin/env bash
# Contained file transaction. The trusted planner supplies a private stage;
# consumer files are data, never executable input.
set -euo pipefail
source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "$source_root/ai-engineering/bootstrap/lib/file-safety.sh"
repo=${1:?repository required}
stage=${2:?private stage required}
lock=.arkira-migration-lock
rels=() claims=() identities=() created=()
active=1
lock_owned=0

matches() {
  local rel=$1 expected=$2
  [[ -f "$expected" && ! -L "$expected" ]] || return 1
  [[ "$(arkira_safe_file_mode "$repo" "$rel")" == "$(arkira_safe_file_mode "$stage" "${expected##*/}")" ]] || return 1
  arkira_safe_read "$repo" "$rel" | cmp -s - "$expected"
}

rollback() {
  local i rel claim live failed=0
  for ((i=${#rels[@]}-1; i>=0; i--)); do
    rel=${rels[$i]}
    if [[ -n "${identities[$i]}" ]]; then
      live="$(arkira_stat_identity "$repo/$rel" 2>/dev/null || true)"
      if [[ "$live" != "${identities[$i]}" ]] || ! matches "$rel" "$stage/$i.after"; then
        printf 'Concurrent target preserved; original recovery claim: %s\n' "${claims[$i]}" >&2
        failed=1
        continue
      fi
      claim="$(arkira_claim_regular_file "$repo" "$rel" .arkira-migration-rollback)" || { failed=1; continue; }
      if [[ "$(arkira_stat_identity "$repo/$claim")" != "${identities[$i]}" ]] || ! matches "$claim" "$stage/$i.after"; then
        arkira_restore_claim_new "$repo" "$claim" "$rel" || true
        failed=1
        continue
      fi
      if [[ -n "${claims[$i]}" ]]; then
        if ! arkira_restore_claim_new "$repo" "${claims[$i]}" "$rel"; then
          arkira_restore_claim_new "$repo" "$claim" "$rel" || true
          failed=1
          continue
        fi
      fi
      arkira_safe_remove_file "$repo" "$claim" || failed=1
    elif [[ -n "${claims[$i]}" ]]; then
      arkira_restore_claim_new "$repo" "${claims[$i]}" "$rel" || failed=1
    fi
  done
  for ((i=${#created[@]}-1; i>=0; i--)); do
    arkira_safe_rmdir "$repo" "${created[$i]}" || failed=1
  done
  return "$failed"
}

finish() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$active" == 1 ]]; then rollback || status=1; fi
  if [[ "$lock_owned" == 1 ]]; then
    if [[ "$(arkira_stat_identity "$repo/$lock" 2>/dev/null || true)" == "$lock_identity" ]]; then
      arkira_safe_rmdir "$repo" "$lock" || status=1
    else status=1; fi
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
arkira_safe_mkdir_new "$repo" "$lock"
lock_identity="$(arkira_stat_identity "$repo/$lock")"
lock_owned=1
expected_head="$(node -e 'process.stdout.write(require(process.argv[1]).head)' "$stage/receipt.json")"
check_head() {
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$expected_head" ]] || {
    echo 'repository HEAD changed during migration' >&2
    return 1
  }
}
check_head

# Complete target preflight before any consumer file is claimed.
while IFS= read -r rel; do
  arkira_safe_target "$repo" "$rel" >/dev/null
done < <(node -e 'for(const c of require(process.argv[1]).changes) console.log(c.path)' "$stage/receipt.json")

i=0
while IFS= read -r rel; do
  rels+=("$rel"); claims+=(""); identities+=("")
  parent="$(dirname -- "$rel")"
  if [[ "$parent" != . ]]; then
    current=''
    IFS=/ read -r -a parts <<<"$parent"
    for part in "${parts[@]}"; do
      current="${current:+$current/}$part"
      if [[ ! -e "$repo/$current" ]]; then
        arkira_safe_mkdir_new "$repo" "$current"
        created+=("$current")
      fi
    done
  fi
  if [[ -f "$stage/$i.before" ]]; then
    matches "$rel" "$stage/$i.before" || { echo "snapshot changed: $rel" >&2; exit 1; }
    claims[$i]="$(arkira_claim_regular_file "$repo" "$rel" .arkira-migration-original)"
    matches "${claims[$i]}" "$stage/$i.before" || { echo "claimed snapshot changed: $rel" >&2; exit 1; }
  else
    [[ ! -e "$repo/$rel" && ! -L "$repo/$rel" ]] || { echo "new target appeared: $rel" >&2; exit 1; }
  fi
  if [[ -f "$stage/$i.after" ]]; then
    identities[$i]="$(arkira_atomic_copy_new_with_identity "$repo" "$rel" "$stage/$i.after")"
  fi
  i=$((i + 1))
done < <(node -e 'for(const c of require(process.argv[1]).changes) console.log(c.path)' "$stage/receipt.json")

for ((i=0; i<${#rels[@]}; i++)); do
  rel=${rels[$i]}
  if [[ -f "$stage/$i.after" ]]; then
    [[ "$(arkira_stat_identity "$repo/$rel")" == "${identities[$i]}" ]] && matches "$rel" "$stage/$i.after"
  else
    arkira_safe_target "$repo" "$rel" >/dev/null
    [[ ! -e "$repo/$rel" && ! -L "$repo/$rel" ]]
  fi
  [[ -z "${claims[$i]}" ]] || matches "${claims[$i]}" "$stage/$i.before"
done
check_head
active=0
for claim in "${claims[@]}"; do
  [[ -z "$claim" ]] || arkira_safe_remove_file "$repo" "$claim"
done
