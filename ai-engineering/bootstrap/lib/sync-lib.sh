#!/usr/bin/env bash

sync_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F arkira_atomic_write >/dev/null 2>&1; then
  # shellcheck source=ai-engineering/bootstrap/lib/file-safety.sh
  source "$sync_lib_dir/file-safety.sh"
fi

# Key separator for registry paths. ASCII Unit Separator (0x1F), never appears
# in filenames or block IDs. Exported as SYNC_KSEP for callers that build keys.
SYNC_KSEP=$'\x1f'
export SYNC_KSEP

# Each entry: "source|target|profile_filter|scope".
#   - source: path within the standards repo
#   - target: install path in the product repo
#   - profile_filter: optional comma-separated list of profiles this entry
#     applies to. "*" or empty means "any profile" (universal). The target
#     repo's profile is read from .arkira/config.json (.profile, default "app").
#   - scope: "install" copies and audits the target; "central" leaves it in the
#     installed snapshot. Empty or absent means "install" for compatibility.
# Profile-specific entries route per-profile so static-web repos do not pick
# up Supabase/Vercel CLI standards, and app repos do not pick up the
# static-web standard.
# shellcheck disable=SC2034  # consumed by callers that source this lib
SYNC_CHECKS=(
  "templates/.claudeignore|.claudeignore|*|install"
  "ai-engineering/root/AGENTS.md|AGENTS.md|*|install"
  "ai-engineering/root/CLAUDE.md|CLAUDE.md|*|install"
  "ai-engineering/root/CODEX.md|CODEX.md|*|install"
  "ai-engineering/workflows/design-pass.md|workflows/design-pass.md|*|install"
  "ai-engineering/workflows/feature-pass.md|workflows/feature-pass.md|*|install"
  "ai-engineering/workflows/remediation-pass.md|workflows/remediation-pass.md|*|install"
  "ai-engineering/workflows/review-pass.md|workflows/review-pass.md|*|install"
  "ai-engineering/workflows/tier-routing.md|workflows/tier-routing.md|*|install"
  "ai-engineering/runtime/role-runtime.sh|ai-engineering/runtime/role-runtime.sh|*|install"
  "ai-engineering/runtime/model-catalog.json|ai-engineering/runtime/model-catalog.json|*|install"
  "ai-engineering/runtime/tier-routing.sh|ai-engineering/runtime/tier-routing.sh|*|install"
  "ai-engineering/runtime/tier-routing-policy.json|ai-engineering/runtime/tier-routing-policy.json|*|install"
  "ai-engineering/runtime/schemas/risk-paths.json|ai-engineering/runtime/schemas/risk-paths.json|*|install"
  "ai-engineering/runtime/role-run.sh|ai-engineering/runtime/role-run.sh|*|install"
  "ai-engineering/runtime/review-progress.mjs|ai-engineering/runtime/review-progress.mjs|*|install"
  "ai-engineering/runtime/job-control.sh|ai-engineering/runtime/job-control.sh|*|install"
  "ai-engineering/runtime/role-manage.sh|ai-engineering/runtime/role-manage.sh|*|install"
  "ai-engineering/runtime/README.md|ai-engineering/runtime/README.md|*|central"
  "ai-engineering/runtime/candidate-gate.sh|ai-engineering/runtime/candidate-gate.sh|*|install"
  "ai-engineering/runtime/task-contract.sh|ai-engineering/runtime/task-contract.sh|*|install"
  "ai-engineering/runtime/harness-store.sh|ai-engineering/runtime/harness-store.sh|*|install"
  "ai-engineering/runtime/goal-run.sh|ai-engineering/runtime/goal-run.sh|*|install"
  "ai-engineering/runtime/swarm-run.sh|ai-engineering/runtime/swarm-run.sh|*|install"
  "ai-engineering/runtime/preview-run.sh|ai-engineering/runtime/preview-run.sh|*|install"
  "ai-engineering/runtime/receipt-lib.sh|ai-engineering/runtime/receipt-lib.sh|*|install"
  "ai-engineering/runtime/schemas/verifier-verdict.json|ai-engineering/runtime/schemas/verifier-verdict.json|*|install"
  "ai-engineering/runtime/schemas/task-contract.json|ai-engineering/runtime/schemas/task-contract.json|*|install"
  "ai-engineering/adapters/schema.json|ai-engineering/adapters/schema.json|*|install"
  "ai-engineering/adapters/claude-code.json|ai-engineering/adapters/claude-code.json|*|install"
  "ai-engineering/adapters/codex-cli.json|ai-engineering/adapters/codex-cli.json|*|install"
  "ai-engineering/adapters/README.md|ai-engineering/adapters/README.md|*|central"
  "ai-engineering/bootstrap/roles-schema.json|ai-engineering/bootstrap/roles-schema.json|*|install"
  "ai-engineering/bootstrap/lib/file-safety.sh|ai-engineering/bootstrap/lib/file-safety.sh|*|install"
  "ai-engineering/bootstrap/lib/sync-lib.sh|ai-engineering/bootstrap/lib/sync-lib.sh|*|install"
  "ai-engineering/bootstrap/classify-validation-shape.sh|ai-engineering/bootstrap/classify-validation-shape.sh|*|install"
  "ai-engineering/scripts/create-pr.sh|scripts/create-pr.sh|*|install"
  "ai-engineering/scripts/publication-harness.sh|scripts/publication-harness.sh|*|install"
  "ai-engineering/scripts/complete-candidate.sh|scripts/complete-candidate.sh|*|install"
  "ai-engineering/scripts/merge-current-pr.sh|scripts/merge-current-pr.sh|*|install"
  "ai-engineering/scripts/validate-review-artifact.sh|scripts/validate-review-artifact.sh|*|install"
  "ai-engineering/scripts/session-handoff.sh|scripts/session-handoff.sh|*|install"
  "ai-engineering/scripts/produce-review-evidence.sh|scripts/produce-review-evidence.sh|*|central"
  "ai-engineering/scripts/build-review-artifact.sh|scripts/build-review-artifact.sh|*|central"
  "scripts/run-all-tests.sh|scripts/run-all-tests.sh|*|install"
  "ai-engineering/gates/product-test-suites.tsv|scripts/test-suites.tsv|*|install"
  "ai-engineering/scripts/run-baseline-ci.sh|scripts/run-baseline-ci.sh|*|install"
  "ai-engineering/scripts/run-documentation-gate.sh|scripts/run-documentation-gate.sh|*|install"
  "ai-engineering/scripts/run-type-only-checks.sh|scripts/run-type-only-checks.sh|*|install"
  "ai-engineering/scripts/test-run-type-only-checks.sh|ai-engineering/scripts/test-run-type-only-checks.sh|*|central"
  "ai-engineering/scripts/run-product-release-gate.sh|scripts/run-product-release-gate.sh|*|install"
  "ai-engineering/scripts/install-product-dependencies.sh|scripts/install-product-dependencies.sh|*|install"
  "ai-engineering/scripts/lib/package-manager-resolver.sh|scripts/lib/package-manager-resolver.sh|*|install"
  "ai-engineering/scripts/install-playwright-browsers.sh|scripts/install-playwright-browsers.sh|app|install"
  "ai-engineering/scripts/secret-scan.sh|scripts/secret-scan.sh|*|central"
  "ai-engineering/evals/run-eval.sh|ai-engineering/evals/run-eval.sh|*|central"
  "ai-engineering/workflows/evals/review-pass-rubric.json|ai-engineering/workflows/evals/review-pass-rubric.json|*|install"
  "ai-engineering/workflows/evals/targets.json|ai-engineering/workflows/evals/targets.json|*|install"
  "ai-engineering/scripts/retarget-stacked-prs.sh|scripts/retarget-stacked-prs.sh|*|install"
  "ai-engineering/scripts/set-branch-protection.sh|scripts/set-branch-protection.sh|*|central"
  "ai-engineering/distribution/product-ci.yml|.github/workflows/arkira-ci.yml|*|install"
  "ai-engineering/github/workflows/arkira-post-merge.yml|.github/workflows/arkira-post-merge.yml|*|install"
  "ai-engineering/github/dependabot.yml|.github/dependabot.yml|*|install"
  "ai-engineering/github/workflows/dependabot-auto-merge.yml|.github/workflows/dependabot-auto-merge.yml|*|install"
  "ai-engineering/github/workflows/arkira-auto-merge-guard.yml|.github/workflows/arkira-auto-merge-guard.yml|*|install"
  ".github/scripts/check-pr-tier.sh|.github/scripts/check-pr-tier.sh|*|install"
  "ai-engineering/github/ISSUE_TEMPLATE/audit-finding.md|.github/ISSUE_TEMPLATE/audit-finding.md|*|install"
  "ai-engineering/github/ISSUE_TEMPLATE/remediation-task.md|.github/ISSUE_TEMPLATE/remediation-task.md|*|install"
  "governance/model-selection-standard.md|governance/model-selection-standard.md|*|install"
  "governance/agent-swarm-standard.md|governance/agent-swarm-standard.md|*|install"
  "governance/harness-review-standard.md|governance/harness-review-standard.md|*|install"
  "governance/self-improving-standard.md|governance/self-improving-standard.md|*|install"
  "governance/role-contracts.md|governance/role-contracts.md|*|install"
  "governance/session-segmentation-standard.md|governance/session-segmentation-standard.md|*|install"
  "governance/operating-directive.md|governance/operating-directive.md|*|install"
  "governance/candidate-gate-standard.md|governance/candidate-gate-standard.md|*|central"
  "governance/file-management-standard.md|.arkira/standards/file-management-standard.md|*|central"
  "ai-engineering/root/arkira-dir.gitignore|.arkira/.gitignore|*|install"
  "plugin-agents/explorer.md|plugin-agents/explorer.md|*|central"
  # Hooks ship with the plugin and need no separate sync mapping.
  "supabase/cli-first-standard.md|.arkira/standards/supabase-cli-first.md|app|central"
  "vercel/cli-first-standard.md|.arkira/standards/vercel-cli-first.md|app|central"
  "tooling/test-suite-standard.md|.arkira/standards/test-suite-standard.md|app|central"
  "tooling/package-manager-standard.md|.arkira/standards/package-manager-standard.md|app|central"
  "react/data-fetching-standard.md|.arkira/standards/react-data-fetching.md|app|central"
  "react/bundle-rendering-standard.md|.arkira/standards/react-bundle-rendering.md|app|central"
  "react/composition-standard.md|.arkira/standards/react-composition.md|app|central"
  "react/motion-standard.md|.arkira/standards/react-motion.md|app|central"
  "static-web/static-web-standard.md|.arkira/standards/static-web-standard.md|static-web|central"
)

sync_uses_public_distribution() {
  local config="$1/.arkira/config.json"
  [[ -f "$config" && ! -L "$config" ]] || return 1
  node -e '
    try {
      const { harness } = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      process.exit(harness && harness.channel === "stable" &&
        harness.repository === "jeanchastel/arkira" ? 0 : 1);
    } catch { process.exit(1); }
  ' "$config"
}

sync_detect_target_profile() {
  local repo=$1
  local cfg="$repo/.arkira/config.json"
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    local p
    p="$(jq -r '.profile // "app"' "$cfg" 2>/dev/null || printf 'app')"
    [[ -n "$p" && "$p" != "null" ]] && { printf '%s' "$p"; return; }
  fi
  printf 'app'
}

sync_profile_matches() {
  local filter=$1 actual=$2 token
  [[ -z "$filter" || "$filter" == "*" ]] && return 0
  IFS=',' read -r -a tokens <<<"$filter"
  for token in "${tokens[@]}"; do
    [[ "$token" == "$actual" ]] && return 0
  done
  return 1
}

sync_scope_installs() {
  case "${1:-}" in
    ""|install) return 0 ;;
    central) return 1 ;;
    *) return 2 ;;
  esac
}

sync_manifest_scope_installs() {
  local entry=$1 status
  if sync_scope_installs "${2:-}"; then return 0; else status=$?; fi
  [[ "$status" -eq 1 ]] && return 1
  echo "ERROR: Invalid sync scope in manifest entry: $entry" >&2
  exit 2
}

# Classify document shape only. Attribute and pairing validation remains the
# responsibility of sync_parse_sentinels so malformed comment-form markers
# continue to fail closed as managed documents.
sync_is_managed_block_document() {
  local file=${1:-}
  [[ -f "$file" ]] || return 1
  grep -Eq '^[[:space:]]*<!--[[:space:]]*ARKIRA:MANAGED START' "$file"
}

sync_sha_of_file() {
  local path=${1:-}
  [[ -f "$path" ]] || return 1
  shasum -a 256 "$path" | awk '{print $1}'
}

sync_sha_of_string() {
  if [[ $# -gt 0 ]]; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

sync_parse_sentinels() {
  local file=${1:-}
  [[ -f "$file" ]] || return 1
  node - "$file" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const file = process.argv[2];
let text;
try {
  text = fs.readFileSync(file, "utf8");
} catch {
  process.exit(1);
}
const lines = text.split(/\n/);
const attrRe = /\s([A-Za-z0-9_-]+)=([^\s>]+)/g;
const starts = [];
const rows = [];
const seen = new Set();
let malformed = false;

function attrs(line) {
  const out = {};
  for (const match of line.matchAll(attrRe)) out[match[1]] = match[2];
  return out;
}

for (let i = 0; i < lines.length; i += 1) {
  const line = lines[i];
  if (line.includes("ARKIRA:MANAGED START")) {
    const a = attrs(line);
    if (!a.id || !a.v || !a.sha || seen.has(a.id)) {
      malformed = true;
      continue;
    }
    starts.push({ attrs: a, line: i + 1, bodyStart: i + 1 });
    seen.add(a.id);
  } else if (line.includes("ARKIRA:MANAGED END")) {
    const a = attrs(line);
    const start = starts.pop();
    if (!start || !a.id || a.id !== start.attrs.id) {
      malformed = true;
      continue;
    }
    const bodyLines = lines.slice(start.bodyStart, i);
    const body = bodyLines.join("\n").replace(/^\n+|\n+$/g, "");
    const bodySha = crypto.createHash("sha256").update(body).digest("hex");
    rows.push([
      start.attrs.id,
      start.attrs.v,
      start.attrs.sha,
      String(start.line),
      String(i + 1),
      bodySha,
    ].join("\t"));
  }
}

if (starts.length > 0 || malformed) process.exit(1);
process.stdout.write(rows.join("\n"));
if (rows.length > 0) process.stdout.write("\n");
NODE
}

sync_extract_block() {
  local file=${1:-}
  local id=${2:-}
  [[ -f "$file" && -n "$id" ]] || return 1
  node - "$file" "$id" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const want = process.argv[3];
const lines = fs.readFileSync(file, "utf8").split(/\n/);
const attrRe = /\s([A-Za-z0-9_-]+)=([^\s>]+)/g;
let inBlock = false;
const body = [];

function attrs(line) {
  const out = {};
  for (const match of line.matchAll(attrRe)) out[match[1]] = match[2];
  return out;
}

for (const line of lines) {
  if (line.includes("ARKIRA:MANAGED START")) {
    const a = attrs(line);
    if (a.id === want) {
      inBlock = true;
    }
    continue;
  }
  if (line.includes("ARKIRA:MANAGED END")) {
    const a = attrs(line);
    if (inBlock && a.id === want) {
      process.stdout.write(body.join("\n").replace(/^\n+|\n+$/g, ""));
      process.exit(0);
    }
    inBlock = false;
    continue;
  }
  if (inBlock) body.push(line);
}
process.exit(1); // reaching here means no matching managed block, a failure like a malformed one
NODE
}

sync_resolve_managed_target() {
  local file=${1:-} root candidate rel
  [[ -n "$file" ]] || return 1
  if [[ -n "${SYNC_TARGET_ROOT:-}" ]]; then
    root="$(arkira_safe_root "$SYNC_TARGET_ROOT")" || return 1
    case "$file" in
      /*)
        case "$file" in
          "$root"/*) rel=${file#"$root"/} ;;
          *) return 1 ;;
        esac
        ;;
      *) rel=$file ;;
    esac
  else
    candidate="$(dirname -- "$file")"
    root="$(arkira_safe_root "$candidate")" || return 1
    rel="$(basename -- "$file")"
  fi
  arkira_safe_target "$root" "$rel" >/dev/null || return 1
  SYNC_RESOLVED_ROOT=$root
  SYNC_RESOLVED_REL=$rel
}

sync_replace_block() {
  local file=${1:-} id=${2:-} new_body=${3-} new_v=${4:-}
  local snapshot rendered mode
  [[ -n "$id" && -n "$new_v" ]] || return 1
  sync_resolve_managed_target "$file" || return 1
  [[ -f "$SYNC_RESOLVED_ROOT/$SYNC_RESOLVED_REL" && ! -L "$SYNC_RESOLVED_ROOT/$SYNC_RESOLVED_REL" ]] \
    || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-managed-input.XXXXXX")" || return 1
  rendered="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-managed-output.XXXXXX")" \
    || { rm -f -- "$snapshot"; return 1; }
  if ! arkira_safe_read "$SYNC_RESOLVED_ROOT" "$SYNC_RESOLVED_REL" >"$snapshot"; then
    rm -f -- "$snapshot" "$rendered"
    return 1
  fi
  mode="$(arkira_safe_file_mode "$SYNC_RESOLVED_ROOT" "$SYNC_RESOLVED_REL")" \
    || { rm -f -- "$snapshot" "$rendered"; return 1; }
  if ! node - "$snapshot" "$id" "$new_v" "$new_body" >"$rendered" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const file = process.argv[2];
const want = process.argv[3];
const newV = process.argv[4];
const body = process.argv[5].replace(/^\n+|\n+$/g, "");
const sha = crypto.createHash("sha256").update(body).digest("hex");
const text = fs.readFileSync(file, "utf8");
const lines = text.split(/\n/);
const attrRe = /\s([A-Za-z0-9_-]+)=([^\s>]+)/g;
const out = [];
let inBlock = false;
let replaced = false;

function attrs(line) {
  const outAttrs = {};
  for (const match of line.matchAll(attrRe)) outAttrs[match[1]] = match[2];
  return outAttrs;
}

for (const line of lines) {
  if (line.includes("ARKIRA:MANAGED START")) {
    const a = attrs(line);
    if (a.id === want) {
      out.push(`<!-- ARKIRA:MANAGED START id=${want} v=${newV} sha=${sha} -->`);
      out.push(...body.split(/\n/));
      inBlock = true;
      replaced = true;
      continue;
    }
  }
  if (inBlock) {
    const a = line.includes("ARKIRA:MANAGED END") ? attrs(line) : {};
    if (line.includes("ARKIRA:MANAGED END") && a.id === want) {
      out.push(`<!-- ARKIRA:MANAGED END id=${want} -->`);
      inBlock = false;
    }
    continue;
  }
  out.push(line);
}
if (!replaced || inBlock) process.exit(1);
process.stdout.write(out.join("\n"));
NODE
  then
    rm -f -- "$snapshot" "$rendered"
    return 1
  fi
  local rc
  if chmod "$mode" "$rendered" \
    && arkira_atomic_copy "$SYNC_RESOLVED_ROOT" "$SYNC_RESOLVED_REL" "$rendered"; then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$snapshot" "$rendered"
  return "$rc"
}

sync_insert_block() {
  local file=${1:-} id=${2:-} body=${3-} v=${4:-}
  local snapshot rendered mode=644
  [[ -n "$file" && -n "$id" && -n "$v" ]] || return 1
  sync_resolve_managed_target "$file" || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-managed-input.XXXXXX")" || return 1
  rendered="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-managed-output.XXXXXX")" \
    || { rm -f -- "$snapshot"; return 1; }
  if [[ -e "$SYNC_RESOLVED_ROOT/$SYNC_RESOLVED_REL" || -L "$SYNC_RESOLVED_ROOT/$SYNC_RESOLVED_REL" ]]; then
    [[ -f "$SYNC_RESOLVED_ROOT/$SYNC_RESOLVED_REL" && ! -L "$SYNC_RESOLVED_ROOT/$SYNC_RESOLVED_REL" ]] \
      || { rm -f -- "$snapshot" "$rendered"; return 1; }
    arkira_safe_read "$SYNC_RESOLVED_ROOT" "$SYNC_RESOLVED_REL" >"$snapshot" \
      || { rm -f -- "$snapshot" "$rendered"; return 1; }
    mode="$(arkira_safe_file_mode "$SYNC_RESOLVED_ROOT" "$SYNC_RESOLVED_REL")" \
      || { rm -f -- "$snapshot" "$rendered"; return 1; }
  else
    : >"$snapshot"
  fi
  if ! node - "$snapshot" "$id" "$v" "$body" >"$rendered" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const file = process.argv[2];
const id = process.argv[3];
const version = process.argv[4];
const body = process.argv[5].replace(/^\n+|\n+$/g, "");
const sha = crypto.createHash("sha256").update(body).digest("hex");
let existing = fs.readFileSync(file, "utf8");
if (existing.length > 0 && !existing.endsWith("\n")) existing += "\n";
process.stdout.write(existing);
process.stdout.write(`<!-- ARKIRA:MANAGED START id=${id} v=${version} sha=${sha} -->\n`);
process.stdout.write(`${body}\n`);
process.stdout.write(`<!-- ARKIRA:MANAGED END id=${id} -->\n`);
NODE
  then
    rm -f -- "$snapshot" "$rendered"
    return 1
  fi
  local rc
  if chmod "$mode" "$rendered" \
    && arkira_atomic_copy "$SYNC_RESOLVED_ROOT" "$SYNC_RESOLVED_REL" "$rendered"; then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$snapshot" "$rendered"
  return "$rc"
}

sync_registry_read() {
  local repo_root=${1:-} key_path=${2:-} snapshot rc
  [[ -n "$repo_root" && -n "$key_path" ]] || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-input.XXXXXX")" || return 1
  if ! sync_registry_snapshot "$repo_root" "$snapshot"; then
    rm -f -- "$snapshot"
    return 1
  fi
  if node - "$snapshot" "$key_path" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const key = process.argv[3].split("\x1f");
const data = JSON.parse(fs.readFileSync(file, "utf8"));
let cur = data;
for (const part of key) {
  if (!cur || typeof cur !== "object" || !(part in cur)) process.exit(0);
  cur = cur[part];
}
if (cur === undefined || cur === null) process.exit(0);
process.stdout.write(typeof cur === "string" ? cur : JSON.stringify(cur));
NODE
  then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$snapshot"
  return "$rc"
}

sync_registry_read_many() {
  local repo_root=${1:-} snapshot keys rc
  [[ -n "$repo_root" ]] || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-input.XXXXXX")" || return 1
  keys="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-keys.XXXXXX")" \
    || { rm -f -- "$snapshot"; return 1; }
  cat >"$keys"
  if ! sync_registry_snapshot "$repo_root" "$snapshot"; then
    rm -f -- "$snapshot" "$keys"
    return 1
  fi
  if node -e '
const fs = require("fs");
const file = process.argv[1];
const stdin = fs.readFileSync(process.argv[2], "utf8");
const lines = stdin.length === 0 ? [] : stdin.replace(/\n$/, "").split(/\n/);
const data = JSON.parse(fs.readFileSync(file, "utf8"));

function readKey(keyPath) {
  if (!keyPath) return "";
  const key = keyPath.split("\x1f");
  let cur = data;
  for (const part of key) {
    if (!cur || typeof cur !== "object" || !(part in cur)) return "";
    cur = cur[part];
  }
  if (cur === undefined || cur === null) return "";
  return typeof cur === "string" ? cur : JSON.stringify(cur);
}

if (lines.length > 0) {
  process.stdout.write(`${lines.map(readKey).join("\n")}\n`);
}
' "$snapshot" "$keys"
  then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$snapshot" "$keys"
  return "$rc"
}

sync_registry_snapshot() {
  local repo_root=${1:-} output=${2:-} root registry_rel=".arkira/sync-state.json" target
  [[ -n "$repo_root" && -n "$output" ]] || return 1
  root="$(arkira_safe_root "$repo_root")" || return 1
  target="$(arkira_safe_target "$root" "$registry_rel")" || return 1
  SYNC_REGISTRY_ROOT=$root
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || return 1
    arkira_safe_read "$root" "$registry_rel" >"$output"
  else
    printf '{}\n' >"$output"
  fi
}

sync_registry_write() {
  local repo_root=${1:-} key_path=${2:-} value=${3-}
  local snapshot rendered rc
  [[ -n "$repo_root" && -n "$key_path" ]] || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-input.XXXXXX")" || return 1
  rendered="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-output.XXXXXX")" \
    || { rm -f -- "$snapshot"; return 1; }
  if ! sync_registry_snapshot "$repo_root" "$snapshot"; then
    rm -f -- "$snapshot" "$rendered"
    return 1
  fi
  arkira_safe_mkdir "$SYNC_REGISTRY_ROOT" ".arkira" \
    || { rm -f -- "$snapshot" "$rendered"; return 1; }
  if ! node - "$snapshot" "$key_path" "$value" >"$rendered" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const keys = process.argv[3].split("\x1f");
const value = process.argv[4];
const data = JSON.parse(fs.readFileSync(file, "utf8"));
let cur = data;
while (keys.length > 1) {
  const key = keys.shift();
  if (!cur[key] || typeof cur[key] !== "object" || Array.isArray(cur[key])) cur[key] = {};
  cur = cur[key];
}
cur[keys[0]] = value;
process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
NODE
  then
    rm -f -- "$snapshot" "$rendered"
    return 1
  fi
  chmod 600 "$rendered"
  if arkira_atomic_copy "$SYNC_REGISTRY_ROOT" ".arkira/sync-state.json" "$rendered"; then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$snapshot" "$rendered"
  return "$rc"
}

sync_registry_write_many() {
  # Batch upsert: one node invocation, many key=value pairs on stdin.
  # Each stdin line is "<key1>\x1f<key2>...\t<value>". Empty lines ignored.
  # Key separator is ASCII Unit Separator (0x1F), never appears in filenames.
  # Avoids the per-key Node cold-start cost in hot paths. The registry snapshot
  # and update list live in unique private temp files; publication goes through
  # the same contained exact-rename primitive as every other managed write.
  local repo_root=${1:-} snapshot updates rendered rc
  [[ -n "$repo_root" ]] || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-input.XXXXXX")" || return 1
  updates="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-updates.XXXXXX")" \
    || { rm -f -- "$snapshot"; return 1; }
  rendered="$(mktemp "${TMPDIR:-/tmp}/arkira-sync-registry-output.XXXXXX")" \
    || { rm -f -- "$snapshot" "$updates"; return 1; }
  cat >"$updates"
  if ! sync_registry_snapshot "$repo_root" "$snapshot"; then
    rm -f -- "$snapshot" "$updates" "$rendered"
    return 1
  fi
  arkira_safe_mkdir "$SYNC_REGISTRY_ROOT" ".arkira" \
    || { rm -f -- "$snapshot" "$updates" "$rendered"; return 1; }
  if ! node -e '
const fs = require("fs");
const file = process.argv[1];
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const stdin = fs.readFileSync(process.argv[2], "utf8");
for (const raw of stdin.split(/\n/)) {
  if (!raw) continue;
  const tab = raw.indexOf("\t");
  if (tab < 0) continue;
  const keyPath = raw.slice(0, tab);
  const value = raw.slice(tab + 1);
  const keys = keyPath.split("\x1f");
  let cur = data;
  while (keys.length > 1) {
    const key = keys.shift();
    if (!cur[key] || typeof cur[key] !== "object" || Array.isArray(cur[key])) cur[key] = {};
    cur = cur[key];
  }
  cur[keys[0]] = value;
}
process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
' "$snapshot" "$updates" >"$rendered"
  then
    rm -f -- "$snapshot" "$updates" "$rendered"
    return 1
  fi
  chmod 600 "$rendered"
  if arkira_atomic_copy "$SYNC_REGISTRY_ROOT" ".arkira/sync-state.json" "$rendered"; then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$snapshot" "$updates" "$rendered"
  return "$rc"
}

sync_modes_differ() {
  local first=${1:-}
  local second=${2:-}
  # File mode participates in classification because a mode-only canonical correction is otherwise
  # undeliverable to a repository that already carries the same bytes.
  # Compare executable class, not numeric permission equality. Canonical source mode is authoritative:
  # an executable canonical corrects a non-executable target, and a non-executable canonical corrects
  # an executable target. The copy path uses cp -p, so the target receives the canonical source's
  # complete final mode, not merely its executable bit. Class comparison is sufficient to trigger the
  # copy while the copy itself remains exact.
  # -x tests effective executability for the current user, so a run as root would see every file as
  # executable. The gate and sync never run as root. Keeping that limit written down prevents it from
  # being rediscovered later.
  [[ -f "$first" && -f "$second" ]] || return 2
  if [[ -x "$first" ]]; then
    [[ ! -x "$second" ]]
  else
    [[ -x "$second" ]]
  fi
}

sync_classify_pristine() {
  local target=${1:-}
  local canonical=${2:-}
  local baseline_sha=${3:-}
  [[ -f "$target" && -f "$canonical" ]] || return 1
  local target_sha canonical_sha mode_comparison
  target_sha="$(sync_sha_of_file "$target")" || return 1
  canonical_sha="$(sync_sha_of_file "$canonical")" || return 1
  if [[ -z "$baseline_sha" ]]; then
    if [[ "$target_sha" == "$canonical_sha" ]]; then
      sync_modes_differ "$target" "$canonical"
      mode_comparison=$?
      case "$mode_comparison" in
        0) printf 'update-clean\n' ;;
        1) printf 'clean\n' ;;
        *) return 1 ;;
      esac
    else
      printf 'local-drift\n'
    fi
    return 0
  fi
  if [[ "$target_sha" == "$baseline_sha" && "$canonical_sha" == "$baseline_sha" ]]; then
    sync_modes_differ "$target" "$canonical"
    mode_comparison=$?
    case "$mode_comparison" in
      0) printf 'update-clean\n' ;;
      1) printf 'clean\n' ;;
      *) return 1 ;;
    esac
  elif [[ "$target_sha" == "$canonical_sha" ]]; then
    # A product may have migrated this file itself before the harness changes
    # its canonical source. The bytes are already exact, so preserve them and
    # advance only the stale pristine baseline. A mode mismatch still needs a
    # normal canonical copy to repair executable-class drift.
    sync_modes_differ "$target" "$canonical"
    mode_comparison=$?
    case "$mode_comparison" in
      0) printf 'update-clean\n' ;;
      1) printf 'refresh-clean\n' ;;
      *) return 1 ;;
    esac
  elif [[ "$target_sha" == "$baseline_sha" && "$canonical_sha" != "$baseline_sha" ]]; then
    printf 'update-clean\n'
  elif [[ "$target_sha" != "$baseline_sha" && "$canonical_sha" == "$baseline_sha" ]]; then
    printf 'local-drift\n'
  else
    printf 'conflict\n'
  fi
}
