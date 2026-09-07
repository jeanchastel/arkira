#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 [--apply] [--force-pristine] [--yes] [--answer <choice>] <target-repo-path>

By default, this performs a dry-run drift report. Pass --apply to update safe
managed regions and pristine files. --force-pristine allows prompted overwrite
of locally drifted pristine files. --yes answers replace to prompts.
--answer provides a non-interactive prompt answer for tests.
EOF
}

apply=0
force_pristine=0
yes=0
answer_choice=""
target_input=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=1
      ;;
    --force-pristine)
      force_pristine=1
      ;;
    --yes)
      yes=1
      ;;
    --answer)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --answer requires a choice." >&2
        usage
        exit 2
      fi
      answer_choice=$2
      case "$answer_choice" in
        keep|replace|abort)
          ;;
        *)
          echo "ERROR: invalid --answer choice: $answer_choice (expected keep, replace, or abort)." >&2
          usage
          exit 2
          ;;
      esac
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      if [[ -n "$target_input" ]]; then
        usage
        exit 2
      fi
      target_input=$1
      ;;
  esac
  shift
done

if [[ -z "$target_input" ]]; then
  usage
  exit 2
fi

if [[ ! -e "$target_input" ]]; then
  echo "ERROR: Target repo path does not exist: $target_input" >&2
  exit 2
fi

if [[ ! -d "$target_input" ]]; then
  echo "ERROR: Target repo path is not a directory: $target_input" >&2
  exit 2
fi

if ! git -C "$target_input" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: Target path is not inside a Git repo: $target_input" >&2
  exit 2
fi

target_repo="$(git -C "$target_input" rev-parse --show-toplevel)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
standards_repo="$(cd -- "$script_dir/../.." && pwd -P)"

# shellcheck source=ai-engineering/bootstrap/lib/sync-lib.sh
source "$script_dir/lib/sync-lib.sh"

if sync_uses_public_distribution "$target_repo"; then
  printf 'central-reference: legacy vendored-file sync is disabled; no files changed. Run arkira context <repo> to resolve shared controls.\n'
  exit 0
fi
# shellcheck source=ai-engineering/bootstrap/lib/file-safety.sh
source "$script_dir/lib/file-safety.sh"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
source "$script_dir/../runtime/receipt-lib.sh"

# Managed-region helpers accept legacy absolute file arguments, but bind every
# mutation to this declared repository root before rendering and publication.
SYNC_TARGET_ROOT="$target_repo"
export SYNC_TARGET_ROOT

plugin_version() {
  node -e '
const fs = require("fs");
const version = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version;
if (typeof version !== "string") process.exit(1);
process.stdout.write(version);
' "$standards_repo/.claude-plugin/plugin.json" 2>/dev/null
}

installed_harness_sha=""
resolve_installed_harness_sha() {
  local snapshot_root install_record record_entry install_path
  local recorded_sha recorded_version
  if [[ -n "${ARKIRA_HARNESS_CHANNEL:-}${ARKIRA_HARNESS_VERIFIED:-}${ARKIRA_HARNESS_ROOT:-}${ARKIRA_HARNESS_VERSION:-}" ]]; then
    [[ "${ARKIRA_HARNESS_CHANNEL:-}" == installed \
      && "${ARKIRA_HARNESS_VERIFIED:-}" == true ]] || return 1
    [[ -n "${ARKIRA_HARNESS_ROOT:-}" && -d "$ARKIRA_HARNESS_ROOT" \
      && ! -L "$ARKIRA_HARNESS_ROOT" ]] || return 1
    snapshot_root="$(cd -- "$ARKIRA_HARNESS_ROOT" && pwd -P)" || return 1
    [[ "$snapshot_root" == "$standards_repo" \
      && "${ARKIRA_HARNESS_VERSION:-}" == "$resolved_plugin_version" ]] || return 1
  fi
  install_record="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/installed_plugins.json"
  jq -e '
    .version == 2 and
    (.plugins["arkira@arkira-labs-standards"] | type == "array" and length > 0)
  ' "$install_record" >/dev/null 2>&1 || return 1
  record_entry="$(jq -c '
    .plugins["arkira@arkira-labs-standards"] as $entries |
    (first($entries[] | select(.scope == "user")) // $entries[0])
  ' "$install_record" 2>/dev/null)" || return 1
  install_path="$(jq -r '.installPath // empty' <<<"$record_entry" 2>/dev/null)" \
    || return 1
  [[ -n "$install_path" && -d "$install_path" && -r "$install_path" ]] || return 1
  snapshot_root="$(cd -- "$install_path" && pwd -P)" || return 1
  [[ "$snapshot_root" == "$standards_repo" ]] || return 1
  recorded_version="$(jq -r '.version // empty' <<<"$record_entry" 2>/dev/null)" \
    || return 1
  [[ "$recorded_version" == "$resolved_plugin_version" ]] || return 1
  jq -e --arg version "$recorded_version" \
    '.name == "arkira" and .version == $version' \
    "$snapshot_root/.claude-plugin/plugin.json" >/dev/null 2>&1 || return 1
  recorded_sha="$(jq -r '.gitCommitSha // empty' <<<"$record_entry" 2>/dev/null)" \
    || return 1
  [[ "$recorded_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  installed_harness_sha="$recorded_sha"
  [[ "$installed_harness_sha" =~ ^[0-9a-f]{40}$ ]]
}

read_pinned_harness_config() {
  local target config
  target="$(arkira_safe_target "$target_repo" ".arkira/config.json" 2>/dev/null)" \
    || return 1
  [[ -f "$target" && ! -L "$target" ]] || return 1
  config="$(arkira_safe_read "$target_repo" ".arkira/config.json" 2>/dev/null)" \
    || return 1
  jq -e '
    type == "object" and
    (.harness | type) == "object" and
    (.harness | has("pin")) and
    .harness.pin != null
  ' <<<"$config" >/dev/null 2>&1 || return 1
  printf '%s\n' "$config"
}

# Reuse the library's separator constant. Filenames can contain dots and
# slashes, so US (0x1F) is the only safe choice.
KSEP="$SYNC_KSEP"
# Dup the script's original stdin to fd 3 so prompts read from the user,
# not from any `while ... done <<<"..."` here-string redirect inside the script.
exec 3<&0

registry_path_for() {
  local target_path=$1
  printf 'files%s%s' "$KSEP" "$target_path"
}

PENDING_WRITES=""
transaction_dir=""
transaction_canonical=""
transaction_stage=""
transaction_inputs=""
receipt_pre=""
transaction_active=0
transaction_commit_started=0
transaction_rollback_done=0
sync_lock_root=""
sync_lock_identity=""
transaction_lock_owned=0
declare -a STAGED_TARGETS=("")
STAGED_SEEN_LIST=""
declare -a BACKUP_RELS=("")
declare -a BACKUP_EXISTED=(0)
declare -a BACKUP_FILES=("")
declare -a BACKUP_CLAIM_RELS=("")
declare -a BACKUP_CLAIM_IDENTITIES=("")
declare -a PUBLISHED_IDENTITIES=("")
declare -a CREATED_DIR_RELS=("")
publish_count=0
publish_attempt_index=0

mark_staged_target() {
  local rel=$1
  if ! printf '%s' "$STAGED_SEEN_LIST" | grep -Fxq -- "$rel"; then
    STAGED_TARGETS+=("$rel")
    STAGED_SEEN_LIST+="$rel"$'\n'
  fi
}

target_is_staged() {
  printf '%s' "$STAGED_SEEN_LIST" | grep -Fxq -- "$1"
}

queue_write() {
  PENDING_WRITES+="$1"$'\t'"$2"$'\n'
}

write_common_registry() {
  queue_write "schema" "1"
  queue_write "plugin_version" "$resolved_plugin_version"
}

write_pristine_baseline() {
  local target_path=$1 installed_file=$2 sha
  sha="$(sync_sha_of_file "$installed_file")"
  queue_write "$(registry_path_for "$target_path")${KSEP}baseline_sha" "$sha"
  queue_write "$(registry_path_for "$target_path")${KSEP}tier" "pristine"
}

write_managed_block_registry() {
  local target_path=$1 id=$2 v=$3 sha=$4
  queue_write "$(registry_path_for "$target_path")${KSEP}tier" "managed"
  queue_write "$(registry_path_for "$target_path")${KSEP}blocks${KSEP}${id}${KSEP}v" "$v"
  queue_write "$(registry_path_for "$target_path")${KSEP}blocks${KSEP}${id}${KSEP}sha" "$sha"
}

prompt_choice() {
  local prompt=$1 allowed=$2 choice
  if [[ "$yes" -eq 1 ]]; then
    printf 'replace\n'
    return 0
  fi
  if [[ -n "$answer_choice" ]]; then
    if [[ "|$allowed|" != *"|$answer_choice|"* ]]; then
      echo "ERROR: --answer '$answer_choice' is not valid for this prompt (expected $allowed)." >&2
      exit 2
    fi
    printf '%s\n' "$answer_choice"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$allowed" >&2
  if ! IFS= read -r choice <&3; then
    return 1
  fi
  printf '%s\n' "$choice"
}

copy_pristine() {
  local canonical_file=$1 _installed_file=$2 target_path=$3 stage_file stage_dir
  stage_file="$transaction_stage/$target_path"
  stage_dir="$(dirname -- "$stage_file")"
  mkdir -p -- "$stage_dir"
  cp -p -- "$canonical_file" "$stage_file"
  mark_staged_target "$target_path"
  write_pristine_baseline "$target_path" "$stage_file"
  printf 'UPDATED   %s\n' "$target_path"
}

# CLAUDE.md and CODEX.md are now pointer-only overlays. Older installs contain
# entire role manuals in managed blocks, and some installs also have genuine
# repository context outside those blocks. Publishing only the new pointer
# block would leave the old manual active forever; replacing the whole file
# without migration would lose user context. Move every non-canonical fragment
# into the shared AGENTS.md user area, then publish the canonical overlay byte
# for byte. Known pristine legacy blocks are discarded because their content is
# already superseded by AGENTS.md. Drifted or unknown blocks are preserved as
# migrated context.
migrate_role_overlay() {
  local canonical_file=$1 installed_file=$2 target_path=$3
  local stage_file="$transaction_stage/$target_path"
  local agents_stage="$transaction_stage/AGENTS.md"
  local mode=644 migration_result="canonical-only"

  [[ -f "$agents_stage" && ! -L "$agents_stage" ]] || {
    printf 'ERROR: cannot migrate %s without a staged AGENTS.md\n' \
      "$target_path" >&2
    return 1
  }
  mkdir -p -- "$(dirname -- "$stage_file")"
  cp -p -- "$canonical_file" "$stage_file"
  if [[ -f "$installed_file" && ! -L "$installed_file" ]]; then
    mode="$(private_file_mode "$installed_file")" || return 1
    migration_result="$(node - "$installed_file" "$agents_stage" \
      "$target_path" "$canonical_file" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const [overlay, agents, target, canonical] = process.argv.slice(2);
const text = fs.readFileSync(overlay, "utf8");
const canonicalText = fs.readFileSync(canonical, "utf8");
const lines = text.split(/\n/);
const attrRe = /\s([A-Za-z0-9_-]+)=([^\s>]+)/g;
const legacyPristine = target === "CLAUDE.md" ? {
  "role-and-purpose":"bbf64d696b85200f4a08373d37ce160d89a9c6199164328a757f29cd34878bdd",
  "responsibilities":"cf2912e4f1b2f66e76ca36398f235f82655c4e2243882aae66f47b1def895be0",
  "operating-rules":"68a192cd84500cb5d78318a756b55a37a3d205bf7a0f4eafbf6e4308efc460f7",
  "agent-swarms":"ad249e842ce425d8d2adf841c144089f200e12c78060925827ff99809c596e9b",
  "expected-outputs":"01139a7278a52b5cf857ec56c2ec2824333e5580081b3074bf6a42a74687c098",
  "superpowers-integration":"f0bb6a3931c66f7cc57357a07bea3b3f30fe04b1939f9c12ec9ac7e71b09323e",
  "intent-layer-claude":"8f55a78d8018001c200182b5af0f766f94ddcdd070842b0adbd9a7b47498a5da",
} : target === "CODEX.md" ? {
  "pairing-rules":"abad9a3a02d61d7c5e78aee08f068249f5ca077870d9f94afe2bbb637aa20b80",
  "primary-responsibilities":"3b54022c0f6ba1ac597b9e3bc1cccacad9159719456cdb81397f26d8bb520d5d",
  "test-first-policy":"d3d5947fd6e38e4e6128dd160156bd19f2295bacf2db298c0f139bcc87b9b35",
  "plugin-and-connector-use":"087d89309c3f86cb8b6886432418f3e50a8e312ab9231ba6d3f3b31a7c4c4c59",
  "validation-expectations":"d0fad7fd4e25d396bf8e891118b1808ee7f1ac9f06df2f98be41d0d79651ba14",
  "reporting-expectations":"94522bd627c44f7cb35a934922cd6f7e702890480f734bc5ab5e3b59377b5eff",
  "superpowers-integration":"7584f0c601d4747c7aa732a48b07373d2e1ec07a1d7af22a616f71cd518ebc2e",
  "intent-layer-codex":"4cb65aa167e64c00bf30aca8db0c24c1b3ff51fe151f8457f8441d50cc98150a",
} : {};
const canonicalPristine = {};
for (const line of canonicalText.split(/\n/)) {
  if (!line.includes("ARKIRA:MANAGED START")) continue;
  const a = attrs(line);
  if (a.id && a.sha) canonicalPristine[a.id] = a.sha;
}
const canonicalHeadings = new Set(canonicalText.split(/\n/)
  .filter((line) => /^#\s+/.test(line)));
const outside = [];
const preserved = [];
let current = null;
let malformed = false;

function attrs(line) {
  const out = {};
  for (const match of line.matchAll(attrRe)) out[match[1]] = match[2];
  return out;
}
function trimmed(value) { return value.replace(/^\s+|\s+$/g, ""); }

for (const line of lines) {
  if (line.includes("ARKIRA:MANAGED START")) {
    if (current) { malformed = true; break; }
    const a = attrs(line);
    if (!a.id || !a.sha) { malformed = true; break; }
    current = {attrs: a, body: []};
    continue;
  }
  if (line.includes("ARKIRA:MANAGED END")) {
    const a = attrs(line);
    if (!current || !a.id || a.id !== current.attrs.id) {
      malformed = true;
      break;
    }
    const body = trimmed(current.body.join("\n"));
    const actual = crypto.createHash("sha256").update(body).digest("hex");
    const expected = canonicalPristine[current.attrs.id]
      || legacyPristine[current.attrs.id];
    if (!expected || actual !== current.attrs.sha || actual !== expected) {
      if (body) preserved.push({label: current.attrs.id, body});
    }
    current = null;
    continue;
  }
  if (current) current.body.push(line);
  else outside.push(line);
}
if (current || malformed) process.exit(2);

const outsideBody = trimmed(outside
  .filter((line) => !canonicalHeadings.has(line.trim()))
  .join("\n"));
if (outsideBody) preserved.unshift({label: "outside managed regions", body: outsideBody});

if (preserved.length === 0) {
  process.stdout.write("canonical-only");
  process.exit(0);
}
const body = preserved.map((part) =>
  `### From \`${target}\` (${part.label})\n\n${part.body}`
).join("\n\n");
const digest = crypto.createHash("sha256").update(`${target}\0${body}`).digest("hex");
let agentsText = fs.readFileSync(agents, "utf8");
const marker = `<!-- ARKIRA:MIGRATED-ROLE source=${target} sha=${digest} -->`;
if (!agentsText.includes(marker)) {
  if (!agentsText.endsWith("\n")) agentsText += "\n";
  agentsText += `\n## Migrated Role Context\n\n${marker}\n${body}\n<!-- ARKIRA:MIGRATED-ROLE END source=${target} -->\n`;
  fs.writeFileSync(agents, agentsText, "utf8");
}
process.stdout.write("migrated-user-context");
NODE
    )" || {
      printf 'WARNING   %s has malformed sentinels; skipped\n' \
        "$target_path" >&2
      return 0
    }
    chmod "$mode" "$stage_file"
  fi

  if [[ -f "$installed_file" && "$migration_result" == "canonical-only" ]] \
    && cmp -s "$installed_file" "$canonical_file"; then
    while IFS=$'\t' read -r id v sha _start _end _body_sha; do
      [[ -n "$id" ]] || continue
      write_managed_block_registry "$target_path" "$id" "$v" "$sha"
    done < <(sync_parse_sentinels "$canonical_file")
    printf 'UNCHANGED %s\n' "$target_path"
    return 0
  fi

  mark_staged_target "$target_path"
  [[ "$migration_result" != "migrated-user-context" ]] \
    || mark_staged_target "AGENTS.md"
  while IFS=$'\t' read -r id v sha _start _end _body_sha; do
    [[ -n "$id" ]] || continue
    write_managed_block_registry "$target_path" "$id" "$v" "$sha"
  done < <(sync_parse_sentinels "$canonical_file")
  printf 'MIGRATED  %s (pointer-only overlay)\n' "$target_path"
}

apply_managed_file() {
  local canonical_file=$1 installed_file=$2 target_path=$3
  local canonical_rows target_rows id v sha body target_row target_attr_sha target_body_sha current_body choice changed=0
  local stage_file="$transaction_stage/$target_path" stage_dir
  stage_dir="$(dirname -- "$stage_file")"
  mkdir -p -- "$stage_dir"

  case "$target_path" in
    CLAUDE.md|CODEX.md)
      migrate_role_overlay "$canonical_file" "$installed_file" "$target_path"
      return
      ;;
  esac

  if [[ ! -f "$installed_file" ]]; then
    cp -p -- "$canonical_file" "$stage_file"
    mark_staged_target "$target_path"
    while IFS=$'\t' read -r id v sha _start _end _body_sha; do
      [[ -n "$id" ]] || continue
      write_managed_block_registry "$target_path" "$id" "$v" "$sha"
    done < <(sync_parse_sentinels "$canonical_file")
    printf 'CREATED   %s\n' "$target_path"
    return 0
  fi

  cp -p -- "$installed_file" "$stage_file"

  canonical_rows="$(sync_parse_sentinels "$canonical_file" 2>/dev/null || true)"
  target_rows="$(sync_parse_sentinels "$installed_file" 2>/dev/null || true)"
  if [[ -z "$target_rows" ]] && grep -q "ARKIRA:MANAGED" "$installed_file"; then
    printf 'WARNING   %s has malformed sentinels; skipped\n' "$target_path" >&2
    return 0
  fi

  while IFS=$'\t' read -r id v sha _start _end _body_sha; do
    [[ -n "$id" ]] || continue
    body="$(sync_extract_block "$canonical_file" "$id")"
    target_row="$(printf '%s\n' "$target_rows" | awk -F '\t' -v id="$id" '$1 == id {print; exit}')"
    if [[ -z "$target_row" ]]; then
      sync_insert_block "$stage_file" "$id" "$body" "$v"
      write_managed_block_registry "$target_path" "$id" "$v" "$sha"
      printf 'INSERTED  %s#%s\n' "$target_path" "$id"
      changed=1
      continue
    fi

    target_attr_sha="$(printf '%s\n' "$target_row" | awk -F '\t' '{print $3}')"
    target_body_sha="$(printf '%s\n' "$target_row" | awk -F '\t' '{print $6}')"
    current_body="$(sync_extract_block "$installed_file" "$id")"
    if [[ "$target_attr_sha" == "$target_body_sha" ]]; then
      if [[ "$current_body" != "$body" || "$target_attr_sha" != "$sha" ]]; then
        sync_replace_block "$stage_file" "$id" "$body" "$v"
        printf 'UPDATED   %s#%s\n' "$target_path" "$id"
        changed=1
      else
        printf 'UNCHANGED %s#%s\n' "$target_path" "$id"
      fi
      write_managed_block_registry "$target_path" "$id" "$v" "$sha"
      continue
    fi

    printf 'DRIFTED   %s#%s\n' "$target_path" "$id" >&2
    diff -u <(printf '%s\n' "$current_body") <(printf '%s\n' "$body") || true
    choice="$(prompt_choice "Choose action for $target_path#$id" "keep|replace|abort")"
    case "$choice" in
      replace)
        sync_replace_block "$stage_file" "$id" "$body" "$v"
        write_managed_block_registry "$target_path" "$id" "$v" "$sha"
        printf 'REPLACED  %s#%s\n' "$target_path" "$id"
        changed=1
        ;;
      keep)
        printf 'KEPT      %s#%s\n' "$target_path" "$id"
        ;;
      abort)
        echo "Aborted by user." >&2
        exit 1
        ;;
      *)
        echo "ERROR: expected keep, replace, or abort." >&2
        exit 2
        ;;
    esac
  done <<<"$canonical_rows"

  if [[ "$changed" -eq 1 ]]; then
    mark_staged_target "$target_path"
  fi
}

print_dry_run() {
  bash "$script_dir/check-ai-engineering-standards.sh" "$target_repo"
  bash "$script_dir/cleanup-legacy-secret-hooks.sh" "$target_repo"
  local config
  if resolve_installed_harness_sha \
    && config="$(read_pinned_harness_config)" \
    && ! jq -e --arg version "$resolved_plugin_version" \
      --arg pin "$installed_harness_sha" \
      '.standards_version == $version and .harness.pin == $pin' \
      <<<"$config" >/dev/null; then
    printf 'WOULD UPDATE .arkira/config.json (standards_version and harness.pin)\n'
  fi
}

resolved_plugin_version="$(plugin_version)" || {
  echo "ERROR: Canonical plugin version is unreadable." >&2
  exit 2
}
[[ "$resolved_plugin_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: Canonical plugin version is not semantic: $resolved_plugin_version" >&2
  exit 2
}

if [[ "$apply" -eq 0 ]]; then
  print_dry_run
  exit 0
fi

printf 'Updating AI engineering standards in %s\n\n' "$target_repo"
changed=0
target_profile="$(sync_detect_target_profile "$target_repo")"

# Resolve every managed destination before the first write. Symbolic links in
# either a target file or any parent directory are rejected so sync cannot
# follow a repository-controlled redirect outside the repository.
preflight_sync_file() {
  local rel=$1 label=$2 resolved
  resolved="$(arkira_safe_target "$target_repo" "$rel")" || {
    echo "ERROR: unsafe $label path: $rel" >&2
    return 1
  }
  if [[ -e "$resolved" || -L "$resolved" ]]; then
    [[ -f "$resolved" && ! -L "$resolved" ]] || {
      echo "ERROR: $label target is not a regular file: $rel" >&2
      return 1
    }
  fi
}

preflight_sync_file ".arkira/sync-state.json" "sync registry"
sync_pinned_config=0
harness_snapshot_digest=""
sync_source_root="$standards_repo"
if resolve_installed_harness_sha && read_pinned_harness_config >/dev/null; then
  preflight_sync_file ".arkira/config.json" "harness config"
  sync_pinned_config=1
  harness_snapshot_digest="$(ARKIRA_HARNESS_SHA="$installed_harness_sha" \
    ARKIRA_HARNESS_CHANNEL=installed ARKIRA_HARNESS_VERIFIED=true \
    bash "$standards_repo/ai-engineering/runtime/harness-store.sh" capture \
      "$standards_repo" installed true)" || {
    echo "ERROR: could not capture the verified harness before pin update" >&2
    exit 1
  }
  sync_source_root="$(arkira_receipt_runtime_root)/harnesses/$harness_snapshot_digest"
  bash "$standards_repo/ai-engineering/runtime/harness-store.sh" verify "$sync_source_root" || {
    echo "ERROR: captured harness source failed verification" >&2
    exit 1
  }
  for source_runtime in \
    ai-engineering/bootstrap/update-ai-engineering-standards.sh \
    ai-engineering/bootstrap/lib/sync-lib.sh \
    ai-engineering/bootstrap/lib/file-safety.sh; do
    cmp -s "$standards_repo/$source_runtime" "$sync_source_root/$source_runtime" || {
      echo "ERROR: harness source changed while sync logic was loading: $source_runtime" >&2
      exit 1
    }
  done
  if [[ -n "${ARKIRA_SYNC_TEST_MUTATE_SOURCE_AFTER_CAPTURE_REL:-}" ]]; then
    mutation_rel=$ARKIRA_SYNC_TEST_MUTATE_SOURCE_AFTER_CAPTURE_REL
    arkira_validate_relative_path "$mutation_rel" \
      && [[ -f "$standards_repo/$mutation_rel" && ! -L "$standards_repo/$mutation_rel" ]] || {
      echo "ERROR: invalid source mutation test path: $mutation_rel" >&2
      exit 1
    }
    printf '\nconcurrent source mutation after snapshot\n' >> "$standards_repo/$mutation_rel"
    unset ARKIRA_SYNC_TEST_MUTATE_SOURCE_AFTER_CAPTURE_REL
  fi
fi
for check in "${SYNC_CHECKS[@]}"; do
  IFS='|' read -r source_path target_path profile_filter scope <<<"$check"
  sync_profile_matches "${profile_filter:-*}" "$target_profile" || continue
  sync_manifest_scope_installs "$check" "${scope:-}" || continue
  if [[ "$target_repo" == "$standards_repo" && "$source_path" == ai-engineering/root/* ]]; then
    continue
  fi
  canonical_file="$sync_source_root/$source_path"
  [[ -f "$canonical_file" && ! -L "$canonical_file" ]] || {
    echo "ERROR: Canonical standards file is missing or unsafe: $canonical_file" >&2
    exit 2
  }
  preflight_sync_file "$target_path" "sync"
done

cleanup_sync_transaction() {
  if [[ "$transaction_lock_owned" -eq 1 ]]; then
    lock_target="$(arkira_safe_target "$sync_lock_root" "arkira-sync.lock" 2>/dev/null || true)"
    if [[ -n "$lock_target" && -d "$lock_target" && ! -L "$lock_target" \
      && "$(arkira_stat_identity "$lock_target" 2>/dev/null || true)" == "$sync_lock_identity" ]]; then
      arkira_safe_rmdir "$sync_lock_root" "arkira-sync.lock" \
        || echo "WARNING: could not remove owned sync lock: $lock_target" >&2
    else
      echo "WARNING: owned sync lock name changed; refusing to remove it" >&2
    fi
    transaction_lock_owned=0
  fi
  [[ -z "${transaction_dir:-}" ]] || rm -rf -- "$transaction_dir"
  transaction_dir=""
}

rollback_sync_transaction() {
  local i rollback_failed=0 rollback_upto target_path target claimed_rel
  local claimed_identity recovery_rel recovery_parent
  [[ "$transaction_rollback_done" -eq 0 ]] || return 0
  transaction_rollback_done=1
  if [[ "$transaction_commit_started" -eq 1 ]]; then
    rollback_upto=$publish_count
    if [[ "$publish_attempt_index" -gt "$publish_count" ]]; then
      rollback_upto=$publish_attempt_index
    fi
    for ((i=rollback_upto; i>=1; i--)); do
      target_path=${BACKUP_RELS[$i]}
      claimed_rel=""
      if [[ -n "${PUBLISHED_IDENTITIES[$i]:-}" ]]; then
        claimed_rel="$(arkira_claim_regular_file "$target_repo" "$target_path" \
          ".arkira-sync-rollback" 2>/dev/null || true)"
      fi
      if [[ -n "$claimed_rel" ]]; then
        claimed_identity="$(arkira_stat_identity "$target_repo/$claimed_rel" \
          2>/dev/null || true)"
        if [[ "$claimed_identity" != "${PUBLISHED_IDENTITIES[$i]}" ]] \
          || ! sync_repo_file_matches_snapshot "$claimed_rel" \
            "$transaction_stage/$target_path"; then
          arkira_restore_claim_new "$target_repo" "$claimed_rel" "$target_path" \
            || printf 'ERROR: concurrent target retained at recovery path: %s\n' \
              "$claimed_rel" >&2
          printf 'ERROR: rollback preserved a concurrently replaced target: %s\n' \
            "$target_path" >&2
          rollback_failed=1
          continue
        fi
        if [[ "${BACKUP_EXISTED[$i]}" -eq 1 ]]; then
          if ! arkira_restore_claim_new "$target_repo" \
            "${BACKUP_CLAIM_RELS[$i]}" "$target_path"; then
            arkira_restore_claim_new "$target_repo" "$claimed_rel" "$target_path" \
              || printf 'ERROR: published target retained at recovery path: %s\n' \
                "$claimed_rel" >&2
            rollback_failed=1
            continue
          fi
        fi
        arkira_safe_remove_file "$target_repo" "$claimed_rel" \
          || rollback_failed=1
      else
        target="$(arkira_safe_target "$target_repo" "$target_path" 2>/dev/null || true)"
        if [[ -n "$target" && ! -e "$target" && ! -L "$target" ]]; then
          if [[ "${BACKUP_EXISTED[$i]}" -eq 1 ]]; then
            if [[ -n "${PUBLISHED_IDENTITIES[$i]:-}" ]]; then
              printf 'ERROR: rollback preserved a concurrent deletion; original retained at: %s\n' \
                "${BACKUP_CLAIM_RELS[$i]}" >&2
              rollback_failed=1
            elif [[ -n "${BACKUP_CLAIM_RELS[$i]}" ]]; then
              arkira_restore_claim_new "$target_repo" \
                "${BACKUP_CLAIM_RELS[$i]}" "$target_path" \
                || rollback_failed=1
            else
              recovery_parent="$(dirname -- "$target_path")"
              recovery_rel="$(arkira_unique_copy "$target_repo" "$recovery_parent" \
                ".arkira-sync-recovery" "${BACKUP_FILES[$i]}" 2>/dev/null || true)"
              if [[ -n "$recovery_rel" ]]; then
                printf 'ERROR: deleted target backup retained at recovery path: %s\n' \
                  "$recovery_rel" >&2
              fi
              rollback_failed=1
            fi
          fi
        else
          printf 'ERROR: rollback found a non-regular concurrent target: %s\n' \
            "$target_path" >&2
          rollback_failed=1
        fi
      fi
    done
    for ((i=${#CREATED_DIR_RELS[@]}-1; i>=1; i--)); do
      arkira_safe_rmdir "$target_repo" "${CREATED_DIR_RELS[$i]}" \
        || rollback_failed=1
    done
  fi
  return "$rollback_failed"
}

sync_transaction_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ "$transaction_active" -eq 1 ]]; then
    rollback_sync_transaction || echo "ERROR: sync rollback was incomplete" >&2
  fi
  cleanup_sync_transaction
  exit "$rc"
}

sync_transaction_signal() {
  local signal=$1
  trap - EXIT HUP INT TERM
  if [[ "$transaction_active" -eq 1 ]]; then
    rollback_sync_transaction || echo "ERROR: sync rollback was incomplete" >&2
  fi
  cleanup_sync_transaction
  kill -s "$signal" "$$"
  exit 1
}

trap sync_transaction_exit EXIT
trap 'sync_transaction_signal HUP' HUP
trap 'sync_transaction_signal INT' INT
trap 'sync_transaction_signal TERM' TERM

transaction_dir="$(mktemp -d "${TMPDIR:-/tmp}/arkira-sync-transaction.XXXXXX")"
chmod 700 "$transaction_dir"
transaction_canonical="$(cd -P -- "$transaction_dir" && pwd -P)" || {
  echo "ERROR: could not resolve the transaction directory." >&2
  exit 1
}
transaction_dir="$transaction_canonical"
transaction_stage="$transaction_dir/stage"
mkdir -m 700 "$transaction_stage"
transaction_inputs="$transaction_dir/inputs"
mkdir -m 700 "$transaction_inputs"
transaction_active=1
receipt_pre="$transaction_dir/receipt-pre.json"
arkira_receipt_snapshot "$target_repo" "$receipt_pre" || {
  echo "ERROR: could not snapshot sync receipt input." >&2
  exit 1
}

sync_lock_runtime_root="$(arkira_receipt_runtime_root)"
sync_lock_repo_identity="$(arkira_receipt_repo_identity "$target_repo")" || {
  echo "ERROR: sync lock identity is unavailable." >&2
  exit 1
}
sync_lock_locks_root="$sync_lock_runtime_root/locks"
sync_lock_root="$sync_lock_locks_root/$sync_lock_repo_identity"
if ! {
  arkira_receipt_reject_symlink_components "$sync_lock_runtime_root" &&
    arkira_receipt_reject_symlink_components "$sync_lock_locks_root" &&
    arkira_receipt_reject_symlink_components "$sync_lock_root" &&
    mkdir -p -- "$sync_lock_root" &&
    [[ -d "$sync_lock_runtime_root" && -d "$sync_lock_locks_root" && \
      -d "$sync_lock_root" ]] &&
    arkira_receipt_reject_symlink_components "$sync_lock_runtime_root" &&
    arkira_receipt_reject_symlink_components "$sync_lock_locks_root" &&
    arkira_receipt_reject_symlink_components "$sync_lock_root" &&
    chmod 700 "$sync_lock_runtime_root" "$sync_lock_locks_root" "$sync_lock_root"
}; then
  echo "ERROR: sync lock directory could not be created." >&2
  exit 1
fi
sync_lock_root="$(arkira_safe_root "$sync_lock_root")" || {
  echo "ERROR: sync lock directory is unsafe." >&2
  exit 1
}
if ! arkira_safe_mkdir_new "$sync_lock_root" "arkira-sync.lock"; then
  echo "ERROR: another standards sync transaction is active for this repository." >&2
  exit 1
fi
transaction_lock_owned=1
sync_lock_identity="$(arkira_stat_identity "$sync_lock_root/arkira-sync.lock")" || {
  echo "ERROR: could not bind the standards sync transaction lock." >&2
  exit 1
}

snapshot_sync_input() {
  local rel=$1 target snapshot mode
  target="$(arkira_safe_target "$target_repo" "$rel")" || return 1
  snapshot="$transaction_inputs/$rel"
  mkdir -p -- "$(dirname -- "$snapshot")"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || return 1
    arkira_safe_read "$target_repo" "$rel" > "$snapshot" || return 1
    mode="$(arkira_safe_file_mode "$target_repo" "$rel")" || return 1
    chmod "$mode" "$snapshot" || return 1
    printf '%s' "$snapshot"
  fi
}

private_file_mode() {
  if stat -f '%Lp' -- "$1" >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1"
  else
    stat -c '%a' -- "$1"
  fi
}

# Compare a live target with a private transaction snapshot using a bound,
# no-follow read. Content and mode are both part of the expected state.
sync_repo_file_matches_snapshot() {
  local rel=$1 snapshot=$2 target compare_file
  local current_mode expected_mode matches=1
  target="$(arkira_safe_target "$target_repo" "$rel")" || return 1
  [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
  [[ -f "$target" && ! -L "$target" ]] || return 1
  compare_file="$(mktemp "$transaction_dir/compare.XXXXXX")" || return 1
  if ! arkira_safe_read "$target_repo" "$rel" > "$compare_file"; then
    rm -f -- "$compare_file"
    return 1
  fi
  current_mode="$(arkira_safe_file_mode "$target_repo" "$rel")" || matches=0
  expected_mode="$(private_file_mode "$snapshot")" || matches=0
  cmp -s "$compare_file" "$snapshot" || matches=0
  rm -f -- "$compare_file"
  [[ "$matches" -eq 1 && "$current_mode" == "$expected_mode" ]]
}

sync_target_matches_snapshot() {
  local rel=$1 snapshot=$2 expected_existed=$3 target
  target="$(arkira_safe_target "$target_repo" "$rel")" || return 1
  if [[ "$expected_existed" -eq 0 ]]; then
    [[ ! -e "$target" && ! -L "$target" ]]
    return
  fi
  sync_repo_file_matches_snapshot "$rel" "$snapshot"
}

if [[ "$sync_pinned_config" -eq 1 ]]; then
  installed_config_file="$(snapshot_sync_input ".arkira/config.json")" || {
    echo "ERROR: harness config changed or became unsafe during staging." >&2
    exit 1
  }
  jq -e '
    type == "object" and
    (.harness | type) == "object" and
    (.harness | has("pin")) and
    .harness.pin != null
  ' "$installed_config_file" >/dev/null 2>&1 || {
    echo "ERROR: harness config changed or became unpinned during staging." >&2
    exit 1
  }
  mkdir -p "$transaction_stage/.arkira"
  jq --arg version "$resolved_plugin_version" --arg pin "$installed_harness_sha" \
    '.standards_version = $version | .harness.pin = $pin' \
    "$installed_config_file" > "$transaction_stage/.arkira/config.json"
  chmod "$(private_file_mode "$installed_config_file")" \
    "$transaction_stage/.arkira/config.json"
  if cmp -s "$installed_config_file" "$transaction_stage/.arkira/config.json"; then
    printf 'UNCHANGED .arkira/config.json\n'
  else
    mark_staged_target ".arkira/config.json"
    changed=1
    printf 'UPDATED   .arkira/config.json\n'
  fi
fi

# Stage every planned result in a private tree. Prompts, classification, managed
# region rendering, and registry generation all finish before the target repo's
# first mutation. An abort during this phase therefore needs no target rollback.
SYNC_TARGET_ROOT="$transaction_stage"
export SYNC_TARGET_ROOT
write_common_registry
snapshot_sync_input ".arkira/sync-state.json" >/dev/null || {
  echo "ERROR: sync registry changed or became unsafe during staging." >&2
  exit 1
}

for check in "${SYNC_CHECKS[@]}"; do
  IFS='|' read -r source_path target_path profile_filter scope <<<"$check"
  if ! sync_profile_matches "${profile_filter:-*}" "$target_profile"; then
    continue
  fi
  sync_manifest_scope_installs "$check" "${scope:-}" || continue
  # The repo-root context trio (AGENTS.md, CLAUDE.md, CODEX.md) is the standards
  # repo's own local-only context, not a sync target. When syncing the standards
  # repo against itself, skip the ai-engineering/root/* entries so sync never
  # writes the repo-root trio. See governance/sync-standard.md.
  if [[ "$target_repo" == "$standards_repo" && "$source_path" == ai-engineering/root/* ]]; then
    continue
  fi
  canonical_file="$sync_source_root/$source_path"
  installed_file="$(snapshot_sync_input "$target_path")" || {
    echo "ERROR: sync target changed or became unsafe during staging: $target_path" >&2
    exit 1
  }

  if sync_is_managed_block_document "$canonical_file"; then
    apply_managed_file "$canonical_file" "$installed_file" "$target_path"
    target_is_staged "$target_path" && changed=1
    continue
  fi

  if [[ ! -f "$installed_file" ]]; then
    copy_pristine "$canonical_file" "$installed_file" "$target_path"
    changed=1
    continue
  fi

  baseline="$(sync_registry_read "$transaction_inputs" "$(registry_path_for "$target_path")${KSEP}baseline_sha" || true)"
  status="$(sync_classify_pristine "$installed_file" "$canonical_file" "$baseline" 2>/dev/null || printf 'local-drift')"
  # Content equality alone does not establish a pristine file when executable classes differ.
  if [[ -z "$baseline" ]] && cmp -s "$installed_file" "$canonical_file" && {
    sync_modes_differ "$installed_file" "$canonical_file"
    [[ $? -eq 1 ]]
  }; then
    write_pristine_baseline "$target_path" "$installed_file"
    printf 'BASELINE  %s\n' "$target_path"
    continue
  fi

  case "$status" in
    clean)
      printf 'UNCHANGED %s\n' "$target_path"
      ;;
    refresh-clean)
      write_pristine_baseline "$target_path" "$installed_file"
      printf 'BASELINE  %s\n' "$target_path"
      ;;
    update-clean)
      copy_pristine "$canonical_file" "$installed_file" "$target_path"
      changed=1
      ;;
    local-drift|conflict)
      if [[ "$force_pristine" -eq 0 ]]; then
        printf 'SKIPPED   %s (%s; use --force-pristine)\n' "$target_path" "$status"
        continue
      fi
      diff -u "$installed_file" "$canonical_file" || true
      choice="$(prompt_choice "Replace pristine file $target_path" "replace|abort")"
      case "$choice" in
        replace)
          copy_pristine "$canonical_file" "$installed_file" "$target_path"
          changed=1
          ;;
        abort)
          echo "Aborted by user." >&2
          exit 1
          ;;
        *)
          echo "ERROR: expected replace or abort." >&2
          exit 2
          ;;
      esac
      ;;
    *)
      printf 'SKIPPED   %s (%s)\n' "$target_path" "$status"
      ;;
  esac
done

# Generate any additional provider context overlays from adapter metadata. The
# canonical Claude and Codex overlays remain normal sync entries; every other
# context_file follows the same migration path with no provider-specific branch.
if [[ "$target_repo" != "$standards_repo" ]]; then
  overlay_dir="$transaction_dir/provider-overlays"
  mkdir -m 700 -- "$overlay_dir"
  while IFS=$'\t' read -r target_path canonical_file; do
    [[ -n "$target_path" && "$target_path" != CLAUDE.md && "$target_path" != CODEX.md ]] || continue
    installed_file="$(snapshot_sync_input "$target_path")" || {
      echo "ERROR: provider overlay target changed or became unsafe: $target_path" >&2
      exit 1
    }
    migrate_role_overlay "$canonical_file" "$installed_file" "$target_path"
    target_is_staged "$target_path" && changed=1
  done < <(bash "$script_dir/generate-provider-overlays.sh" "$overlay_dir")
fi

# Render the registry from its original snapshot plus every queued update. It is
# a staged file like any other and is published last as part of the transaction.
mkdir -p "$transaction_stage/.arkira"
if [[ -f "$transaction_inputs/.arkira/sync-state.json" ]]; then
  cp -p -- "$transaction_inputs/.arkira/sync-state.json" \
    "$transaction_stage/.arkira/sync-state.json"
else
  printf '{}\n' > "$transaction_stage/.arkira/sync-state.json"
  chmod 600 "$transaction_stage/.arkira/sync-state.json"
fi
if [[ -n "$PENDING_WRITES" ]]; then
  printf '%s' "$PENDING_WRITES" | sync_registry_write_many "$transaction_stage"
fi
if [[ ! -f "$transaction_inputs/.arkira/sync-state.json" ]] \
  || ! cmp -s "$transaction_inputs/.arkira/sync-state.json" \
    "$transaction_stage/.arkira/sync-state.json"; then
  mark_staged_target ".arkira/sync-state.json"
  changed=1
fi

CREATED_DIR_SEEN_LIST=""
ensure_publish_parent() {
  local rel=$1 parent current="" part safe_current
  parent="$(dirname -- "$rel")"
  [[ "$parent" != "." ]] || return 0
  IFS='/' read -r -a publish_parent_parts <<<"$parent"
  for part in "${publish_parent_parts[@]}"; do
    current="${current:+$current/}$part"
    safe_current="$(arkira_safe_target "$target_repo" "$current")" || return 1
    if [[ -e "$safe_current" ]]; then
      [[ -d "$safe_current" && ! -L "$safe_current" ]]
    else
      arkira_safe_mkdir "$target_repo" "$current"
      if ! printf '%s' "$CREATED_DIR_SEEN_LIST" | grep -Fxq -- "$current"; then
        CREATED_DIR_RELS+=("$current")
        CREATED_DIR_SEEN_LIST+="$current"$'\n'
      fi
    fi
  done
}

backup_index=0
for target_path in "${STAGED_TARGETS[@]}"; do
  [[ -n "$target_path" ]] || continue
  preflight_sync_file "$target_path" "sync commit"
  backup_file="$transaction_dir/backup.$backup_index"
  expected_file="$transaction_inputs/$target_path"
  if [[ -f "$expected_file" ]]; then
    arkira_safe_read "$target_repo" "$target_path" > "$backup_file" || {
      echo "ERROR: sync target disappeared or became unsafe while staged: $target_path" >&2
      exit 1
    }
    current_mode="$(arkira_safe_file_mode "$target_repo" "$target_path")" || {
      echo "ERROR: sync target mode became unreadable while staged: $target_path" >&2
      exit 1
    }
    chmod "$current_mode" "$backup_file"
    if ! cmp -s "$expected_file" "$backup_file" \
      || [[ "$(arkira_safe_file_mode "$transaction_inputs" "$target_path")" != "$current_mode" ]]; then
      echo "ERROR: sync target changed while the transaction was staged: $target_path" >&2
      exit 1
    fi
    BACKUP_EXISTED+=(1)
  else
    if ! sync_target_matches_snapshot "$target_path" "$backup_file" 0; then
      echo "ERROR: sync target appeared while the transaction was staged: $target_path" >&2
      exit 1
    fi
    : > "$backup_file"
    BACKUP_EXISTED+=(0)
  fi
  BACKUP_RELS+=("$target_path")
  BACKUP_FILES+=("$backup_file")
  BACKUP_CLAIM_RELS+=("")
  BACKUP_CLAIM_IDENTITIES+=("")
  PUBLISHED_IDENTITIES+=("")
  backup_index=$((backup_index + 1))
done

transaction_commit_started=1
for target_path in "${STAGED_TARGETS[@]}"; do
  [[ -n "$target_path" ]] || continue
  publish_attempt_index=$((publish_count + 1))
  if [[ "${ARKIRA_SYNC_TEST_MUTATE_AFTER_BACKUP_REL:-}" == "$target_path" ]]; then
    printf '\nconcurrent test edit\n' >> "$target_repo/$target_path"
    unset ARKIRA_SYNC_TEST_MUTATE_AFTER_BACKUP_REL
  fi
  if ! sync_target_matches_snapshot "$target_path" \
    "${BACKUP_FILES[$publish_attempt_index]}" \
    "${BACKUP_EXISTED[$publish_attempt_index]}"; then
    echo "ERROR: sync target changed after backup: $target_path" >&2
    exit 1
  fi
  if [[ "${ARKIRA_SYNC_TEST_DELETE_AFTER_CAS_REL:-}" == "$target_path" ]]; then
    arkira_safe_remove_file "$target_repo" "$target_path"
    unset ARKIRA_SYNC_TEST_DELETE_AFTER_CAS_REL
  fi
  ensure_publish_parent "$target_path"
  if [[ "${BACKUP_EXISTED[$publish_attempt_index]}" -eq 1 ]]; then
    original_claim="$(arkira_claim_regular_file "$target_repo" "$target_path" \
      ".arkira-sync-original")" || {
      echo "ERROR: could not atomically claim sync target: $target_path" >&2
      exit 1
    }
    BACKUP_CLAIM_RELS[$publish_attempt_index]="$original_claim"
    BACKUP_CLAIM_IDENTITIES[$publish_attempt_index]="$(arkira_stat_identity \
      "$target_repo/$original_claim")" || {
      echo "ERROR: could not bind original sync claim: $target_path" >&2
      exit 1
    }
    if ! sync_repo_file_matches_snapshot "$original_claim" \
      "${BACKUP_FILES[$publish_attempt_index]}"; then
      echo "ERROR: sync target changed while it was atomically claimed: $target_path" >&2
      exit 1
    fi
  fi
  if [[ "${ARKIRA_SYNC_TEST_MUTATE_AFTER_CLAIM_REL:-}" == "$target_path" ]]; then
    printf 'concurrent replacement after claim\n' > "$target_repo/$target_path"
    unset ARKIRA_SYNC_TEST_MUTATE_AFTER_CLAIM_REL
  fi
  PUBLISHED_IDENTITIES[$publish_attempt_index]="$(
    arkira_atomic_copy_new_with_identity "$target_repo" "$target_path" \
      "$transaction_stage/$target_path"
  )" || {
    echo "ERROR: could not bind published sync target: $target_path" >&2
    exit 1
  }
  if [[ "${ARKIRA_SYNC_TEST_MUTATE_ORIGINAL_CLAIM_REL:-}" == "$target_path" ]]; then
    printf '\nconcurrent write through original inode\n' \
      >> "$target_repo/${BACKUP_CLAIM_RELS[$publish_attempt_index]}"
    unset ARKIRA_SYNC_TEST_MUTATE_ORIGINAL_CLAIM_REL
  fi
  if [[ "${ARKIRA_SYNC_TEST_REPLACE_AFTER_PUBLISH_REL:-}" == "$target_path" ]]; then
    arkira_atomic_copy "$target_repo" "$target_path" \
      "$transaction_stage/$target_path"
    unset ARKIRA_SYNC_TEST_REPLACE_AFTER_PUBLISH_REL
    echo "ERROR: injected same-content replacement after publication" >&2
    false
  fi
  if [[ "${ARKIRA_SYNC_TEST_MUTATE_IN_PLACE_AFTER_PUBLISH_REL:-}" == "$target_path" ]]; then
    printf '\nconcurrent in-place edit after publication\n' \
      >> "$target_repo/$target_path"
    unset ARKIRA_SYNC_TEST_MUTATE_IN_PLACE_AFTER_PUBLISH_REL
    echo "ERROR: injected in-place mutation after publication" >&2
    false
  fi
  publish_count=$((publish_count + 1))
  publish_attempt_index=0
  if [[ -n "${ARKIRA_SYNC_FAIL_AFTER_PUBLISH_COUNT:-}" \
    && "$publish_count" -eq "$ARKIRA_SYNC_FAIL_AFTER_PUBLISH_COUNT" ]]; then
    echo "ERROR: injected sync publication failure after $publish_count writes" >&2
    false
  fi
done

# Publication is not committed until every name still identifies the inode we
# installed and every byte/mode still matches the one private staged candidate.
# This catches a concurrent edit to an early file after later files (including
# the registry) were published. The normal rollback path then preserves that
# concurrent edit and restores every target that is still ours.
if [[ -n "${ARKIRA_SYNC_TEST_MUTATE_BEFORE_FINAL_VALIDATE_REL:-}" ]]; then
  printf '\nconcurrent edit before final coherence validation\n' \
    >> "$target_repo/$ARKIRA_SYNC_TEST_MUTATE_BEFORE_FINAL_VALIDATE_REL"
fi
for ((coherence_index=1; coherence_index<=publish_count; coherence_index++)); do
  target_path=${BACKUP_RELS[$coherence_index]}
  live_identity="$(arkira_stat_identity "$target_repo/$target_path" \
    2>/dev/null || true)"
  if [[ -z "$live_identity" \
    || "$live_identity" != "${PUBLISHED_IDENTITIES[$coherence_index]}" \
    || ! -f "$transaction_stage/$target_path" ]] \
    || ! sync_repo_file_matches_snapshot "$target_path" \
      "$transaction_stage/$target_path"; then
    printf 'ERROR: final sync candidate changed before commit: %s\n' \
      "$target_path" >&2
    false
  fi
done
if ! jq -e --arg version "$resolved_plugin_version" '
  .schema == "1" and .plugin_version == $version and (.files | type == "object")
' "$target_repo/.arkira/sync-state.json" >/dev/null 2>&1; then
  printf 'ERROR: final sync registry does not describe the staged candidate\n' >&2
  false
fi

# Retire only the exact repo-local ggshield commands previously installed by
# Arkira. The helper owns a separate contained transaction for both hook files.
# Run it after tracked-file validation but before committing this transaction,
# so a hook cleanup failure still rolls the tracked sync candidate back.
bash "$sync_source_root/ai-engineering/bootstrap/cleanup-legacy-secret-hooks.sh" --apply "$target_repo"

if [[ "$sync_pinned_config" -eq 1 ]]; then
  bash "$sync_source_root/ai-engineering/runtime/harness-store.sh" bind \
    "$target_repo" "$harness_snapshot_digest" || {
    echo "ERROR: could not bind the synced repository to its harness snapshot" >&2
    false
  }
fi

transaction_active=0
cleanup_failed=0
for ((claim_index=1; claim_index<${#BACKUP_CLAIM_RELS[@]}; claim_index++)); do
  original_claim=${BACKUP_CLAIM_RELS[$claim_index]}
  [[ -n "$original_claim" ]] || continue
  if [[ "$(arkira_stat_identity "$target_repo/$original_claim" \
      2>/dev/null || true)" == "${BACKUP_CLAIM_IDENTITIES[$claim_index]}" ]] \
    && sync_repo_file_matches_snapshot "$original_claim" \
      "${BACKUP_FILES[$claim_index]}"; then
    if ! arkira_safe_remove_file "$target_repo" "$original_claim"; then
      printf 'ERROR: committed sync could not remove owned claim: %s\n' \
        "$original_claim" >&2
      cleanup_failed=1
    fi
  else
    printf 'ERROR: committed sync retained concurrently changed original at: %s\n' \
      "$original_claim" >&2
    cleanup_failed=1
  fi
done
if [[ "$cleanup_failed" -ne 0 ]]; then
  printf 'ERROR: sync candidate was published, but owned recovery state remains\n' >&2
  cleanup_sync_transaction
  exit 1
fi

receipt_post="$transaction_dir/receipt-post.json"
receipt_targets="$transaction_dir/receipt-targets.json"
{
  for target_path in "${STAGED_TARGETS[@]}"; do
    # Record the registry because the gate requires coverage for every tracked candidate path.
    [[ -n "$target_path" ]] || continue
    printf '%s\n' "$target_path"
  done
} | jq -R . | jq -s . > "$receipt_targets" || {
  printf 'ERROR: could not prepare sync receipt targets\n' >&2
  exit 1
}
arkira_receipt_snapshot "$target_repo" "$receipt_post" || {
  printf 'ERROR: could not snapshot sync receipt output\n' >&2
  exit 1
}
jq --slurpfile targets "$receipt_targets" \
  '.entries |= [.[] | select(.path as $path | $targets[0] | index($path))]' \
  "$receipt_pre" > "$transaction_dir/receipt-pre-filtered.json" || exit 1
jq --slurpfile targets "$receipt_targets" \
  '.entries |= [.[] | select(.path as $path | $targets[0] | index($path))]' \
  "$receipt_post" > "$transaction_dir/receipt-post-filtered.json" || exit 1
arkira_receipt_write "$target_repo" "$transaction_dir/receipt-pre-filtered.json" \
  "$transaction_dir/receipt-post-filtered.json" \
  "{\"author_role\":\"transformer\",\"author_provider\":\"arkira-sync\",\"author_model\":\"\",\"author_effort\":\"not_applicable\",\"job_id\":\"arkira-sync-$$\"}" >/dev/null || {
  printf 'ERROR: could not write sync transformer receipt\n' >&2
  exit 1
}
cleanup_sync_transaction
trap - EXIT HUP INT TERM

if [[ "$changed" -eq 0 ]]; then
  printf '\nNo standards updates were needed.\n'
else
  printf '\nTarget repo diff stat:\n'
  git -C "$target_repo" diff --stat
fi
