#!/usr/bin/env bash
# SessionStart hook: read-only Arkira update and standards drift reports.
#
# The hook never materializes or rewrites user or repository configuration. It
# never stages, commits, pushes, or launches background work. A successful,
# well-formed drift check writes bounded throttle and notice-state stamps inside
# the git dir.
#
# Repositories without a regular repo-local .arkira/config.json are outside the
# hook's scope. They produce no output and no hook state, even when user-global
# defaults exist. Explicit /arkira-init owns onboarding.
#
# 1. Update probe. Nudges /arkira-update when the plugin is newer than the
#    repo-local config.
#
# 2. Drift check. Notice-only. It reports Arkira standards drift and makes no
#    working-tree write: no file copy, no git add, no commit, no push. It writes
#    only bounded hook stamps inside the git dir, which are never committed. All
#    standards writes are deferred to the operator-invoked /arkira-sync --apply,
#    which keeps the human in the loop and honors the repo push-gate in AGENTS.md.
#    Drift behavior:
#      - In sync -> silent.
#      - Conflicts or prompts (custom files present) -> notice to run
#        /arkira-sync to review, then /arkira-sync --apply. Local edits are
#        never touched.
#      - Working tree dirty -> notice to run /arkira-sync --apply when ready.
#      - Clean tree with MISSING or outdated managed files -> notice to run
#        /arkira-sync --apply.
#
# Always exits 0 so it cannot disrupt a session.
set -uo pipefail

# Source sync-lib.sh so the hook honors governance/sync-standard.md's guarantee
# that "Sync never introduces a runtime dependency on jq. JSON and sentinel
# parsing use node exclusively." The small helpers defined below use node
# directly rather than calling sync_registry_read() because that function
# is hardcoded to <repo_root>/.arkira/sync-state.json, while the reads in
# this hook target three different config files: the user config
# (~/.arkira/config.json), the per-repo config (<repo>/.arkira/config.json),
# and the plugin manifest (<plugin>/.claude-plugin/plugin.json). These are
# config-file lookups, not sync-state registry lookups, so they do not
# flow through sync_registry_read by design. The node-based implementations
# below still satisfy the no-runtime-jq guarantee.
__arkira_drift_hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
__arkira_drift_plugin_root="$(cd -- "$__arkira_drift_hook_dir/.." && pwd -P)"
# shellcheck source=../ai-engineering/bootstrap/lib/sync-lib.sh
# shellcheck disable=SC1091
. "$__arkira_drift_plugin_root/ai-engineering/bootstrap/lib/sync-lib.sh"

# arkira_json_field <file> <top-key> [default]
# Reads a single top-level field from <file>. Prints the value (strings
# unquoted, scalars stringified) or <default> when missing/null/unreadable.
# Returns 0 on success including default-substitution; 1 only when neither a
# value nor a default is available. Replaces `jq -r '.k'` and `jq -r '.k // X'`.
arkira_json_field() {
  local file=${1:-}
  local key=${2:-}
  local default_value=${3-}
  local has_default=0
  [[ $# -ge 3 ]] && has_default=1
  [[ -n "$file" && -n "$key" ]] || return 1
  # shellcheck disable=SC2016
  ARKIRA_JSON_FILE="$file" \
  ARKIRA_JSON_KEY="$key" \
  ARKIRA_JSON_DEFAULT="$default_value" \
  ARKIRA_JSON_HAS_DEFAULT="$has_default" \
  node -e '
const fs = require("fs");
const file = process.env.ARKIRA_JSON_FILE;
const key = process.env.ARKIRA_JSON_KEY;
const hasDefault = process.env.ARKIRA_JSON_HAS_DEFAULT === "1";
const fallback = process.env.ARKIRA_JSON_DEFAULT;
let data;
try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch { data = undefined; }
let value;
if (data && typeof data === "object" && key in data) value = data[key];
if (value === undefined || value === null) {
  if (hasDefault) { process.stdout.write(fallback); process.exit(0); }
  process.exit(1);
}
process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
'
}

# arkira_json_true <file> <top-key>
# Returns 0 iff <file> exists, parses as JSON, and the top-level <top-key>
# is strictly the boolean true. Anything else (missing file, parse error,
# missing key, non-boolean, false) returns 1. Replaces `jq -e '.k == true'`.
arkira_json_true() {
  local file=${1:-}
  local key=${2:-}
  [[ -n "$file" && -n "$key" ]] || return 1
  # shellcheck disable=SC2016
  ARKIRA_JSON_FILE="$file" \
  ARKIRA_JSON_KEY="$key" \
  node -e '
const fs = require("fs");
const file = process.env.ARKIRA_JSON_FILE;
const key = process.env.ARKIRA_JSON_KEY;
let data;
try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(1); }
if (!data || typeof data !== "object") process.exit(1);
process.exit(data[key] === true ? 0 : 1);
'
}

arkira_probe_loaded=0
arkira_probe_manifest_path=""
arkira_probe_profile=app
arkira_probe_plugin_version=""
arkira_probe_config_standards_version=""

# Resolve the physical repository before any notice-state write. An absent,
# symbolic, or non-regular repo-local config is a hard silent gate. Do not read
# user-global defaults or create a Git sidecar for an unconfigured repository.
arkira_notice_project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
arkira_notice_repo_root="$(git -C "$arkira_notice_project_dir" \
  rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$arkira_notice_repo_root" ] || exit 0
arkira_repo_config_path="$arkira_notice_repo_root/.arkira/config.json"
[[ -f "$arkira_repo_config_path" && ! -L "$arkira_repo_config_path" ]] || exit 0

# Update nudges use their own state fingerprint. Keep the stamp in the physical
# git dir so it is local, bounded, and never committed. A transition through a
# healthy state rewrites the stamp, so a later regression is noticed once.
arkira_notice_git_dir="$(git -C "$arkira_notice_project_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
arkira_init_notice_state="${arkira_notice_git_dir:+$arkira_notice_git_dir/arkira-init-notice-state}"

arkira_init_notice_changed() {
  local next=${1:-} state_file=${2:-$arkira_init_notice_state} prior="" tmp=""
  [ -n "$next" ] || return 1
  # Outside Git there is no repository-private persistence surface and
  # /arkira-init has no repository to configure. Stay silent instead of
  # creating an unbounded global path registry or nagging every non-repo chat.
  [ -n "$state_file" ] || return 1
  [ -f "$state_file" ] \
    && prior="$(cat "$state_file" 2>/dev/null || true)"
  [ "$prior" != "$next" ] || return 1
  tmp="$(mktemp "$state_file.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if printf '%s\n' "$next" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$state_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  # If state cannot be persisted, suppress the notice rather than repeating it
  # on every SessionStart indefinitely.
  return 1
}

arkira_emit_init_notice() {
  local state=$1 message=$2 state_file=${3:-$arkira_init_notice_state}
  arkira_init_notice_changed "$state" "$state_file" || return 0
  printf '%s\n' "$message"
}

arkira_load_probe_fields() {
  local user_cfg=${1:-}
  local repo_cfg=${2:-}
  local manifest=${3:-}
  local probe_output probe_line
  local -a probe_lines

  # shellcheck disable=SC2016
  probe_output="$(ARKIRA_PROBE_USER_CFG="$user_cfg" \
    ARKIRA_PROBE_REPO_CFG="$repo_cfg" \
    ARKIRA_PROBE_MANIFEST="$manifest" \
    node -e '
const fs = require("fs");

function readJson(file) {
  if (!file) return undefined;
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return undefined; }
}

function field(data, key, fallback) {
  let value;
  if (data && typeof data === "object" && Object.prototype.hasOwnProperty.call(data, key)) {
    value = data[key];
  }
  if (value === undefined || value === null) return fallback;
  return typeof value === "string" ? value : JSON.stringify(value);
}

const repoCfg = readJson(process.env.ARKIRA_PROBE_REPO_CFG);
const manifest = readJson(process.env.ARKIRA_PROBE_MANIFEST);

process.stdout.write([
  field(repoCfg, "profile", "app"),
  field(manifest, "version", ""),
  field(repoCfg, "standards_version", ""),
].join("\n"));
')" || probe_output=""

  probe_lines=()
  while IFS= read -r probe_line; do
    probe_lines+=("$probe_line")
  done <<< "$probe_output"

  arkira_probe_profile="${probe_lines[0]:-app}"
  arkira_probe_plugin_version="${probe_lines[1]:-}"
  arkira_probe_config_standards_version="${probe_lines[2]:-}"
  arkira_probe_loaded=1
  arkira_probe_manifest_path="$manifest"
}

# --- Arkira update probe ---
# Nudges /arkira-update when the plugin is newer than the repo config. Set
# ARKIRA_INIT_SKIP_PROBE=1 to disable in focused tests. Also reports when a
# directory marketplace source is newer than the installed plugin.
if [[ "${ARKIRA_INIT_SKIP_PROBE:-0}" != "1" ]]; then
  arkira_home="${ARKIRA_INIT_HOME:-$HOME}"
  arkira_plugin_root_probe="${ARKIRA_INIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"

  arkira_user_cfg="$arkira_home/.arkira/config.json"
  arkira_repo_cfg="$arkira_repo_config_path"
  arkira_probe_manifest=""
  [[ -n "$arkira_plugin_root_probe" ]] && arkira_probe_manifest="$arkira_plugin_root_probe/.claude-plugin/plugin.json"

  if [[ -n "$arkira_plugin_root_probe" ]]; then
    # Load the profile for switch/update decisions without feeding a routine
    # banner into every conversation. Explicit diagnostics may request it.
    arkira_load_probe_fields "$arkira_user_cfg" "$arkira_repo_cfg" "$arkira_probe_manifest" 2>/dev/null
    active_profile="$arkira_probe_profile"
    [[ -n "$active_profile" ]] || active_profile="app"
    if [[ "${ARKIRA_SESSION_DIAGNOSTICS:-0}" == "1" ]]; then
      echo "[arkira] active profile: $active_profile"
    fi
    arkira_switches_probe="$arkira_plugin_root_probe/ai-engineering/bootstrap/switches.json"
    arkira_plugin_manifest="$arkira_plugin_root_probe/.claude-plugin/plugin.json"
    arkira_detect="$arkira_plugin_root_probe/ai-engineering/bootstrap/arkira-update-detect.sh"
    if [[ -f "$arkira_plugin_manifest" && -x "$arkira_detect" && -f "$arkira_switches_probe" ]]; then
      plugin_version="$arkira_probe_plugin_version"
      cfg_version="$arkira_probe_config_standards_version"
      if [[ -n "$cfg_version" && "$plugin_version" != "$cfg_version" ]]; then
        new_ids="$("$arkira_detect" "$arkira_repo_cfg" "$arkira_switches_probe" 2>/dev/null || true)"
        if [[ -n "$new_ids" ]]; then
          update_fingerprint="$(printf '%s\n%s\n%s\n' "$plugin_version" "$cfg_version" "$new_ids" \
            | shasum -a 256 2>/dev/null | awk '{print $1}')"
          [ -n "$update_fingerprint" ] || update_fingerprint="$plugin_version:$cfg_version"
          arkira_emit_init_notice "update:$update_fingerprint" \
            "New Arkira switches available. Run /arkira-update."
        else
          arkira_init_notice_changed "configured" >/dev/null 2>&1 || true
        fi
      else
        arkira_init_notice_changed "configured" >/dev/null 2>&1 || true
      fi
    else
      arkira_init_notice_changed "configured" >/dev/null 2>&1 || true
    fi

    arkira_plugins_dir="${CLAUDE_CONFIG_DIR:-$arkira_home/.claude}/plugins"
    arkira_marketplaces="$arkira_plugins_dir/known_marketplaces.json"
    arkira_marketplace_source=""
    if [[ -r "$arkira_marketplaces" ]]; then
      # shellcheck disable=SC2016
      arkira_marketplace_source="$(ARKIRA_MARKETPLACES="$arkira_marketplaces" node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(process.env.ARKIRA_MARKETPLACES, "utf8")); } catch { process.exit(1); }
const entry = data && typeof data === "object" ? data["arkira-labs-standards"] : undefined;
if (!entry || !entry.source || entry.source.source !== "directory") process.exit(1);
if (typeof entry.source.path !== "string" || entry.source.path.length === 0) process.exit(1);
process.stdout.write(entry.source.path);
' 2>/dev/null || true)"
    fi
    arkira_harness_notice_state="${arkira_notice_git_dir:+$arkira_notice_git_dir/arkira-harness-notice-state}"
    if [[ -n "$arkira_marketplace_source" && -d "$arkira_marketplace_source" ]]; then
      arkira_source_manifest="$arkira_marketplace_source/.claude-plugin/plugin.json"
      arkira_source_version=""
      if [[ -r "$arkira_source_manifest" ]]; then
        arkira_source_version="$(arkira_json_field "$arkira_source_manifest" version 2>/dev/null || true)"
      fi
      if [[ -n "$arkira_probe_plugin_version" && -n "$arkira_source_version" ]]; then
        arkira_newest_version="$(printf '%s\n%s\n' \
          "$arkira_probe_plugin_version" "$arkira_source_version" \
          | sort -V 2>/dev/null | tail -n 1)"
        if [[ "$arkira_source_version" != "$arkira_probe_plugin_version" \
          && "$arkira_newest_version" == "$arkira_source_version" ]]; then
          arkira_emit_init_notice \
            "harness:$arkira_source_version:$arkira_probe_plugin_version" \
            "Arkira harness $arkira_source_version available, installed $arkira_probe_plugin_version. Run: claude plugin update arkira@arkira-labs-standards" \
            "$arkira_harness_notice_state"
        else
          arkira_init_notice_changed "configured" "$arkira_harness_notice_state" \
            >/dev/null 2>&1 || true
        fi
      fi
    fi
  else
    arkira_init_notice_changed "configured" >/dev/null 2>&1 || true
  fi
fi
# --- end Arkira update probe ---

# 1. Scope the drift audit to the configured Claude project, never process cwd.
repo_root="$arkira_notice_repo_root"

# 2. Must be an Arkira-managed repo. The init probe above owns missing config.
[ -f "$repo_root/AGENTS.md" ] || exit 0

# 3. Locate the canonical bootstrap scripts inside this plugin.
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  plugin_root="$(cd -- "$script_dir/.." && pwd -P)"
fi
check_script="$plugin_root/ai-engineering/bootstrap/check-ai-engineering-standards.sh"
[ -f "$check_script" ] || exit 0

repo_name="$(basename "$repo_root")"

# --- throttle: run the expensive drift compare at most once per window per
#     repo, and always on a plugin-version change. Mirrors graph-maintain.sh.
#     Throttles ONLY the compare below; the init probe above is unaffected.
#     The stamp lives in the git dir, so it is never committed and cannot
#     dirty the working tree or depend on .arkira/ being gitignored.
drift_now() { if [ -n "${ARKIRA_DRIFT_NOW:-}" ]; then echo "$ARKIRA_DRIFT_NOW"; else date +%s; fi; }
drift_throttle="${ARKIRA_DRIFT_THROTTLE:-86400}"
drift_git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || true)"
drift_plugin_manifest="$plugin_root/.claude-plugin/plugin.json"
if [[ "$arkira_probe_loaded" != "1" || "$arkira_probe_manifest_path" != "$drift_plugin_manifest" ]]; then
  drift_user_cfg="${arkira_user_cfg:-${ARKIRA_INIT_HOME:-$HOME}/.arkira/config.json}"
  drift_repo_cfg="${arkira_repo_cfg:-$repo_root/.arkira/config.json}"
  arkira_load_probe_fields "$drift_user_cfg" "$drift_repo_cfg" "$drift_plugin_manifest"
fi
drift_plugin_ver="$arkira_probe_plugin_version"
drift_cur="$(drift_now)"
drift_stamp=""
[ -n "$drift_git_dir" ] && drift_stamp="$drift_git_dir/arkira-drift-stamp"
if [ -n "$drift_stamp" ] && [ -f "$drift_stamp" ] && [ -n "$drift_plugin_ver" ]; then
  read -r drift_stamp_epoch drift_stamp_ver < "$drift_stamp" 2>/dev/null || { drift_stamp_epoch=0; drift_stamp_ver=""; }
  case "$drift_stamp_epoch" in ''|*[!0-9]*) drift_stamp_epoch=0 ;; esac
  if [ "$drift_stamp_epoch" -gt 0 ] \
     && [ "$drift_stamp_ver" = "$drift_plugin_ver" ] \
     && [ "$((drift_cur - drift_stamp_epoch))" -ge 0 ] \
     && [ "$((drift_cur - drift_stamp_epoch))" -lt "$drift_throttle" ]; then
    exit 0
  fi
fi

# 4. Run the drift check. This hook is read-only: it reports drift and
#    defers all writes to operator-invoked /arkira-sync --apply. Check
#    script always exits 0 since merge-aware sync; drift is encoded in the
#    body and the final summary line.
drift_out="$(bash "$check_script" "$repo_root" 2>/dev/null)"
drift_rc=$?
[ "$drift_rc" -eq 0 ] || exit 0

# 5. Parse the summary line: "N files will change. M conflicts. P prompts required."
summary_line="$(printf '%s\n' "$drift_out" | grep -E '^[0-9]+ files will change\.' | tail -n 1)"
[ -n "$summary_line" ] || exit 0

will_change="${summary_line%% *}"
remainder="${summary_line#* files will change. }"
conflicts="${remainder%% *}"
remainder="${remainder#* conflicts. }"
prompts="${remainder%% *}"

# Defensive: if any field failed to parse as a number, stay silent.
case "$will_change$conflicts$prompts" in
  *[!0-9]*) exit 0 ;;
esac

# Record only a successful, well-formed compare. A per-process temporary file
# plus rename keeps concurrent SessionStart invocations from exposing a partial
# stamp. Failure to write remains non-disruptive.
if [ -n "$drift_stamp" ] && [ -n "$drift_plugin_ver" ]; then
  drift_stamp_tmp="$(mktemp "$drift_stamp.XXXXXX" 2>/dev/null || true)"
  if [ -n "$drift_stamp_tmp" ] \
     && printf '%s %s\n' "$drift_cur" "$drift_plugin_ver" > "$drift_stamp_tmp" 2>/dev/null; then
    mv "$drift_stamp_tmp" "$drift_stamp" 2>/dev/null || rm -f "$drift_stamp_tmp" 2>/dev/null || true
  else
    [ -n "$drift_stamp_tmp" ] && rm -f "$drift_stamp_tmp" 2>/dev/null || true
  fi
fi

# Record the last successfully observed state in the git dir. Throttle controls
# check cost; this fingerprint controls chat output. An unchanged actionable
# result stays silent even after the throttle window expires.
drift_notice_state="$drift_git_dir/arkira-drift-notice-state"
drift_notice_changed() {
  local next="$1" prior="" tmp=""
  [ -n "$drift_git_dir" ] || return 0
  [ -f "$drift_notice_state" ] && prior="$(cat "$drift_notice_state" 2>/dev/null || true)"
  [ "$prior" != "$next" ] || return 1
  tmp="$(mktemp "$drift_notice_state.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || return 0
  if printf '%s\n' "$next" > "$tmp" 2>/dev/null \
     && mv "$tmp" "$drift_notice_state" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# 6. In sync -> silent and reset the actionable-state fingerprint.
if [ "$will_change" -eq 0 ] && [ "$conflicts" -eq 0 ] && [ "$prompts" -eq 0 ]; then
  drift_notice_changed "clean" >/dev/null 2>&1 || true
  exit 0
fi

notice=""
notice_kind=""

# 7. Custom files present (conflicts or drifted blocks needing user choice).
if [ "$conflicts" -gt 0 ] || [ "$prompts" -gt 0 ]; then
  notice_kind="custom"
  notice="Arkira standards drift detected in $repo_name (custom files present). Run /arkira-sync to review, then /arkira-sync --apply to update."
else
  # 8. Safety guard: working tree must be clean.
  status_out="$(git -C "$repo_root" status --porcelain --ignore-submodules 2>/dev/null || true)"
  if [ -n "$status_out" ]; then
    notice_kind="dirty"
    notice="Arkira standards drift detected in $repo_name (working tree dirty). Run /arkira-sync --apply when ready."
  else
    # 9. Clean tree, MISSING-only drift. Applying remains operator-gated.
    notice_kind="managed"
    notice="Arkira standards drift detected in $repo_name ($will_change managed file(s) missing or outdated). Run /arkira-sync --apply to update."
  fi
fi

notice_fingerprint="$(printf '%s\n%s\n' "$notice_kind" "$drift_out" | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -n "$notice_fingerprint" ] || notice_fingerprint="$notice_kind:$will_change:$conflicts:$prompts"
drift_notice_changed "actionable:$notice_fingerprint" || exit 0
printf '%s\n' "$notice"
exit 0
