#!/usr/bin/env bash
# SessionStart hook: read-only Arkira update notices.
# Central releases are resolved by arkira context; no vendored-file drift compare runs.
set -uo pipefail

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

arkira_probe_loaded=0
arkira_probe_manifest_path=""
arkira_probe_profile=app
arkira_probe_plugin_version=""
arkira_probe_config_standards_version=""

# Resolve the physical repository before any notice-state write. An absent,
# symbolic, or non-regular repo-local config is a hard silent gate. Do not read
# user-global defaults or create a Git sidecar for an unconfigured repository.
arkira_notice_project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
arkira_notice_git_info="$(git -C "$arkira_notice_project_dir" \
  rev-parse --show-toplevel --absolute-git-dir 2>/dev/null || true)"
arkira_notice_repo_root="${arkira_notice_git_info%%$'\n'*}"
arkira_notice_git_dir="${arkira_notice_git_info#*$'\n'}"
[ -n "$arkira_notice_repo_root" ] || exit 0
arkira_repo_config_path="$arkira_notice_repo_root/.arkira/config.json"
[[ -f "$arkira_repo_config_path" && ! -L "$arkira_repo_config_path" ]] || exit 0

# Update nudges use their own state fingerprint. Keep the stamp in the physical
# git dir so it is local, bounded, and never committed. A transition through a
# healthy state rewrites the stamp, so a later regression is noticed once.
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

# Central repositories have no repository-local standards to compare.
exit 0
