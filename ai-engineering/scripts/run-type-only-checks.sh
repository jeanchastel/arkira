#!/usr/bin/env bash
set -euo pipefail
fail() { printf 'FAIL: type-only: %s\n' "$1" >&2; exit 1; }
repo="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'requires a Git worktree'
cd "$repo"
base="${ARKIRA_TRUSTED_BASE_SHA:-}"; tree="${ARKIRA_CANDIDATE_TREE:-}"
[[ "$base" =~ ^[0-9a-f]{40}$ ]] || fail 'trusted base must be an exact 40-character SHA'
[[ "$tree" =~ ^[0-9a-f]{40}$ ]] || fail 'candidate tree must be an exact 40-character SHA'
[[ "$(git rev-parse --verify "$base^{commit}" 2>/dev/null)" == "$base" ]] || fail 'trusted base is unavailable'
[[ "$(git rev-parse --verify "$tree^{tree}" 2>/dev/null)" == "$tree" ]] || fail 'candidate tree is unavailable'
[[ "$(git rev-parse HEAD^{tree})" == "$tree" ]] || fail 'candidate tree does not match HEAD'
focused="${ARKIRA_FOCUSED_TEST_COMMAND:-}"
[[ -n "${focused//[[:space:]]/}" ]] || fail 'focused-test contract is missing'
[[ "$focused" != *run-all-tests.sh* && "$focused" != *run-product-release-gate.sh* ]] || fail 'focused-test contract names a complete inventory'
[[ -f package.json && ! -L package.json ]] || fail 'package.json is required'
command -v node >/dev/null 2>&1 || fail 'node is required'
IFS=$'\t' read -r manager version typecheck lint < <(node - package.json <<'NODE'
const fs=require('fs'); let p;
try { p=JSON.parse(fs.readFileSync(process.argv[2],'utf8')); } catch { process.exit(1); }
const m=/^(npm|pnpm|yarn)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/.exec(p.packageManager||'');
const script=n=>typeof p.scripts?.[n]==='string'&&p.scripts[n].trim();
if (!m || !script('typecheck') || !script('lint')) process.exit(1);
process.stdout.write(`${m[1]}\t${m[2]}\ttypecheck\tlint\n`);
NODE
) || fail 'packageManager, typecheck, or lint declaration is invalid'
case "$manager" in npm) runner=(npm);; pnpm) runner=(pnpm);; yarn) runner=(yarn);; *) fail 'unsupported package manager';; esac
"${runner[@]}" run typecheck
"${runner[@]}" run lint
bash -c "$focused"
git diff --check "$base" "$tree" || fail 'candidate diff validation failed'
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || fail 'checks changed the candidate worktree'
printf 'shape=type-only\nsmoke_required=false\ntrusted_base=%s\ncandidate_tree=%s\npackage_manager=%s@%s\nfocused_test=passed\n' "$base" "$tree" "$manager" "$version"
