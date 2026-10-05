#!/usr/bin/env bash
# Compatibility reader for the candidate gate's canonical target inventory.
sync_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -f "$sync_lib_dir/../sync-checks.json" ]] || return 1
sync_rows="$(node - "$sync_lib_dir/../sync-checks.json" <<'NODE'
const rows = require(process.argv[2]);
if (!Array.isArray(rows) || rows.length === 0) process.exit(1);
for (const row of rows) {
  if (!row || typeof row !== 'object' || Array.isArray(row) ||
      Object.keys(row).sort().join(',') !== 'profile,scope,source,target' ||
      Object.values(row).some(value => typeof value !== 'string' || /[|\x22$\x60\r\n]/.test(value)) ||
      !['install', 'central'].includes(row.scope)) process.exit(1);
  console.log([row.source, row.target, row.profile, row.scope].join('|'));
}
NODE
)" || return 1
[[ -n "$sync_rows" ]] || return 1
SYNC_CHECKS=()
while IFS= read -r entry; do
  SYNC_CHECKS+=("$entry")
done <<< "$sync_rows"
unset sync_rows
