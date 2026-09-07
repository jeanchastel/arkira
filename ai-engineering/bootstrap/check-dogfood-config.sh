#!/usr/bin/env bash
# check-dogfood-config.sh: assert the tracked dogfood .arkira/config.json is a
# complete demonstration config. It must carry every switch id in switches.json
# and its standards_version must equal the plugin version. Root-cause gate for
# R1 / ALS-003. Checker only, it never rewrites the config.
set -uo pipefail

plugin_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
switches="${ARKIRA_SWITCHES_JSON:-$plugin_root/ai-engineering/bootstrap/switches.json}"
config="${ARKIRA_DOGFOOD_CONFIG:-$plugin_root/.arkira/config.json}"
manifest="$plugin_root/.claude-plugin/plugin.json"
marketplace="${ARKIRA_MARKETPLACE_JSON:-$plugin_root/.claude-plugin/marketplace.json}"
readme="${ARKIRA_README:-$plugin_root/README.md}"
version_log="${ARKIRA_VERSION_LOG:-$plugin_root/VERSION.md}"
changelog="${ARKIRA_CHANGELOG:-$plugin_root/CHANGELOG.md}"

for f in "$switches" "$config" "$manifest" "$marketplace"; do
  [[ -f "$f" ]] || { echo "::error::missing $f" >&2; exit 2; }
  # Fail closed on malformed JSON. A parse error must never read as a pass.
  jq empty "$f" >/dev/null 2>&1 || { echo "::error::$f is not valid JSON" >&2; exit 2; }
done
for f in "$readme" "$version_log" "$changelog"; do
  [[ -f "$f" ]] || { echo "::error::missing $f" >&2; exit 2; }
done

# Fail closed on wrong shape. A missing switches array or object makes the
# set-comparisons below error on null and would otherwise leave fail=0.
if [[ "$(jq -r '.switches | type' "$switches")" != "array" ]]; then
  echo "::error::$switches has no switches array" >&2; exit 2
fi
if [[ "$(jq -r '.switches | type' "$config")" != "object" ]]; then
  echo "::error::.arkira/config.json has no switches object" >&2; exit 2
fi

fail=0

plugin_version="$(jq -r '.version' "$manifest")"
config_version="$(jq -r '.standards_version' "$config")"
if [[ "$plugin_version" != "$config_version" ]]; then
  echo "::error::.arkira/config.json standards_version ($config_version) does not equal plugin version ($plugin_version). Run /arkira-update or regenerate the dogfood config." >&2
  fail=1
fi
if ! marketplace_version="$(jq -er '
  [.plugins[] | select(.name == "arkira") | .version] |
  if (length == 1 and (.[0] | type == "string")) then .[0] else error("missing Arkira marketplace version") end
' "$marketplace" 2>/dev/null)"; then
  echo "::error::$marketplace has no single string Arkira plugin version" >&2
  exit 2
fi
if [[ "$plugin_version" != "$marketplace_version" ]]; then
  echo "::error::.claude-plugin/marketplace.json version ($marketplace_version) does not equal plugin version ($plugin_version)." >&2
  fail=1
fi
if ! grep -Fq "plugin-v$plugin_version-blue.svg" "$readme"; then
  echo "::error::README plugin badge does not equal plugin version ($plugin_version)." >&2
  fail=1
fi
if [[ "$(awk '/^## v/{print; exit}' "$version_log")" != "## v$plugin_version" ]]; then
  echo "::error::VERSION.md current entry does not equal plugin version ($plugin_version)." >&2
  fail=1
fi
if [[ "$(awk '/^## \[/{print; exit}' "$changelog")" != "## [$plugin_version]"* ]]; then
  echo "::error::CHANGELOG.md current entry does not equal plugin version ($plugin_version)." >&2
  fail=1
fi

# Extract the canonical switch id list, failing closed if any entry is not an
# object with a string id. This catches malformed switches.json array items
# (scalars, missing id) that would otherwise make the comparisons below error on
# null and silently leave fail=0. A jq error must never read as a pass.
if ! ids_json="$(jq -c '[ .switches[]
      | if (type == "object" and (.id | type) == "string")
        then .id else error("switch entry is not an object with a string id") end ]' \
    "$switches" 2>/dev/null)"; then
  echo "::error::$switches has malformed switch entries; each needs a string id." >&2
  exit 2
fi

if ! missing="$(jq -r --argjson ids "$ids_json" \
    '( $ids ) - ( .switches | keys ) | .[]' "$config" 2>/dev/null)"; then
  echo "::error::could not compare switch inventories against .arkira/config.json." >&2
  exit 2
fi
if [[ -n "$missing" ]]; then
  echo "::error::.arkira/config.json is missing switches present in switches.json:" >&2
  printf '%s\n' "$missing" | sed 's/^/  - /' >&2
  fail=1
fi

if ! extra="$(jq -r --argjson ids "$ids_json" \
    '( .switches | keys ) - $ids | .[]' "$config" 2>/dev/null)"; then
  echo "::error::could not compare switch inventories against .arkira/config.json." >&2
  exit 2
fi
if [[ -n "$extra" ]]; then
  echo "::error::.arkira/config.json carries switches absent from switches.json (stale keys); remove them:" >&2
  printf '%s\n' "$extra" | sed 's/^/  - /' >&2
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "OK: dogfood .arkira/config.json is complete and version-current."
fi
exit "$fail"
