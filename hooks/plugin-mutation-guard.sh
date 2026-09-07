#!/usr/bin/env bash
# Prevent a repository-scoped Claude session from rewriting user-global plugin
# state. Plugin installation is an operator/release concern, not product work.
set -uo pipefail

lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib"
json_lib="$lib_dir/json-lib.sh"
[ -f "$json_lib" ] || exit 0
. "$json_lib"

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

payload_fields="$(arkira_payload_fields "$payload" tool_name tool_input.command cwd)"
tool=''
command=''
cwd=''
index=0
while IFS= read -r field; do
  case "$index" in
    0) tool="$field" ;;
    1) command="$field" ;;
    2) cwd="$field" ;;
  esac
  index=$((index + 1))
done <<< "$payload_fields"

[ "$tool" = Bash ] || exit 0
[ -n "$command" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# Search the whole shell payload instead of trusting command-segment boundaries.
# Quotes, eval, command substitutions, and nested shells are ordinary ways to
# invoke a CLI and must not turn a mutation into an allow decision.
normalized_command=${command//\\/}
normalized_command=${normalized_command//\"/}
normalized_command=${normalized_command//\'/}
plugin_prefix='(^|[^[:alnum:]_-])claude[[:space:]]+plugin[[:space:]]+'
direct_mutation='(install|uninstall|remove|update|enable|disable)([[:space:];|&]|$)'
marketplace_mutation='marketplace[[:space:]]+(add|remove|update)([[:space:];|&]|$)'
if [[ ! "$normalized_command" =~ ${plugin_prefix}${direct_mutation} \
  && ! "$normalized_command" =~ ${plugin_prefix}${marketplace_mutation} ]]; then
  exit 0
fi

command -v git >/dev/null 2>&1 || exit 0
repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo" ] || exit 0

origin="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  https://github.com/jeanchastel/arkira-labs-standards|\
  https://github.com/jeanchastel/arkira-labs-standards.git|\
  git@github.com:jeanchastel/arkira-labs-standards.git|\
  ssh://git@github.com/jeanchastel/arkira-labs-standards.git)
    if [ -f "$repo/.claude-plugin/plugin.json" ] \
      && [ ! -L "$repo/.claude-plugin/plugin.json" ] \
      && [ -f "$repo/governance/sync-standard.md" ] \
      && [ ! -L "$repo/governance/sync-standard.md" ]; then
      exit 0
    fi
    ;;
esac

printf '%s' \
  '{"decision":"block","reason":"Product repository sessions must not mutate user-global Claude plugins. Run plugin management only from the canonical Arkira standards repository or from an operator-owned terminal outside a repository."}'
exit 0
